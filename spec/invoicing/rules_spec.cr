# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Lot 2F — cas limites de la Facturation (ADR-006 D4 à D6) : émission
# (déjà émise, total nul, échéance, remise globale, acompte annulé entre-temps),
# avoirs (date, dépassement, avoir d'acompte), transformations interdites,
# décisions sur un devis, règlements refusés, refus d'un module inactif pour
# chaque appel restant du contrat.

private alias Api = Partiduo::Api::Invoicing

private def d(text : String) : BigDecimal
  BigDecimal.new(text)
end

private def actor : Partiduo::Api::Actor
  InvoicingSpec.actor
end

private def pay(id : Int64, amount : String, on : String = "2026-09-20", method : String = "transfer")
  Api.record_payment(actor, Api::PaymentInput.new(document_id: id, amount: d(amount), paid_on: InvoicingSpec.date(on),
    method: method))
end

describe "Facturation — chaque appel du contrat refuse un module inactif (lot 2F)" do
  it "lève ModuleDisabled" do
    with_active_modules("accounting") do
      day = InvoicingSpec.date("2026-01-01")
      input = Api::DocumentInput.new(kind: "invoice", customer_card_id: 1_i64)
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.document(actor, 1_i64) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.count_documents(actor) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.document_by_number(actor, "F-2026-0001") }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.check_document(actor, input) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.create_document(actor, input) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.update_document(actor, 1_i64, input) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.delete_draft(actor, 1_i64) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.transform(actor, 1_i64, Api::TransformInput.new("invoice")) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.decide_quote(actor, 1_i64, "accepted") }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.document_pdf(actor, 1_i64) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.facturx_xml(actor, 1_i64) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.document_events(actor, 1_i64) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.verify_fingerprint(actor, 1_i64) }
      expect_raises(Partiduo::Api::ModuleDisabled) do
        Api.record_payment(actor, Api::PaymentInput.new(document_id: 1_i64, amount: d("1"), paid_on: day))
      end
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.payments(actor, 1_i64) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.reminders(actor) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.dismiss_reminder(actor, 1_i64) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.send_document(actor, 1_i64, Api::SendInput.new(["a@b.test"])) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.email_logs(actor, 1_i64) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.layouts(actor) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.create_layout(actor, Api::LayoutInput.new("Sobre")) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.update_settings(actor, Api::SettingsInput.new) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.sales_journal_csv(actor, day, day) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.pdf_archive(actor, day, day) }
    end
  end
end

describe_module "INVOICING", "Facturation — émission, cas limites (lot 2F)" do
  it "refuse d'émettre deux fois un document" do
    setup = InvoicingSpec.setup
    invoice = InvoicingSpec.issued(setup)
    Api.issue(actor, invoice.id).error_keys.should eq(["invoicing.errors.issue.already_issued"])
    Api.document(actor, invoice.id).number.should eq("F-2026-0001")
  end

  it "refuse une facture de total nul et une échéance antérieure à l'émission" do
    setup = InvoicingSpec.setup
    notes_only = InvoicingSpec.draft(setup, lines: [Api::LineInput.new(kind: "note", description: "Rien à facturer")])
    Api.issue(actor, notes_only.id).error_keys.should contain("invoicing.errors.issue.no_line")
    zero = InvoicingSpec.draft(setup, lines: [InvoicingSpec.line(setup, "1", unit_price: d("0"))])
    Api.issue(actor, zero.id).error_keys.should eq(["invoicing.errors.issue.total_not_positive"])

    early = InvoicingSpec.draft(setup, due_date: InvoicingSpec.date("2026-09-01"))
    result = Api.issue(actor, early.id, Api::IssueInput.new(issue_date: InvoicingSpec.date("2026-09-15")))
    result.error_keys.should eq(["invoicing.errors.document.due_date.before_issue"])
    ReferentialSpec.expect_translated(result)
    # Rien n'a été numéroté.
    InvoicingSpec.issued(setup).number.should eq("F-2026-0001")
  end

  it "fixe l'échéance par défaut au délai de paiement des paramètres" do
    setup = InvoicingSpec.setup
    invoice = InvoicingSpec.issued(setup, on: "2026-09-15")
    days = Api.settings(actor).payment_terms_days
    invoice.due_date.should eq(InvoicingSpec.date("2026-09-15") + days.days)
    invoice.delivery_date.should eq(InvoicingSpec.date("2026-09-15"))
  end

  it "refuse une remise globale supérieure au total des lignes" do
    setup = InvoicingSpec.setup
    result = Api.create_document(actor, InvoicingSpec.document_input(setup, global_discount_kind: "amount",
      global_discount_value: d("5000")))
    result.errors_for("global_discount_value").map(&.key).should eq(["invoicing.errors.document.global_discount.exceeds"])
    percent = Api.create_document(actor, InvoicingSpec.document_input(setup, global_discount_kind: "percent",
      global_discount_value: d("120")))
    percent.errors_for("global_discount_value").should_not be_empty
  end

  it "refuse de déduire un acompte annulé par avoir entre la saisie et l'émission de la facture finale" do
    setup = InvoicingSpec.setup
    order = InvoicingSpec.issued(setup, "order", on: "2026-09-01")
    deposit = Api.transform(actor, order.id, Api::TransformInput.new("deposit_invoice", deposit_percent: d("30"))).value!
    deposit = InvoicingSpec.issue(deposit.id, "2026-09-02")
    final = Api.transform(actor, order.id, Api::TransformInput.new("invoice")).value!
    final.deductions.map(&.deposit_id).should eq([deposit.id])

    credit = Api.transform(actor, deposit.id, Api::TransformInput.new("credit_note")).value!
    InvoicingSpec.issue(credit.id, "2026-09-05")
    Api.document(actor, deposit.id).status.should eq("cancelled")

    result = Api.issue(actor, final.id, Api::IssueInput.new(issue_date: InvoicingSpec.date("2026-09-20")))
    result.error_keys.should eq(["invoicing.errors.document.deposits.cancelled"])
    Api.document(actor, final.id).number.should be_nil
  end
