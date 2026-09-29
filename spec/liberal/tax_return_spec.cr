# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias Api = Partiduo::Api::Liberal
private alias L = LiberalSpec

# Année 2026 d'un kinésithérapeute : recettes, débours, rétrocessions,
# dépenses ventilées, part privée du véhicule, prélèvements et apport hors
# 2035, une immobilisation, une déduction et une réintégration.
private def year_2026 : Nil
  L.setup
  L.receipt("2026-03-01", "60000.40")
  L.receipt("2026-03-02", "5000", "CONTRIBUTION")
  L.receipt("2026-03-03", "120.49", "FINANCIAL_INCOME")
  L.expense("2026-03-04", "1200", "DISBURSEMENTS")
  L.expense("2026-03-05", "3000.50", "FEES_RETROCEDED")
  L.expense("2026-03-06", "9600", "RENT")
  L.expense("2026-03-07", "4000", "VEHICLE", nondeductible_amount: L.d("1000"))
  L.expense("2026-03-08", "12000.50", "PERSONAL_SOCIAL_MANDATORY")
  L.expense("2026-03-09", "850", "OFFICE")
  L.expense("2026-03-10", "20000", "WITHDRAWAL")
  L.asset("2026-04-01", "3000", 3)
  Api.add_adjustment(L.actor, Api::AdjustmentInput.new(2026, "deduction", "Exonération", L.d("500"))).value!
  Api.add_adjustment(L.actor, Api::AdjustmentInput.new(2026, "reintegration", "Amende", L.d("200"))).value!
end

