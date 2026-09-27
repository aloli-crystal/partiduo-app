# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Déclarations belges (lot 4), successeur de l'extension TVA de
# noalyss-plugins : grilles calculées depuis les écritures (`Tva_Amount`,
# `Ext_Tva::compute`), listing des clients assujettis (`Ext_List_Assujetti`),
# relevé intracommunautaire (`Ext_List_Intra`), fichiers Intervat, clôture et
# écriture de liquidation (`Ext_Tva::propose_form`).

private alias Api = Partiduo::Api::Accounting

private def system
  Partiduo::Api::Actor.system
end

private def d(text : String) : BigDecimal
  BigDecimal.new(text)
end

private record BeDataset,
  client : Partiduo::Api::Cards::CardView,
  client2 : Partiduo::Api::Cards::CardView,
  small : Partiduo::Api::Cards::CardView,
  foreign : Partiduo::Api::Cards::CardView,
  supplier : Partiduo::Api::Cards::CardView

# Premier trimestre 2026 : ventes à 21 et 6 %, avoir, livraison
# intracommunautaire ; achats de marchandises, de biens d'investissement et
# acquisition intracommunautaire autoliquidée.
private def be_dataset : BeDataset
  VatReturnSpec.setup("be")
  client = VatReturnSpec.card("CUSTOMER", "Client Belge", "BE0123456749")
  client2 = VatReturnSpec.card("CUSTOMER", "Second Client", "BE0417497106")
  small = VatReturnSpec.card("CUSTOMER", "Petit Client", "BE0999999922")
  foreign = VatReturnSpec.card("CUSTOMER", "Client Français", "FR44732829320")
  supplier = VatReturnSpec.card("SUPPLIER", "Fournisseur")

  VatReturnSpec.sale(client, [EntrySpec.item("1000", "21G", account: "700"), EntrySpec.item("500", "6A", account: "700")])
  VatReturnSpec.sale(client, [EntrySpec.item("-100", "21G", account: "700")], "2026-02-20")
  VatReturnSpec.sale(client2, [EntrySpec.item("1000", "21G", account: "700")], "2026-03-01")
  VatReturnSpec.sale(small, [EntrySpec.item("100", "21G", account: "700")], "2026-03-02")
  VatReturnSpec.sale(foreign, [EntrySpec.item("2000", "INTL", account: "700")], "2026-03-05")
  VatReturnSpec.purchase(supplier, [EntrySpec.item("400", "21G", account: "604")])
  VatReturnSpec.purchase(supplier, [EntrySpec.item("1000", "21G", account: "240")])
  VatReturnSpec.purchase(supplier, [EntrySpec.item("1000", "INTA", account: "604")], "2026-03-15")
  # Hors période.
  VatReturnSpec.sale(client, [EntrySpec.item("999", "21G", account: "700")], "2026-04-02")
  BeDataset.new(client, client2, small, foreign, supplier)
end

private EXPECTED_Q1 = {
  "01" => d("500"), "03" => d("2100"), "46" => d("2000"), "49" => d("100"),
  "81" => d("1400"), "83" => d("1000"), "86" => d("1000"),
  "54" => d("471"), "55" => d("210"), "xx" => d("681"),
  "59" => d("504"), "64" => d("21"), "yy" => d("525"), "71" => d("156"),
}

