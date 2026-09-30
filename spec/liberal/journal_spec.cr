# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias Api = Partiduo::Api::Liberal
private alias L = LiberalSpec

# ADR-007 D6 : livre-journal des recettes et des dépenses professionnelles,
# ventilé par rubrique de la 2035-A, intangible (contre-passation datée),
# édité en CSV et en PDF.
describe_module "LIBERAL", Api do
  it "charge une nature par rubrique et la table de correspondance au provisionnement" do
    L.setup
    Api.natures(L.system, "receipt").map(&.heading).sort!.should eq(Api::RECEIPT_HEADINGS.sort)
    Api.natures(L.system, "expense").map(&.heading).sort!.should eq(Api::EXPENSE_HEADINGS.sort)
    L.nature("RENT").label.should eq("Loyers et charges locatives")
    lines = Api.form_lines(L.system, 2026)
    lines.find!(&.item.==("receipts")).line.should eq("1")
    lines.find!(&.item.==("depreciation")).form.should eq("2035-B")
    # Codes des zones EDI de la 2035-A 2026 (DECISIONS D-VAL-006).
    {"cet" => "BE", "maintenance" => "EB", "works_total" => "BH", "profit" => "CP"}.each do |item, box|
      {item, lines.find!(&.item.==(item)).box}.should eq({item, box})
    end
    Api.settings(L.system).default_nature_id.should eq(L.nature("RECEIPTS").id)
    Api.load_defaults(L.system).should eq(0)
  end

  it "inscrit recettes et dépenses numérotées par année et publie leurs événements" do
    L.setup
    ReferentialSpec.capture_events("liberal.receipt.recorded") do |receipts|
      ReferentialSpec.capture_events("liberal.expense.recorded") do |expenses|
        first = L.receipt("2026-09-10", "120.50", reference: "N-12")
        rent = L.expense("2026-09-11", "800", "RENT")
        first.number.should eq("J2026-00001")
        rent.number.should eq("J2026-00002")
        first.heading.should eq("receipts")
        rent.heading.should eq("rent")
        rent.cash_flow.should eq(L.d("-800"))
        receipts.size.should eq(1)
        expenses.size.should eq(1)
        payload = expenses.first.payload
        payload["expense_id"].should eq(rent.id.to_s)
        payload["heading"].should eq("rent")
        payload["heading_label"].should eq("Loyers et charges locatives")
        L.d(payload["amount"]).should eq(L.d("800"))
        payload["origin"].should eq("manual")
        receipts.first.payload["receipt_id"].should eq(first.id.to_s)
      end
    end
    Api.lines(L.system).map(&.number).should eq(%w[J2026-00001 J2026-00002])
    Api.lines(L.system, Api::JournalQuery.new(kind: "expense")).size.should eq(1)
    totals = Api.journal_totals(L.system)
    totals.receipts.should eq(L.d("120.5"))
    totals.expenses.should eq(L.d("800"))
    totals.balance.should eq(L.d("-679.5"))
  end

  it "refuse une saisie invalide, avec des messages traduits" do
    L.setup
    result = Api.record_receipt(L.actor, L.input("2026-12-01", "-3", "RENT", method: "bitcoin", card_id: 999_999_i64,
      attachment_id: 999_999_i64, reference: "x" * 101, nondeductible_amount: L.d("1")))
    result.error_keys.sort!.should eq(%w[
      liberal.errors.line.amount.not_positive liberal.errors.line.attachment.unknown liberal.errors.line.card.unknown
      liberal.errors.line.date.future liberal.errors.line.method.invalid liberal.errors.line.nature.unknown
      liberal.errors.line.nondeductible.receipt liberal.errors.line.too_long
    ].sort)
    Api.check_expense(L.actor, L.input("2026-09-01", "10.001", "VEHICLE")).error_keys
      .should eq(["liberal.errors.line.amount.scale"])
    Api.check_expense(L.actor, L.input("2026-09-01", "10", "VEHICLE", nondeductible_amount: L.d("11"))).error_keys
      .should eq(["liberal.errors.line.nondeductible.exceeds"])
    I18n.with_locale("fr") do
      Api.check_expense(L.actor, L.input("2026-09-01", "10", "VEHICLE", nondeductible_amount: L.d("11")))
        .errors.first.message.should eq("La part non déductible ne peut dépasser le montant")
    end
  end

  it "corrige par contre-passation datée et ferme les périodes closes" do
    L.setup
    line = L.expense("2026-03-10", "250", "VEHICLE", nondeductible_amount: L.d("50"))
    reversal = Api.reverse_line(L.actor, Api::ReverseInput.new(line.id, L.date("2026-03-20"))).value!
    reversal.amount.should eq(L.d("-250"))
    reversal.nondeductible_amount.should eq(L.d("-50"))
    reversal.reference.should eq(line.number)
    reversal.label.should eq("Annulation de #{line.number}")
    Api.line(L.system, line.id).reversed_by_id.should eq(reversal.id)
    Api.reverse_line(L.actor, Api::ReverseInput.new(line.id, L.date("2026-03-21"))).error_keys
      .should eq(["liberal.errors.line.reversal.already"])
    Api.reverse_line(L.actor, Api::ReverseInput.new(reversal.id, L.date("2026-03-21"))).error_keys
      .should eq(["liberal.errors.line.reversal.is_reversal"])

    other = L.expense("2026-01-15", "30")
    L.close_period("2026-01-15")
    Api.line(L.system, other.id).locked.should be_true
    # Intangible en base dans une période close : ni modification, ni
    # suppression (D-LIB2-001).
    expect_raises(Exception, /intangible/) do
      Partiduo::Liberal::Line.get!(id: other.id).update!(label: "autre")
    end
    Api.record_expense(L.actor, L.input("2026-01-20", "10", "OFFICE")).error_keys
      .should eq(["liberal.errors.line.date.closed_period"])
    Api.reverse_line(L.actor, Api::ReverseInput.new(other.id, L.date("2026-01-31"))).error_keys
      .should eq(["liberal.errors.line.date.closed_period"])
    Api.reverse_line(L.actor, Api::ReverseInput.new(other.id, L.date("2026-02-01"))).success?.should be_true
  end

  it "ventile l'année par rubrique, contre-passations comprises" do
    L.setup(years: [2025, 2026])
    L.receipt("2026-02-01", "1000")
    L.receipt("2026-02-02", "12.40", "FINANCIAL_INCOME")
    L.expense("2026-02-03", "300", "RENT")
    fuel = L.expense("2026-02-04", "100", "VEHICLE", nondeductible_amount: L.d("20"))
    Api.reverse_line(L.actor, Api::ReverseInput.new(fuel.id, L.date("2026-02-05"))).value!
    L.expense("2026-02-06", "80", "VEHICLE", nondeductible_amount: L.d("16"))
    L.expense("2025-12-31", "999", "RENT")
    totals = Api.heading_totals(L.system, 2026).index_by(&.heading)
    totals.keys.should eq(%w[receipts financial_income rent vehicle])
    totals["vehicle"].amount.should eq(L.d("80"))
    totals["vehicle"].nondeductible_amount.should eq(L.d("16"))
    totals["vehicle"].count.should eq(3)
  end

  it "édite le livre-journal en CSV protégé et en PDF/A" do
    L.setup
    L.receipt("2026-05-01", "150", party_name: "=cmd()")
    L.expense("2026-05-02", "40.10", "OFFICE")
    query = Api::JournalQuery.new(from: L.date("2026-01-01"), to: L.date("2026-12-31"))
    I18n.with_locale("fr") do
      csv = Api.export_journal(L.system, query, Api::ExportFormat::Csv)
      csv.filename.should eq("livre-journal.csv")
      text = String.new(csv.content)
      text.should contain("'=cmd()")
      text.should contain("40.10")
      text.lines.size.should eq(3)
      pdf = Api.export_journal(L.system, query, Api::ExportFormat::Pdf)
      pdf.filename.should eq("livre-journal.pdf")
      String.new(pdf.content[0, 8]).should start_with("%PDF-")
    end
  end

  it "paramètre natures et table de correspondance, avec leurs contrôles" do
    L.setup
    created = Api.create_nature(L.system, Api::NatureInput.new("fuel", "Carburant", "expense", "vehicle")).value!
    created.code.should eq("FUEL")
    Api.create_nature(L.system, Api::NatureInput.new("FUEL", "", "expense", "receipts")).error_keys.sort!
      .should eq(%w[liberal.errors.nature.code.taken liberal.errors.nature.heading.invalid liberal.errors.nature.label.blank])
    L.expense("2026-06-01", "60", "FUEL")
    Api.update_nature(L.system, created.id, Api::NatureInput.new("FUEL", "Gazole", "expense", "travel"))
      .error_keys.should eq(["liberal.errors.nature.in_use"])
    Api.update_nature(L.system, created.id, Api::NatureInput.new("FUEL", "Gazole", "expense", "vehicle", false))
      .value!.enabled.should be_false
    Api.check_expense(L.actor, L.input("2026-06-02", "10", "FUEL")).error_keys
      .should eq(["liberal.errors.line.nature.disabled"])

    line = Api.set_form_line(L.system, Api::FormLineInput.new(2027, "rent", "2035-A", "16", "bf")).value!
    line.box.should eq("BF")
    Api.form_lines(L.system, 2027).find!(&.item.==("rent")).line.should eq("16")
    Api.form_lines(L.system, 2026).find!(&.item.==("rent")).line.should eq("15")
    Api.set_form_line(L.system, Api::FormLineInput.new(1999, "withdrawal", "2036", "1")).error_keys.sort!
      .should eq(%w[liberal.errors.form_line.form.unknown liberal.errors.form_line.item.unknown
        liberal.errors.form_line.millesime.invalid])
    Api.delete_form_line(L.system, line.id).success?.should be_true
    Api.form_lines(L.system, 2027).find!(&.item.==("rent")).line.should eq("15")
  end
end
