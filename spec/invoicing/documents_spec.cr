# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias Api = Partiduo::Api::Invoicing

private def d(text : String) : BigDecimal
  BigDecimal.new(text)
end

describe_module "INVOICING", "Facturation — documents" do
  it "enregistre un brouillon complet : articles, lignes libres, titres, sous-totaux, remises" do
    setup = InvoicingSpec.setup
    lines = [
      Api::LineInput.new(kind: "title", description: "Lot 1 — conseil"),
      InvoicingSpec.line(setup, "10", discount_kind: "percent", discount_value: d("10")),
      Api::LineInput.new(kind: "free", description: "Déplacement", quantity: d("1"), unit_code: "LS",
        unit_price: d("45.50"), vat_rate_id: InvoicingSpec.standard_rate(setup).id),
      Api::LineInput.new(kind: "subtotal"),
      Api::LineInput.new(kind: "note", description: "Livraison sous huit jours."),
      InvoicingSpec.line(setup, "3", item_card_id: setup.goods.id, discount_kind: "amount", discount_value: d("4.70")),
    ]
    view = InvoicingSpec.draft(setup, lines: lines, global_discount_kind: "percent", global_discount_value: d("5"))
    view.lines.map(&.kind).should eq(%w[title item free subtotal note item])
    view.lines[1].description.should eq("Conseil (heure)")
    view.lines[1].unit_code.should eq("HUR")
    view.lines[1].net_amount.should eq(d("720"))
    view.lines[3].net_amount.should eq(d("765.5"))
    view.lines[5].net_amount.should eq(d("70")) # 3 × 24,90 − 4,70
    totals = view.totals
    totals.lines_total.should eq(d("835.5"))
    totals.discount_total.should eq(d("41.78"))
    totals.total_net.should eq(d("793.72"))
    totals.total_vat.should eq(d("158.74"))
    totals.total_gross.should eq(d("952.46"))
    ReferentialSpec.present(view.delivery_address).city.should eq("Saint-Herblain")
    Api.check_document(InvoicingSpec.actor, InvoicingSpec.document_input(setup, lines: lines,
      global_discount_kind: "percent", global_discount_value: d("5"))).value!.total_gross.should eq(d("952.46"))
  end

  it "refuse une saisie invalide, champ par champ" do
    setup = InvoicingSpec.setup
    lines = [
      Api::LineInput.new(kind: "item", item_card_id: setup.customer.id),
      Api::LineInput.new(kind: "free", description: "Sans taux", unit_price: d("1.23456")),
      Api::LineInput.new(kind: "item", item_card_id: setup.item.id, quantity: d("0")),
      Api::LineInput.new(kind: "item", item_card_id: setup.item.id, discount_kind: "percent", discount_value: d("120")),
      Api::LineInput.new(kind: "item", item_card_id: setup.item.id, unit_code: "XXX"),
      Api::LineInput.new(kind: "item", item_card_id: setup.item.id, discount_kind: "amount", discount_value: d("90")),
    ]
    result = Api.create_document(InvoicingSpec.actor, InvoicingSpec.document_input(setup, lines: lines,
      customer_card_id: setup.item.id, validity_date: InvoicingSpec.date("2026-10-01")))
    result.failure?.should be_true
    result.errors.map { |error| {error.field, error.key} }.should contain({"customer_card_id", "invoicing.errors.document.customer.not_customer"})
    {
      "lines[0].item_card_id"   => "invoicing.errors.line.item.invalid",
      "lines[1].unit_price"     => "invoicing.errors.line.unit_price.scale",
      "lines[1].vat_rate_id"    => "invoicing.errors.line.vat_rate.required",
      "lines[2].quantity"       => "invoicing.errors.line.quantity.zero",
      "lines[3].discount_value" => "invoicing.errors.discount.percent",
      "lines[4].unit_code"      => "invoicing.errors.line.unit_code",
      "validity_date"           => "invoicing.errors.document.validity_date.quote_only",
    }.each do |field, key|
      result.errors_for(field).map(&.key).should contain(key)
    end
    ReferentialSpec.expect_translated(result)
    ok = Api.create_document(InvoicingSpec.actor, InvoicingSpec.document_input(setup, lines: [lines[5]]))
    ok.errors_for("lines[0].discount_value").map(&.key).should eq(["invoicing.errors.line.discount.exceeds"])
  end

  it "enchaîne devis → commande → bon de livraison → facture, lien conservé et affiché" do
    setup = InvoicingSpec.setup
    quote = InvoicingSpec.issued(setup, "quote", on: "2026-09-01")
    quote.status.should eq("sent")
    quote.validity_date.should eq(InvoicingSpec.date("2026-10-01"))
    order = Api.transform(InvoicingSpec.actor, quote.id, Api::TransformInput.new("order")).value!
    ReferentialSpec.present(order.source).number.should eq("D-2026-0001")
    I18n.with_locale("fr") { ReferentialSpec.present(order.origin_mention).message.should eq("Issu du devis D-2026-0001") }
    Api.document(InvoicingSpec.actor, quote.id).status.should eq("accepted")
    order = InvoicingSpec.issue(order.id, "2026-09-02")
    order.number.should eq("C-2026-0001")
    order.status.should eq("confirmed")
    delivery = InvoicingSpec.issue(Api.transform(InvoicingSpec.actor, order.id,
      Api::TransformInput.new("delivery_note")).value!.id, "2026-09-05")
    delivery.number.should eq("BL-2026-0001")
    invoice = Api.transform(InvoicingSpec.actor, delivery.id, Api::TransformInput.new("invoice")).value!
    invoice.lines.map(&.description).should eq(quote.lines.map(&.description))
    invoice.order_reference.should eq("C-2026-0001")
    invoice = InvoicingSpec.issue(invoice.id, "2026-09-06")
    invoice.totals.total_gross.should eq(quote.totals.total_gross)
    Api.document(InvoicingSpec.actor, delivery.id).derived.map(&.number).should eq(["F-2026-0001"])

    refused = Api.transform(InvoicingSpec.actor, delivery.id, Api::TransformInput.new("credit_note"))
    refused.error_keys.should eq(["invoicing.errors.transform.not_allowed"])
    draft = InvoicingSpec.draft(setup, "quote")
    Api.transform(InvoicingSpec.actor, draft.id, Api::TransformInput.new("order"))
      .error_keys.should eq(["invoicing.errors.transform.source_draft"])
  end

  it "suit les statuts du devis : accepté, refusé, expiré" do
    setup = InvoicingSpec.setup
    quote = InvoicingSpec.issued(setup, "quote", on: "2026-01-10")
    quote.effective_status.should eq("expired") # validité échue au 9 février 2026
    Api.transform(InvoicingSpec.actor, quote.id, Api::TransformInput.new("invoice"))
      .error_keys.should eq(["invoicing.errors.transform.source_status"])
    other = InvoicingSpec.issued(setup, "quote", on: "2026-09-10", validity_date: InvoicingSpec.date("2099-01-01"))
    Api.decide_quote(InvoicingSpec.actor, other.id, "refused").value!.status.should eq("refused")
    Api.decide_quote(InvoicingSpec.actor, other.id, "accepted").error_keys.should eq(["invoicing.errors.quote.not_sent"])
  end

  it "déduit la facture d'acompte de la facture finale" do
    setup = InvoicingSpec.setup
    order = InvoicingSpec.issued(setup, "order", on: "2026-09-01")
    deposit = Api.transform(InvoicingSpec.actor, order.id,
      Api::TransformInput.new("deposit_invoice", deposit_percent: d("30"))).value!
    deposit.lines.size.should eq(1)
    deposit.lines.first.net_amount.should eq(d("254.94")) # 30 % de 849,80
    deposit = InvoicingSpec.issue(deposit.id, "2026-09-02")
    deposit.number.should eq("FA-2026-0001")
    deposit.type_code.should eq("386")
    InvoicingSpec.codes(deposit).should contain("deposit.invoice")

    invoice = Api.transform(InvoicingSpec.actor, order.id, Api::TransformInput.new("invoice")).value!
    invoice.deductions.map(&.deposit_number).should eq(["FA-2026-0001"])
    invoice = InvoicingSpec.issue(invoice.id, "2026-09-20")
    invoice.totals.prepaid.should eq(deposit.totals.total_gross)
    invoice.totals.payable.should eq(invoice.totals.total_gross - deposit.totals.total_gross)
    InvoicingSpec.codes(invoice).should contain("deposit.deducted")
    # Un acompte ne se déduit qu'une fois.
    again = Api.create_document(InvoicingSpec.actor, InvoicingSpec.document_input(setup, deposit_ids: [deposit.id]))
    again.errors_for("deposit_ids[0]").map(&.key).should eq(["invoicing.errors.document.deposits.already_deducted"])
  end

  it "rend la facture émise intangible, jusque dans la base" do
    setup = InvoicingSpec.setup
    invoice = InvoicingSpec.issued(setup)
    Api.update_document(InvoicingSpec.actor, invoice.id, InvoicingSpec.document_input(setup))
      .error_keys.should eq(["invoicing.errors.document.issued"])
    Api.delete_draft(InvoicingSpec.actor, invoice.id).error_keys.should eq(["invoicing.errors.document.issued"])
    InvoicingSpec.sql_error("UPDATE invoicing_document SET total_gross = 1 WHERE id = $1", invoice.id)
      .to_s.should contain("modification interdite")
    InvoicingSpec.sql_error("UPDATE invoicing_document SET number = 'F-2026-9999' WHERE id = $1", invoice.id)
      .to_s.should contain("modification interdite")
    InvoicingSpec.sql_error("DELETE FROM invoicing_document WHERE id = $1", invoice.id)
      .to_s.should contain("suppression interdite")
    InvoicingSpec.sql_error("UPDATE invoicing_line SET unit_price = 1 WHERE document_id = $1", invoice.id)
      .to_s.should contain("modification interdite")
    InvoicingSpec.sql_error("DELETE FROM invoicing_line WHERE document_id = $1", invoice.id)
      .to_s.should contain("modification interdite")
    InvoicingSpec.sql_error("INSERT INTO invoicing_line (document_id, position, kind, description, quantity, " \
                            "unit_code, unit_price, discount_kind, discount_value, discount_amount, vat_percent, " \
                            "vat_category, net_amount) VALUES ($1, 99, 'note', 'x', 0, '', 0, 'none', 0, 0, 0, '', 0)",
      invoice.id).to_s.should contain("modification interdite")
    InvoicingSpec.sql_error("UPDATE invoicing_document_event SET action = 'x'").to_s.should contain("ajout seul")
    Api.verify_fingerprint(InvoicingSpec.actor, invoice.id).should be_true

    # Un brouillon, lui, se modifie et se supprime.
    draft = InvoicingSpec.draft(setup)
    Api.update_document(InvoicingSpec.actor, draft.id, InvoicingSpec.document_input(setup, notes: "Merci")).value!
      .notes.should eq("Merci")
    Api.delete_draft(InvoicingSpec.actor, draft.id).success?.should be_true
  end

  it "corrige par un avoir (381) qui référence la facture et l'annule" do
    setup = InvoicingSpec.setup
    invoice = InvoicingSpec.issued(setup)
    credit = Api.transform(InvoicingSpec.actor, invoice.id, Api::TransformInput.new("credit_note")).value!
    ReferentialSpec.present(credit.credited).number.should eq(invoice.number)
    over = Api.update_document(InvoicingSpec.actor, credit.id, InvoicingSpec.document_input(setup, "credit_note",
      credited_document_id: invoice.id, lines: [InvoicingSpec.line(setup, "100")]))
    over.success?.should be_true
    Api.issue(InvoicingSpec.actor, credit.id).error_keys.should eq(["invoicing.errors.issue.credit_exceeds"])
    Api.update_document(InvoicingSpec.actor, credit.id, InvoicingSpec.document_input(setup, "credit_note",
      credited_document_id: invoice.id, lines: [InvoicingSpec.line(setup, "1")])).value!
    partial = InvoicingSpec.issue(credit.id, "2026-09-16")
    partial.number.should eq("AV-2026-0001")
    partial.type_code.should eq("381")
    InvoicingSpec.codes(partial).should contain("credit_note.reference")
    Api.document(InvoicingSpec.actor, invoice.id).totals.credited.should eq(d("96"))

    rest = Api.transform(InvoicingSpec.actor, invoice.id, Api::TransformInput.new("credit_note")).value!
    Api.update_document(InvoicingSpec.actor, rest.id, InvoicingSpec.document_input(setup, "credit_note",
      credited_document_id: invoice.id, lines: [InvoicingSpec.line(setup, "9"),
                                                InvoicingSpec.line(setup, "2", item_card_id: setup.goods.id)])).value!
    InvoicingSpec.issue(rest.id, "2026-09-17").number.should eq("AV-2026-0002")
    cancelled = Api.document(InvoicingSpec.actor, invoice.id)
    cancelled.status.should eq("cancelled")
    cancelled.credit_notes.map(&.number).should eq(["AV-2026-0001", "AV-2026-0002"])

    Api.create_document(InvoicingSpec.actor, InvoicingSpec.document_input(setup, "credit_note"))
      .errors_for("credited_document_id").map(&.key).should eq(["invoicing.errors.document.credited.required"])
  end

  it "trace chaque opération : qui, quand, empreinte" do
    setup = InvoicingSpec.setup
    invoice = InvoicingSpec.issued(setup)
    invoice.issued_by_id.should eq(7_i64)
    invoice.issued_at.should_not be_nil
    invoice.fingerprint.size.should eq(64)
    events = Api.document_events(InvoicingSpec.actor, invoice.id)
    events.map(&.action).should eq(%w[created issued])
    issued = events.last
    issued.user_id.should eq(7_i64)
    issued.fingerprint.should eq(invoice.fingerprint)
    issued.details["number"].should eq("F-2026-0001")
  end

  it "publie invoice.issued et credit_note.issued, avec de quoi passer l'écriture" do
    setup = InvoicingSpec.setup
    InvoicingSpec.capture("invoice.issued") do |events|
      invoice = InvoicingSpec.issued(setup, global_discount_kind: "amount", global_discount_value: d("9.80"))
      events.size.should eq(1)
      payload = events.first.payload
      payload["invoice_id"].should eq(invoice.id.to_s)
      payload["source"].should eq("invoice:#{invoice.id}")
      payload["type_code"].should eq("380")
      BigDecimal.new(payload["total_gross"]).should eq(invoice.totals.total_gross)
      sales = JSON.parse(payload["sales"]).as_a
      sales.sum(BigDecimal.new(0)) { |share| BigDecimal.new(share["amount"].as_s) }.should eq(invoice.totals.total_net)
      vat = JSON.parse(payload["vat"]).as_a
      vat.sum(BigDecimal.new(0)) { |share| BigDecimal.new(share["amount"].as_s) }.should eq(invoice.totals.total_vat)
      events.first.actor_user_id.should eq(7_i64)

      InvoicingSpec.capture("credit_note.issued") do |credits|
        credit = Api.transform(InvoicingSpec.actor, invoice.id, Api::TransformInput.new("credit_note")).value!
        InvoicingSpec.issue(credit.id, "2026-09-20")
        credits.size.should eq(1)
        credits.first["invoice_id"].should eq(invoice.id.to_s)
        credits.first["type_code"].should eq("381")
      end
    end
  end

  it "vérifie les droits : lecture, écriture, émission, avoirs" do
    setup = InvoicingSpec.setup
    draft = InvoicingSpec.draft(setup)
    reader = actor_with("invoicing.invoice.read")
    Api.document(reader, draft.id).id.should eq(draft.id)
    expect_raises(Partiduo::Api::Forbidden) { Api.create_document(reader, InvoicingSpec.document_input(setup)) }
    writer = actor_with("invoicing.invoice.read", "invoicing.invoice.write")
    expect_raises(Partiduo::Api::Forbidden) { Api.issue(writer, draft.id) }
    invoice = InvoicingSpec.issue(draft.id)
    credit = Api.transform(writer, invoice.id, Api::TransformInput.new("credit_note")).value!
    issuer = actor_with("invoicing.invoice.issue")
    expect_raises(Partiduo::Api::Forbidden) { Api.issue(issuer, credit.id) }
    expect_raises(Partiduo::Api::Forbidden) { Api.document(Partiduo::Api::Actor.anonymous, draft.id) }
  end
end

describe "Facturation — module inactif" do
  it "refuse toute commande et requête (ModuleDisabled)" do
    with_active_modules("accounting") do
      actor = InvoicingSpec.actor
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.documents(actor) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.settings(actor) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.issue(actor, 1_i64) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.propose_reminders(actor) }
      expect_raises(Partiduo::Api::ModuleDisabled) do
        Api.sales_fec(actor, InvoicingSpec.date("2026-01-01"), InvoicingSpec.date("2026-12-31"))
      end
    end
  end
end