# ADR-007 D6 : 2035, 2035-A et 2035-B préparées depuis la ventilation, lignes
# lues dans la table datée par millésime, contrôles de cohérence, édition
# de contrôle, lecture par `partiduo-teledec`.
describe_module "LIBERAL", Api do
  it "prépare la 2035-A et la 2035-B en euros entiers" do
    year_2026
    view = Api.tax_return(L.system, 2026)
    {
      "receipts" => "60000", "disbursements" => "1200", "fees_retroceded" => "3001", "net_receipts" => "55799",
      "financial_income" => "120", "total_receipts" => "55919", "rent" => "9600", "vehicle" => "4000",
      "personal_social_mandatory" => "12001", "office" => "850", "total_expenses" => "26451", "excess" => "29468",
      "reintegrations" => "1200", "total_additions" => "30668", "depreciation" => "750", "deductions" => "500",
      "total_subtractions" => "1250", "profit" => "29418", "loss" => "0", "shortfall" => "0",
      "assets_cost" => "3000", "assets_year_depreciation" => "750",
    }.each { |item, amount| {item, view.amount(item)}.should eq({item, L.d(amount)}) }

    receipts = view.lines.find!(&.item.==("receipts"))
    {receipts.form, receipts.line, receipts.box, receipts.mapped}.should eq({"2035-A", "1", "AA", true})
    view.lines.map(&.item).should_not contain("withdrawal")
    view.boxes["2035-A"]["AA"].should eq(L.d("60000"))
    view.boxes["2035-B"]["CH"].should eq(L.d("750"))
    view.boxes["2035-A"]["GJ"].should eq(L.d("3000"))
    view.boxes["2035-A"]["BJ"].should eq(L.d("4000"))
    view.boxes["2035-A"]["BK"].should eq(L.d("12001"))
    view.boxes["2035-A"]["BM"].should eq(L.d("850"))
    view.boxes["2035-A"]["EK"].should eq(L.d("850"))
    view.boxes["2035-B"]["CP"].should eq(L.d("29418"))
    view.boxes.has_key?("2035").should be_false
    view.identity.siren.should eq("732829320")
    view.identity.profession.should eq("Masseur-kinésithérapeute")
    view.assets.size.should eq(1)
    view.adjustments.map(&.kind).should eq(%w[deduction reintegration])
    # Amortissements de l'année : tableau I de la 2035, sans code de zone.
    view.controls.map(&.key).should eq(%w[liberal.controls.box_manual liberal.controls.year_open])
    view.ready?.should be_true
    view.fingerprint.size.should eq(64)
  end

  it "lit les lignes dans la table du millésime et bloque un poste sans ligne" do
    year_2026
    before = Api.tax_return(L.system, 2026)
    Api.set_form_line(L.system, Api::FormLineInput.new(2026, "rent", "2035-A", "15", "ZZ")).value!
    Api.tax_return(L.system, 2026).lines.find!(&.item.==("rent")).box.should eq("ZZ")
    Api.tax_return(L.system, 2025).lines.find!(&.item.==("rent")).box.should eq("BF")
    Api.tax_return(L.system, 2026).fingerprint.should_not eq(before.fingerprint)

    office = Api.form_lines(L.system).find! { |line| line.item == "office" && line.millesime == 2024 }
    Api.delete_form_line(L.system, office.id).value!
    view = Api.tax_return(L.system, 2026)
    view.lines.find!(&.item.==("office")).mapped.should be_false
    view.ready?.should be_false
    I18n.with_locale("fr") do
      control = view.controls.find!(&.key.==("liberal.controls.mapping_missing"))
      I18n.t(control.key, control.params).should eq(
        "« Fournitures de bureau, documentation, correspondance et téléphone » n'a pas de ligne dans la table du millésime 2026")
    end
  end

  it "signale une rubrique négative, un SIREN absent, une année sans exercice" do
    L.setup(years: [2025, 2026])
    old = L.receipt("2025-12-20", "300")
    Api.reverse_line(L.actor, Api::ReverseInput.new(old.id, L.date("2026-01-05"))).value!
    Partiduo::Api::Core.update_settings(L.system, settings_input(siren: "", vat_number: "", rcs: "")).value!
    keys = Api.tax_return(L.system, 2026).controls.map(&.key)
    keys.should contain("liberal.controls.heading_negative")
    keys.should contain("liberal.controls.siren_missing")
    Api.tax_return(L.system, 2030).controls.map(&.key).sort!.should eq(%w[
      liberal.controls.no_fiscal_year liberal.controls.no_receipts liberal.controls.siren_missing
    ])
  end

  it "fige réintégrations et déductions d'une année close" do
    year_2026
    adjustment = Api.adjustments(L.system, 2026).first
    Api.add_adjustment(L.actor, Api::AdjustmentInput.new(2026, "bonus", "", L.d("-1"))).error_keys.sort!.should eq(%w[
      liberal.errors.adjustment.kind.invalid liberal.errors.adjustment.label.blank
      liberal.errors.line.amount.not_positive
    ])
    L.close_year(2026)
    Api.adjustments(L.system, 2026).all?(&.locked).should be_true
    Api.add_adjustment(L.actor, Api::AdjustmentInput.new(2026, "deduction", "x", L.d("1"))).error_keys
      .should eq(["liberal.errors.adjustment.year.closed"])
    Api.delete_adjustment(L.actor, adjustment.id).error_keys.should eq(["liberal.errors.adjustment.year.closed"])
    expect_raises(Exception, /close/) do
      Partiduo::Liberal::Adjustment.get!(id: adjustment.id).delete
    end
    view = Api.tax_return(L.system, 2026)
    view.controls.map(&.key).should eq(["liberal.controls.box_manual"])
    view.amount("profit").should eq(L.d("29418"))
  end

  it "édite la 2035 de contrôle en PDF/A et l'expose en lecture seule" do
    year_2026
    I18n.with_locale("fr") do
      file = Api.export_tax_return(L.system, 2026)
      file.filename.should eq("2035-controle-2026.pdf")
      String.new(file.content[0, 8]).should start_with("%PDF-")
    end
    reader = Partiduo::Api::Actor.user(12_i64, ["liberal.register.read"])
    Api.tax_return(reader, 2026).amount("profit").should eq(L.d("29418"))
    expect_raises(Partiduo::Api::Forbidden) { Api.add_adjustment(reader, Api::AdjustmentInput.new(2026, "deduction", "x", L.d("1"))) }
  end
end