end

describe_module "INVOICING", "Facturation — avoirs, transformations et devis, cas limites (lot 2F)" do
  it "refuse un avoir daté avant sa facture, ou plus grand que ce qui reste à créditer" do
    setup = InvoicingSpec.setup
    invoice = InvoicingSpec.issued(setup, on: "2026-09-15")
    credit = Api.transform(actor, invoice.id, Api::TransformInput.new("credit_note")).value!
    Api.issue(actor, credit.id, Api::IssueInput.new(issue_date: InvoicingSpec.date("2026-09-10")))
      .error_keys.should contain("invoicing.errors.issue.credit_before_invoice")
    InvoicingSpec.issue(credit.id, "2026-09-16").totals.total_gross.should eq(invoice.totals.total_gross)
    # Facture entièrement créditée : un second avoir ne peut plus rien créditer.
    again = Api.transform(actor, invoice.id, Api::TransformInput.new("credit_note"))
    if again.success?
      Api.issue(actor, again.value!.id, Api::IssueInput.new(issue_date: InvoicingSpec.date("2026-09-17")))
        .error_keys.should contain("invoicing.errors.issue.credit_exceeds")
    else
      again.error_keys.should eq(["invoicing.errors.transform.source_status"])
    end
  end

  it "refuse un avoir pour un autre client ou sur un devis" do
    setup = InvoicingSpec.setup
    invoice = InvoicingSpec.issued(setup)
    quote = InvoicingSpec.issued(setup, "quote", on: "2026-09-16", validity_date: InvoicingSpec.date("2099-01-01"))
    other = Api.create_document(actor, InvoicingSpec.document_input(setup, "credit_note",
      customer_card_id: setup.private_customer.id, credited_document_id: invoice.id))
    other.errors_for("credited_document_id").map(&.key).should eq(["invoicing.errors.document.credited.other_customer"])
    on_quote = Api.create_document(actor, InvoicingSpec.document_input(setup, "credit_note", credited_document_id: quote.id))
    on_quote.errors_for("credited_document_id").map(&.key).should eq(["invoicing.errors.document.credited.invalid"])
    plain = Api.create_document(actor, InvoicingSpec.document_input(setup, credited_document_id: invoice.id))
    plain.errors_for("credited_document_id").map(&.key).should eq(["invoicing.errors.document.credited.credit_note_only"])
  end

  it "n'admet que les transformations de la chaîne documentaire, depuis un document émis" do
    setup = InvoicingSpec.setup
    draft = InvoicingSpec.draft(setup, "quote")
    Api.transform(actor, draft.id, Api::TransformInput.new("invoice")).error_keys
      .should eq(["invoicing.errors.transform.source_draft"])
    invoice = InvoicingSpec.issued(setup)
    Api.transform(actor, invoice.id, Api::TransformInput.new("order")).error_keys
      .should eq(["invoicing.errors.transform.not_allowed"])
    order = InvoicingSpec.issued(setup, "order", on: "2026-09-16")
    Api.transform(actor, order.id, Api::TransformInput.new("deposit_invoice")).error_keys
      .should eq(["invoicing.errors.transform.deposit_percent"])
    Api.transform(actor, order.id, Api::TransformInput.new("deposit_invoice", deposit_percent: d("0"))).error_keys
      .should eq(["invoicing.errors.transform.deposit_percent"])
    Api.transform(actor, order.id, Api::TransformInput.new("deposit_invoice", deposit_percent: d("101"))).error_keys
      .should eq(["invoicing.errors.transform.deposit_percent"])
  end

  it "ne décide que d'un devis émis, et d'une décision connue" do
    setup = InvoicingSpec.setup
    draft = InvoicingSpec.draft(setup, "quote")
    Api.decide_quote(actor, draft.id, "accepted").success?.should be_false
    quote = InvoicingSpec.issued(setup, "quote", validity_date: InvoicingSpec.date("2099-01-01"))
    Api.decide_quote(actor, quote.id, "maybe").success?.should be_false
    invoice = InvoicingSpec.issued(setup, on: "2026-09-16")
    Api.decide_quote(actor, invoice.id, "accepted").success?.should be_false
    Api.decide_quote(actor, quote.id, "accepted").value!.status.should eq("accepted")
  end

  it "vérifie l'empreinte : une altération en base est détectée" do
    setup = InvoicingSpec.setup
    invoice = InvoicingSpec.issued(setup)
    Api.verify_fingerprint(actor, invoice.id).should be_true
    Api.verify_fingerprint(actor, InvoicingSpec.draft(setup).id).should be_false
  end