describe_module "ACCOUNTING", "Déclarations de TVA belges" do
  it "calcule les grilles de la déclaration périodique depuis les achats et les ventes" do
    be_dataset
    view = Api.preview_vat_return(system, VatReturnSpec.input("be_periodic")).value!

    view.id.should be_nil
    view.regime.should eq("be")
    view.date_from.should eq(EntrySpec.date("2026-01-01"))
    view.date_to.should eq(EntrySpec.date("2026-03-31"))
    VatReturnSpec.amounts(view).should eq(EXPECTED_Q1)
    view.box("03").try(&.label_key).should eq("vat.boxes.be.03")
    view.box("03").try(&.section_key).should eq("vat.sections.be.frame2")
    view.box("71").try(&.total).should be_true
    I18n.t(ReferentialSpec.present(view.box("54")).label_key).should contain("[54]")
  end

  it "détaille l'apport de chaque règle et lit les règles par défaut" do
    be_dataset
    created = Api.create_vat_return(system, VatReturnSpec.input("be_periodic")).value!
    details = Api.vat_return_details(system, ReferentialSpec.present(created.id))
    details.select(&.box.==("03")).sum(BigDecimal.new(0), &.amount).should eq(d("2100"))
    details.find! { |detail| detail.box == "86" }.vat_rate_code.should eq("INTA")
    details.find! { |detail| detail.box == "81" }.lines.should eq(2)

    rules = Api.vat_box_rules(system, "be")
    rules.all?(&.default).should be_true
    rules.find! { |rule| rule.box == "83" }.accounts.should eq("20,21,22,23,24,25,26,27")
    rules.find! { |rule| rule.box == "82" }.excluded_accounts.should eq("2,60")
  end

  it "corrige une grille d'un brouillon, recalcule les totaux et refuse de corriger un total" do
    be_dataset
    id = VatReturnSpec.create(VatReturnSpec.input("be_periodic"))

    view = Api.update_vat_return(system, id, Api::VatReturnUpdateInput.new(
      adjustments: [Api::VatAdjustment.new("61", d("10"))], ask_restitution: true)).value!
    view.amount("61").should eq(d("10"))
    view.box("61").try(&.adjusted).should be_true
    view.box("61").try(&.computed).should eq(d("0"))
    view.amount("xx").should eq(d("691"))
    view.amount("71").should eq(d("166"))
    view.ask_restitution.should be_true

    refused = Api.update_vat_return(system, id, Api::VatReturnUpdateInput.new(
      adjustments: [Api::VatAdjustment.new("71", d("1")), Api::VatAdjustment.new("03", d("1.005"))]))
    refused.error_keys.should eq(["accounting.errors.vat_return.box.not_editable",
                                  "accounting.errors.vat_return.box.too_many_decimals"])

    # Recalcul : la correction reste.
    Api.recompute_vat_return(system, id).value!.amount("61").should eq(d("10"))
    back = Api.update_vat_return(system, id, Api::VatReturnUpdateInput.new(
      adjustments: [Api::VatAdjustment.new("61", nil)])).value!
    back.amount("71").should eq(d("156"))
    back.box("61").try(&.adjusted).should be_false

    Api.create_vat_return(system, VatReturnSpec.input("be_periodic")).error_keys
      .should eq(["accounting.errors.vat_return.draft_exists"])
  end

  it "écrit le fichier Intervat de la déclaration, avec le déclarant de la société" do
    be_dataset
    id = VatReturnSpec.create(VatReturnSpec.input("be_periodic"))
    file = Api.vat_return_file(system, id, Api::VatFileFormat::Xml).value!
    file.filename.should eq("be_periodic-20260101-20260331.xml")
    file.content_type.should eq("application/xml")
    text = String.new(file.content)
    text.should contain("<VATNumber>0417497106</VATNumber>")
    text.should contain("<Name>Exemple SRL</Name>")
    text.should contain("<Street>Rue Haute 12</Street>")
    text.should contain(%(<ns2:Amount GridNumber="3">2100.00</ns2:Amount>))
    text.should contain(%(<ns2:Amount GridNumber="71">156.00</ns2:Amount>))
    text.should contain("<ns2:Quarter>1</ns2:Quarter>")

    Api.update_vat_settings(system, Api::VatSettingsInput.new(representative_id: "0123456749",
      representative_id_type: "TIN", representative_issued_by: "be", representative_name: "Fiduciaire SC",
      representative_country_code: "BE")).value!
    String.new(Api.vat_return_file(system, id, Api::VatFileFormat::Xml).value!.content)
      .should contain(%(<RepresentativeID identificationType="TIN" issuedBy="BE">0123456749</RepresentativeID>))

    csv = String.new(Api.vat_return_file(system, id, Api::VatFileFormat::Csv).value!.content)
    csv.should contain("71;")
    csv.should contain("156.00")
    pdf = Api.vat_return_file(system, id, Api::VatFileFormat::Pdf).value!
    pdf.content_type.should eq("application/pdf")
  end

  it "clôt la déclaration et passe l'écriture de liquidation des comptes de TVA" do
    be_dataset
    id = VatReturnSpec.create(VatReturnSpec.input("be_periodic"))
    view = Api.close_vat_return(system, id).value!

    view.closed?.should be_true
    view.closed_at.should_not be_nil
    entry = Api.entry(system, ReferentialSpec.present(view.settlement_entry_id))
    entry.ledger_code.should eq("O01")
    entry.date.should eq(EntrySpec.date("2026-03-31"))
    entry.source.should eq("vat_return:#{id}")
    EntrySpec.lines_by_account(entry).should eq({
      "4111"   => [{"credit", d("294")}],
      "411502" => [{"credit", d("210")}],
      "4511"   => [{"debit", d("420")}],
      "4513"   => [{"debit", d("30")}],
      "451502" => [{"debit", d("210")}],
      "451"    => [{"credit", d("156")}],
    })

    # Figée : ni correction, ni suppression, ni recalcul, ni seconde liquidation.
    Api.update_vat_return(system, id, Api::VatReturnUpdateInput.new(ask_restitution: true)).error_keys
      .should eq(["accounting.errors.vat_return.closed"])
    Api.delete_vat_return(system, id).error_keys.should eq(["accounting.errors.vat_return.closed"])
    Api.recompute_vat_return(system, id).error_keys.should eq(["accounting.errors.vat_return.closed"])
    Api.settle_vat_return(system, id).error_keys.should eq(["accounting.errors.vat_return.already_settled"])
    Api.create_vat_return(system, VatReturnSpec.input("be_periodic", "month", 2)).error_keys
      .should eq(["accounting.errors.vat_return.overlap"])

    # Une déclaration suivante ne reprend pas la liquidation (journal d'OD).
    Api.preview_vat_return(system, VatReturnSpec.input("be_periodic", number: 2)).value!.amount("03")
      .should eq(d("999"))
  end

  it "refuse de clore une déclaration dont les écritures ont changé, puis la liquide après coup" do
    data = be_dataset
    id = VatReturnSpec.create(VatReturnSpec.input("be_periodic"))
    VatReturnSpec.sale(data.client, [EntrySpec.item("50", "21G", account: "700")], "2026-03-20")

    Api.close_vat_return(system, id).error_keys.should eq(["accounting.errors.vat_return.stale"])
    Api.recompute_vat_return(system, id).value!.amount("03").should eq(d("2150"))
    closed = Api.close_vat_return(system, id, nil).value!
    closed.settlement_entry_id.should be_nil

    settled = Api.settle_vat_return(system, id, Api::VatSettlementInput.new(date: EntrySpec.date("2026-04-15"))).value!
    entry = Api.entry(system, ReferentialSpec.present(settled.settlement_entry_id))
    entry.date.should eq(EntrySpec.date("2026-04-15"))
    EntrySpec.lines_by_account(entry)["451"].should eq([{"credit", d("166.50")}])
  end

  it "garde une déclaration close intacte en base (SQL direct)" do
    be_dataset
    id = Api.close_vat_return(system,
      VatReturnSpec.create(VatReturnSpec.input("be_periodic")), nil).value!.id

    expect_raises(Exception, /close, modification interdite/) do
      EntrySpec.sql_transaction { |db| db.exec("UPDATE vat_return SET ask_restitution = true WHERE id = $1", id) }
    end
    expect_raises(Exception, /modification interdite/) do
      EntrySpec.sql_transaction { |db| db.exec("UPDATE vat_return_box SET amount = 1 WHERE vat_return_id = $1", id) }
    end
    expect_raises(Exception, /suppression interdite/) do
      EntrySpec.sql_transaction { |db| db.exec("DELETE FROM vat_return WHERE id = $1", id) }
    end
  end

  it "établit le listing annuel des clients assujettis (seuil de 250 €)" do
    data = be_dataset
    view = Api.create_vat_return(system, VatReturnSpec.input("be_client_listing", "year")).value!

    view.date_from.should eq(EntrySpec.date("2026-01-01"))
    view.date_to.should eq(EntrySpec.date("2026-12-31"))
    view.threshold.should eq(d("250"))
    view.lines.map { |line| {line.vat_number, line.amount, line.vat} }.should eq([
      {"BE0123456749", d("2399"), d("428.79")},
      {"BE0417497106", d("1000"), d("210")},
    ])
    view.lines.first.card_id.should eq(data.client.id)
    view.lines.first.name.should eq("Client Belge")

    text = String.new(Api.vat_return_file(system, ReferentialSpec.present(view.id), Api::VatFileFormat::Xml).value!.content)
    text.should contain(%(ClientsNbr="2"))
    text.should contain(%(TurnOverSum="3399.00"))
    text.should contain(%(<ns2:CompanyVATNumber issuedBy="BE">0123456749</ns2:CompanyVATNumber>))

    Api.preview_vat_return(system, VatReturnSpec.input("be_client_listing", "year", threshold: d("50"))).value!
      .lines.size.should eq(3)
    Api.preview_vat_return(system, VatReturnSpec.input("be_client_listing", "quarter")).error_keys
      .should eq(["accounting.errors.vat_return.periodicity.invalid"])
  end

  it "établit le relevé intracommunautaire du mois (livraisons de biens, code L)" do
    data = be_dataset
    view = Api.create_vat_return(system, VatReturnSpec.input("be_intra_listing", "month", 3)).value!
    view.lines.map { |line| {line.card_id, line.vat_number, line.code, line.amount} }
      .should eq([{data.foreign.id, "FR44732829320", "L", d("2000")}])
    text = String.new(Api.vat_return_file(system, ReferentialSpec.present(view.id), Api::VatFileFormat::Xml).value!.content)
    text.should contain("<ns2:Month>3</ns2:Month>")
    text.should contain(%(<ns2:CompanyVATNumber issuedBy="FR">44732829320</ns2:CompanyVATNumber>))
    Api.preview_vat_return(system, VatReturnSpec.input("be_intra_listing", "month", 2)).value!.lines.should be_empty
    Api.close_vat_return(system, ReferentialSpec.present(view.id)).value!.settlement_entry_id.should be_nil
  end

  it "paramètre les règles d'une grille (solde d'un journal d'opérations diverses) et revient aux règles par défaut" do
    be_dataset
    EntrySpec.post_misc([EntrySpec.debit("640", "10"), EntrySpec.credit("4519", "10")], "2026-03-10")
    result = Api.set_vat_box_rules(system, "be", "61", [
      Api::VatBoxRuleInput.new(ledger_kind: "misc", accounts: "451", source: "balance", operation: "subtract"),
    ])
    result.value!.first.accounts.should eq("451")
    Api.preview_vat_return(system, VatReturnSpec.input("be_periodic")).value!.amount("61").should eq(d("10"))
    rules = Api.vat_box_rules(system, "be")
    rules.none?(&.default).should be_true
    rules.count(&.box.==("03")).should eq(1)

    Api.set_vat_box_rules(system, "be", "03", [] of Api::VatBoxRuleInput).value!
    Api.preview_vat_return(system, VatReturnSpec.input("be_periodic")).value!.amount("03").should eq(d("0"))

    refused = Api.set_vat_box_rules(system, "be", "81", [
      Api::VatBoxRuleInput.new(source: "balance", ledger_kind: "sale", vat_rate_code: "21G"),
      Api::VatBoxRuleInput.new(source: "nope", ledger_code: "ZZ9", accounts: "6-0"),
    ])
    refused.error_keys.should eq([
      "accounting.errors.vat_rule.ledger_kind.balance", "accounting.errors.vat_rule.vat_rate_code.balance",
      "accounting.errors.vat_rule.source.invalid", "accounting.errors.vat_rule.ledger_code.not_found",
      "accounting.errors.vat_rule.accounts.invalid",
    ])
    Api.set_vat_box_rules(system, "be", "xx", [] of Api::VatBoxRuleInput).error_keys
      .should eq(["accounting.errors.vat_rule.box.invalid"])

    Api.reset_vat_box_rules(system, "be").value!
    Api.vat_box_rules(system, "be").all?(&.default).should be_true
    VatReturnSpec.amounts(Api.preview_vat_return(system, VatReturnSpec.input("be_periodic")).value!).should eq(EXPECTED_Q1)
  end

  it "ne propose que les formulaires du régime du dossier et refuse ceux d'un autre régime" do
    be_dataset
    Api.vat_forms(system).map(&.form).should eq(%w[be_periodic be_client_listing be_intra_listing])
    Api.preview_vat_return(system, VatReturnSpec.input("fr_ca3")).error_keys
      .should eq(["accounting.errors.vat_return.form.regime"])
    Api.preview_vat_return(system, VatReturnSpec.input("be_periodic", number: 5)).error_keys
      .should eq(["accounting.errors.vat_return.number.invalid"])
    Api.preview_vat_return(system, VatReturnSpec.input("nope")).error_keys
      .should eq(["accounting.errors.vat_return.form.invalid"])
  end

  it "exige la permission de déclarer la TVA et le module Comptabilité" do
    be_dataset
    actor = actor_with("accounting.entry.read")
    expect_raises(Partiduo::Api::Forbidden) { Api.vat_forms(actor) }
    expect_raises(Partiduo::Api::Forbidden) { Api.preview_vat_return(actor, VatReturnSpec.input("be_periodic")) }
    with_active_modules("invoicing") do
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.vat_returns(system) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.create_vat_return(system, VatReturnSpec.input("be_periodic")) }
    end
  end
end
