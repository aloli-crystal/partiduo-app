# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Paiements rejetés, Facturation seule (DECISIONS D-INV3-007 à D-INV3-011) :
# règlement annulé par un mouvement inverse tracé, facture de nouveau due,
# encours HT, relance proposée, frais refacturés, alerte.
private alias Inv = Partiduo::Api::Invoicing
private alias S = InvoicingSpec

private def d(text : String) : BigDecimal
  BigDecimal.new(text)
end

private def keys(result) : Array(String)
  result.errors.map(&.key)
end

private def pay(id : Int64, amount : BigDecimal, on : String = "2026-09-20", method : String = "cheque") : Inv::PaymentView
  Inv.record_payment(S.actor, Inv::PaymentInput.new(document_id: id, amount: amount, paid_on: S.date(on), method: method)).value!
end

private def reject(payment : Inv::PaymentView, on : String = "2026-09-24", **options)
  Inv.reject_payment(S.actor, payment.id,
    Inv::PaymentRejectionInput.new(rejected_on: S.date(on), reason: "insufficient_funds").copy_with(**options))
end

describe "Rejet d'un règlement saisi (D-INV3-007, D-INV3-009)" do
  it "rend la facture due, garde le règlement tracé, propose une relance, remonte l'encours, publie payment.rejected" do
    with_active_modules("invoicing") do
      setup = S.setup
      Inv.update_customer_billing(S.actor, setup.customer.id, Inv::CustomerBillingInput.new("monthly", d("2000"))).value!
      invoice = S.issued(setup, "invoice", "2026-09-15")
      payment = pay(invoice.id, invoice.totals.total_gross)
      Inv.document(S.actor, invoice.id).status.should eq("paid")
      Inv.customer_billing(S.actor, setup.customer.id).exposure.should eq(d("0"))

      S.capture("payment.rejected") do |events|
        rejection = reject(payment).value!
        rejection.amount.should eq(invoice.totals.total_gross)
        rejection.open?.should be_true
        rejection.end_of_month.should be_true
        rejection.reminder_id.should_not be_nil
        events.size.should eq(1)
        event = events.first
        {event["payment_id"], event["invoice_id"], event["source"], event["rejected_on"], event["amount"]}
          .should eq({payment.id.to_s, invoice.id.to_s, "manual", "2026-09-24", invoice.totals.total_gross.to_s})
        event["rejection_id"].should eq(rejection.id.to_s)
      end
      document = Inv.document(S.actor, invoice.id)
      document.status.should eq("issued")
      document.totals.paid.should eq(d("0"))
      document.totals.amount_due.should eq(invoice.totals.total_gross)
      Inv.customer_billing(S.actor, setup.customer.id).exposure.should eq(invoice.totals.total_net)
      payments = Inv.payments(S.actor, invoice.id)
      payments.size.should eq(1)
      payments.first.rejected?.should be_true
      payments.first.rejection.try(&.reason).should eq("insufficient_funds")
      Inv.document_events(S.actor, invoice.id).map(&.action).should contain("payment_rejected")
      S.sql_error("DELETE FROM invoicing_payment_rejection").should_not be_nil

      reminders = Inv.reminders(S.actor)
      reminders.size.should eq(1)
      reminders.first.level.should eq(1)
      reminders.first.payment_rejection_id.should_not be_nil
      subject, body = Partiduo::Invoicing::Reminders.message(Partiduo::Invoicing::Reminder.filter(id: reminders.first.id).first!,
        Partiduo::Invoicing::Documents.find(invoice.id))
      subject.should eq("Règlement rejeté : facture #{invoice.number}")
      body.should contain("Provision insuffisante")
      body.should contain("20/09/2026")

      Inv.payment_rejections(S.actor, open_only: true).map(&.document_id).should eq([invoice.id])
      # Réglée de nouveau : l'alerte tombe.
      pay(invoice.id, invoice.totals.total_gross, "2026-09-28", "transfer")
      Inv.payment_rejections(S.actor, open_only: true).should be_empty
      Inv.payment_rejections(S.actor).size.should eq(1)
      keys(reject(payment)).should eq(["invoicing.errors.payment_rejection.already_rejected"])
    end
  end

  it "refacture les frais par un brouillon de facture de frais, au taux choisi" do
    with_active_modules("invoicing") do
      setup = S.setup
      invoice = S.issued(setup, "invoice", "2026-09-15")
      payment = pay(invoice.id, d("500"))
      rate = S.standard_rate(setup)
      rejection = reject(payment, fees: d("12.50"), rebill_fees: true, fees_vat_rate_id: rate.id).value!
      fees_id = rejection.fees_invoice_id || raise "sans facture de frais"
      fees = Inv.document(S.actor, fees_id)
      fees.draft?.should be_true
      fees.kind.should eq("invoice")
      fees.customer_card_id.should eq(setup.customer.id)
      fees.lines.size.should eq(1)
      fees.lines.first.description.should contain(invoice.number.to_s)
      fees.totals.total_net.should eq(d("12.50"))
      Inv.document(S.actor, invoice.id).status.should eq("issued")
    end
  end

  it "contrôle la saisie du rejet" do
    with_active_modules("invoicing") do
      setup = S.setup
      invoice = S.issued(setup, "invoice", "2026-09-15")
      payment = pay(invoice.id, d("100"))
      keys(reject(payment, "2026-09-19")).should eq(["invoicing.errors.payment_rejection.date.before_payment"])
      keys(reject(payment, "2099-01-01")).should eq(["invoicing.errors.payment_rejection.date.future"])
      keys(reject(payment, reason: "lost")).should eq(["invoicing.errors.payment_rejection.reason.invalid"])
      keys(reject(payment, reason: "other")).should eq(["invoicing.errors.payment_rejection.reason_text.required"])
      keys(reject(payment, fees: d("-1"))).should eq(["invoicing.errors.payment_rejection.fees.negative"])
      keys(reject(payment, fees: d("1.234"))).should eq(["invoicing.errors.payment_rejection.fees.scale"])
      keys(reject(payment, rebill_fees: true)).should eq(["invoicing.errors.payment_rejection.fees.required",
                                                          "invoicing.errors.payment_rejection.fees_vat_rate.required"])
      reject(payment, reason: "other", reason_text: "Signature absente").value!.reason_text.should eq("Signature absente")
      expect_raises(Partiduo::Api::NotFound) { Inv.reject_payment(S.actor, 999_999_i64, Inv::PaymentRejectionInput.new(S.date("2026-09-24"), "other")) }
    end
  end

  it "transmet le rejet au comptable : mouvement inverse à sa date dans le journal des encaissements" do
    with_active_modules("invoicing") do
      setup = S.setup
      invoice = S.issued(setup, "invoice", "2026-09-15")
      reject(pay(invoice.id, d("300")), "2026-09-25").value!
      csv = String.new(Inv.sales_journal_csv(S.actor, S.date("2026-09-01"), S.date("2026-09-30")).content)
      csv.should contain("payment_rejection")
      csv.lines.count(&.includes?("payment_rejection")).should eq(2)
    end
  end
end

describe "Rejet d'un règlement et registres micro-entreprise (D-INV3-008)" do
  it "contre-passe la recette d'un règlement saisi" do
    with_active_modules("micro,invoicing") do
      setup = IntegrationSpec.setup
      invoice = S.issued(setup, "invoice", "2026-09-15")
      payment = pay(invoice.id, d("300"))
      receipts = Partiduo::Micro::Receipt.filter(source: "payment:#{payment.id}").to_a
      receipts.should_not be_empty
      reject(payment, "2026-09-25").value!
      receipts.each do |row|
        Partiduo::Micro::Receipt.filter(reversal_of_id: row.pk).exists?.should be_true
      end
    end
  end
end