end

describe "Facturation — règlements refusés (lot 2F)" do
  it "refuse un règlement nul, un mode inconnu, une facture annulée, un devis" do
    with_active_modules("invoicing") do
      setup = InvoicingSpec.setup
      invoice = InvoicingSpec.issued(setup)
      pay(invoice.id, "0").error_keys.should eq(["invoicing.errors.payment.amount.not_positive"])
      pay(invoice.id, "-5").error_keys.should eq(["invoicing.errors.payment.amount.not_positive"])
      result = pay(invoice.id, "10", method: "bitcoin")
      result.error_keys.should eq(["invoicing.errors.payment.method"])
      ReferentialSpec.expect_translated(result)
      quote = InvoicingSpec.issued(setup, "quote", on: "2026-09-16", validity_date: InvoicingSpec.date("2099-01-01"))
      pay(quote.id, "10").error_keys.should eq(["invoicing.errors.payment.document.invalid"])
      pay(987654_i64, "10").error_keys.should eq(["invoicing.errors.payment.document.invalid"])

      credit = Api.transform(actor, invoice.id, Api::TransformInput.new("credit_note")).value!
      InvoicingSpec.issue(credit.id, "2026-09-17")
      pay(invoice.id, "10").error_keys.should contain("invoicing.errors.payment.document.cancelled")
      Api.payments(actor, invoice.id).should be_empty
    end
  end

  it "exige la permission de saisie des règlements" do
    with_active_modules("invoicing") do
      setup = InvoicingSpec.setup
      invoice = InvoicingSpec.issued(setup)
      expect_raises(Partiduo::Api::Forbidden) do
        Api.record_payment(actor_with("invoicing.invoice.read"), Api::PaymentInput.new(document_id: invoice.id,
          amount: d("1"), paid_on: InvoicingSpec.date("2026-09-20")))
      end
    end
  end

  it "passe une facture partiellement créditée puis réglée du reste à « payée »" do
    with_active_modules("invoicing") do
      setup = InvoicingSpec.setup
      invoice = InvoicingSpec.issued(setup) # 1 019,76 TTC
      credit = Api.transform(actor, invoice.id, Api::TransformInput.new("credit_note")).value!
      Api.update_document(actor, credit.id, InvoicingSpec.document_input(setup, "credit_note",
        credited_document_id: invoice.id, lines: [InvoicingSpec.line(setup, "1")])).value!
      InvoicingSpec.issue(credit.id, "2026-09-16") # 96,00 TTC
      due = Api.document(actor, invoice.id).totals.amount_due
      due.should eq(d("923.76"))
      pay(invoice.id, "923.77").error_keys.should eq(["invoicing.errors.payment.amount.exceeds"])
      pay(invoice.id, "923.76").success?.should be_true
      Api.document(actor, invoice.id).status.should eq("paid")
    end
  end
end
