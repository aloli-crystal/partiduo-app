# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias Api = Partiduo::Api::Invoicing

private def d(text : String) : BigDecimal
  BigDecimal.new(text)
end

private def pay(id : Int64, amount : String, on : String = "2026-09-20") : Partiduo::Api::Result(Api::PaymentView)
  Api.record_payment(InvoicingSpec.actor, Api::PaymentInput.new(document_id: id, amount: d(amount),
    paid_on: InvoicingSpec.date(on), method: "transfer", reference: "VIR 123"))
end

# ADR-006 D3, D5 : règlements total, partiel, acompte déduit ; une seule
# source de vérité selon que la Comptabilité est active ou non.
describe "Facturation — règlements saisis (Comptabilité inactive)" do
  it "enregistre un règlement partiel puis le solde, publie payment.recorded" do
    with_active_modules("invoicing") do
      setup = InvoicingSpec.setup
      invoice = InvoicingSpec.issued(setup) # 1 019,76 TTC
      InvoicingSpec.capture("payment.recorded") do |events|
        pay(invoice.id, "500").value!.amount.should eq(d("500"))
        Api.document(InvoicingSpec.actor, invoice.id).status.should eq("partially_paid")
        pay(invoice.id, "600").error_keys.should eq(["invoicing.errors.payment.amount.exceeds"])
        pay(invoice.id, "519.765").error_keys.should eq(["invoicing.errors.payment.amount.scale"])
        pay(invoice.id, "519.76").success?.should be_true
        events.size.should eq(2)
        events.first["invoice_id"].should eq(invoice.id.to_s)
        events.first["amount"].should eq("500.0")
        events.first.actor_user_id.should eq(7_i64)
      end
      paid = Api.document(InvoicingSpec.actor, invoice.id)
      paid.status.should eq("paid")
      paid.totals.amount_due.should eq(BigDecimal.new(0))
      Api.payments(InvoicingSpec.actor, invoice.id).map(&.amount).should eq([d("500"), d("519.76")])
      Api.verify_fingerprint(InvoicingSpec.actor, invoice.id).should be_true
    end
  end

  it "solde une facture finale diminuée de son acompte, et refuse un brouillon" do
    with_active_modules("invoicing") do
      setup = InvoicingSpec.setup
      order = InvoicingSpec.issued(setup, "order")
      deposit = Api.transform(InvoicingSpec.actor, order.id,
        Api::TransformInput.new("deposit_invoice", deposit_percent: d("40"))).value!
      deposit = InvoicingSpec.issue(deposit.id, "2026-09-16")
      pay(deposit.id, deposit.totals.total_gross.to_s).success?.should be_true
      invoice = Api.transform(InvoicingSpec.actor, order.id, Api::TransformInput.new("invoice")).value!
      pay(invoice.id, "1").error_keys.should eq(["invoicing.errors.payment.document.invalid"])
      invoice = InvoicingSpec.issue(invoice.id, "2026-09-25")
      invoice.totals.amount_due.should eq(invoice.totals.total_gross - deposit.totals.total_gross)
      pay(invoice.id, invoice.totals.amount_due.to_s, "2026-10-05").success?.should be_true
      Api.document(InvoicingSpec.actor, invoice.id).status.should eq("paid")
    end
  end

  it "compte un avoir dans le solde de la facture" do
    with_active_modules("invoicing") do
      setup = InvoicingSpec.setup
      invoice = InvoicingSpec.issued(setup)
      credit = Api.transform(InvoicingSpec.actor, invoice.id, Api::TransformInput.new("credit_note")).value!
      Api.update_document(InvoicingSpec.actor, credit.id, InvoicingSpec.document_input(setup, "credit_note",
        credited_document_id: invoice.id, lines: [InvoicingSpec.line(setup, "1")])).value!
      InvoicingSpec.issue(credit.id, "2026-09-16")
      balance = Api.document(InvoicingSpec.actor, invoice.id).totals.amount_due
      balance.should eq(d("1019.76") - d("96"))
      pay(invoice.id, balance.to_s).success?.should be_true
      Api.document(InvoicingSpec.actor, invoice.id).status.should eq("paid")
    end
  end
end

describe "Facturation — règlements quand la Comptabilité est active" do
  it "refuse la saisie : le règlement vient du lettrage" do
    with_active_modules("accounting,invoicing") do
      setup = InvoicingSpec.setup
      invoice = InvoicingSpec.issued(setup)
      pay(invoice.id, "10").error_keys.should eq(["invoicing.errors.payment.accounting_active"])
    end
  end

  it "passe la facture à payée ou partiellement payée sur payment.matched (idempotent)" do
    with_active_modules("accounting,invoicing") do
      setup = InvoicingSpec.setup
      invoice = InvoicingSpec.issued(setup)
      other = InvoicingSpec.issued(setup)
      Partiduo::Events.publish("payment.matched", {"matching_id" => "41", "sources" => "invoice:#{invoice.id}",
                                                   "amounts" => "invoice:#{invoice.id}=300.00",
                                                   "matched_on" => "2026-09-25"})
      partial = Api.document(InvoicingSpec.actor, invoice.id)
      partial.status.should eq("partially_paid")
      partial.totals.paid.should eq(d("300"))
      Partiduo::Events.publish("payment.matched", {"matching_id" => "41", "sources" => "invoice:#{invoice.id}",
                                                   "amounts" => "invoice:#{invoice.id}=300.00"})
      Api.document(InvoicingSpec.actor, invoice.id).totals.paid.should eq(d("300"))
      # Sans montant : le lettrage solde la facture ; les sources étrangères sont ignorées.
      Partiduo::Events.publish("payment.matched", {"matching_id" => "42",
                                                   "sources"     => "fec:12,invoice:#{invoice.id},invoice:#{other.id}"})
      Api.document(InvoicingSpec.actor, invoice.id).status.should eq("paid")
      Api.document(InvoicingSpec.actor, other.id).status.should eq("paid")
      payments = Api.payments(InvoicingSpec.actor, invoice.id)
      payments.map(&.source).uniq!.should eq(["matching"])
      payments.first.paid_on.should eq(InvoicingSpec.date("2026-09-25"))
      payments.sum(BigDecimal.new(0), &.amount).should eq(invoice.totals.total_gross)
    end
  end
end
