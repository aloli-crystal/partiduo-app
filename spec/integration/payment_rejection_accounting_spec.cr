# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Paiement rejeté avec la Comptabilité (D-INV3-008) : encaissement
# contre-passé à la date du rejet, lettrage défait (`payment.unmatched`),
# autres règlements relettrés, frais bancaires au compte `bank_fees` ;
# règlement saisi sans Comptabilité puis rejeté, rejoué à l'activation.
private alias Acc = Partiduo::Api::Accounting
private alias Inv = Partiduo::Api::Invoicing
private alias I = IntegrationSpec

private def d(text : String) : BigDecimal
  BigDecimal.new(text)
end

private def reject(payment_id : Int64, on : String = "2026-09-27", fees : String = "0") : Inv::PaymentRejectionView
  result = Inv.reject_payment(InvoicingSpec.actor, payment_id,
    Inv::PaymentRejectionInput.new(rejected_on: I.date(on), reason: "insufficient_funds", fees: d(fees)))
  raise "rejet refusé : #{result.error_keys.join(", ")}" if result.failure?
  result.value!
end

describe "Rejet d'un encaissement lettré (D-INV3-008)" do
  it "contre-passe l'encaissement, défait son lettrage, relettre l'autre règlement, passe les frais" do
    with_active_modules(I::BOTH) do
      setup = I.setup
      invoice = InvoicingSpec.issued(setup)
      sale = I.entry("invoice:#{invoice.id}")
      account = I.card_account(setup.customer.id)
      line = I.line(sale, account).id
      first = I.bank_receipt(setup.customer.code, "400", [line], "2026-09-20")
      second = I.bank_receipt(setup.customer.code, "619.76", [line], "2026-09-25")
      I.document(invoice.id).status.should eq("paid")
      rejected = Inv.payments(InvoicingSpec.actor, invoice.id).find { |payment| payment.amount == d("619.76") } ||
                 raise "règlement absent"

      InvoicingSpec.capture("payment.unmatched") do |events|
        rejection = reject(rejected.id, fees: "8.40")
        rejection.payment_source.should eq("matching")
        events.size.should eq(1)
      end

      # Facture : l'autre règlement demeure, le rejeté est tracé.
      document = I.document(invoice.id)
      document.status.should eq("partially_paid")
      document.totals.paid.should eq(d("400"))
      payments = Inv.payments(InvoicingSpec.actor, invoice.id)
      payments.select(&.rejected?).map(&.amount).should eq([d("619.76")])
      payments.reject(&.rejected?).sum(BigDecimal.new(0), &.amount).should eq(d("400"))

      # Comptabilité : contre-passation à la date du rejet, lettrée avec
      # l'encaissement ; la facture reste ouverte de 619,76.
      reversal = I.entry("payment_rejection:#{Inv.payment_rejections(InvoicingSpec.actor).first.id}")
      reversal.date.should eq(I.date("2026-09-27"))
      reversal.ledger_id.should eq(Acc.ledger_by_code(I.system, "F01").id)
      I.line(reversal, account).side.debit?.should be_true
      I.line(reversal, account).amount.should eq(d("619.76"))
      reversal_matching = I.line(reversal, account).matching_id || raise "contre-passation non lettrée"
      I.line(Acc.entry(I.system, second.id), account).matching_id.should eq(reversal_matching)
      invoice_matching = I.line(Acc.entry(I.system, sale.id), account).matching_id || raise "facture non relettrée"
      I.line(Acc.entry(I.system, first.id), account).matching_id.should eq(invoice_matching)

      fees = I.entry("payment_rejection:#{Inv.payment_rejections(InvoicingSpec.actor).first.id}:fees")
      I.line(fees, "627").amount.should eq(d("8.40"))
      I.line(fees, "627").side.debit?.should be_true
    end
  end
end

describe "Règlement saisi puis rejeté sans Comptabilité, comptabilisé à l'activation (D-INV3-008)" do
  it "rejoue l'encaissement puis sa contre-passation, lettrages compris" do
    with_active_modules(I::BOTH) do
      setup = I.setup
      invoice = InvoicingSpec.issued(setup)
      # Règlement saisi et rejeté quand la Comptabilité était inactive.
      payment, rejection = with_active_modules("invoicing") do
        recorded = I.record_payment(invoice.id, "300", "2026-09-20")
        {recorded, reject(recorded.id, "2026-09-26", "5")}
      end
      I.entries("payment:#{payment.id}").should be_empty
      history = Acc.invoicing_history(I.system)
      history.map(&.source).should eq(["payment:#{payment.id}", "payment_rejection:#{rejection.id}"])
      history.last.amount.should eq(d("300"))
      history.last.date.should eq(I.date("2026-09-26"))
      Acc.post_invoicing_history(I.system).value!.posted.map(&.source)
        .should eq(["payment:#{payment.id}", "payment_rejection:#{rejection.id}"])
      Acc.invoicing_history(I.system).should be_empty
      account = I.card_account(setup.customer.id)
      reversal = I.entry("payment_rejection:#{rejection.id}")
      I.line(reversal, account).matching_id.should eq(I.line(I.entry("payment:#{payment.id}"), account).matching_id)
      I.line(I.entry("invoice:#{invoice.id}"), account).matching_id.should be_nil
      I.line(I.entry("payment_rejection:#{rejection.id}:fees"), "627").amount.should eq(d("5"))
      I.document(invoice.id).totals.paid.should eq(d("0"))
    end
  end
end
