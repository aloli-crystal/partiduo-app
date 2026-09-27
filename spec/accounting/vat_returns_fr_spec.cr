# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Déclarations françaises (lot 4) : CA3 et CA12 calculées depuis les
# écritures, TVA sur les débits ou les encaissements (`tva_payment_sale`,
# `Tax_Summary`), autoliquidation des acquisitions intracommunautaires,
# euros entiers, liquidation vers la TVA à décaisser ou le crédit à reporter.

private alias Api = Partiduo::Api::Accounting

private def system
  Partiduo::Api::Actor.system
end

private def d(text : String) : BigDecimal
  BigDecimal.new(text)
end

private record FrDataset, customer : Partiduo::Api::Cards::CardView, supplier : Partiduo::Api::Cards::CardView

# Premier trimestre 2026 : ventes à 20 et 5,5 %, achats de biens et
# services, immobilisation, acquisition intracommunautaire autoliquidée.
private def fr_dataset : FrDataset
  VatReturnSpec.setup("fr")
  AccountingSpec.create_account("6061", "Fournitures non stockables")
  customer = VatReturnSpec.card("CUSTOMER", "Client Durand")
  supplier = VatReturnSpec.card("SUPPLIER", "Fournisseur Martin")
  VatReturnSpec.sale(customer, [EntrySpec.item("1000", "NOR", account: "706"), EntrySpec.item("100", "TR55", account: "706")])
  VatReturnSpec.purchase(supplier, [EntrySpec.item("500", "NOR", account: "6061")])
  VatReturnSpec.purchase(supplier, [EntrySpec.item("1000", "NOR", account: "201")])
  VatReturnSpec.purchase(supplier, [EntrySpec.item("1000", "INTS", account: "6061")], "2026-03-20")
  FrDataset.new(customer, supplier)
end

describe_module "ACCOUNTING", "Déclarations de TVA françaises" do
  it "calcule la CA3 en euros entiers : TVA brute par taux, autoliquidation, TVA déductible, crédit" do
    fr_dataset
    view = Api.preview_vat_return(system, VatReturnSpec.input("fr_ca3")).value!

    VatReturnSpec.amounts(view).should eq({
      "A1" => d("1100"), "B2" => d("1000"),
      "08.base" => d("2000"), "08.tax" => d("400"), "09.base" => d("100"), "09.tax" => d("6"),
      "16" => d("406"), "17" => d("200"),
      "19" => d("200"), "20" => d("300"), "23" => d("500"),
      "25" => d("94"), "27" => d("94"),
    })
    view.box("08.tax").try(&.label_key).should eq("vat.boxes.fr.08.tax")
    I18n.t("vat.boxes.fr.9B.base").should contain("10 %")
  end

  it "reporte le crédit précédent, déduit le remboursement demandé et liquide vers le crédit de TVA à reporter" do
    fr_dataset
    id = VatReturnSpec.create(VatReturnSpec.input("fr_ca3"))
    view = Api.update_vat_return(system, id, Api::VatReturnUpdateInput.new(adjustments: [
      Api::VatAdjustment.new("22", d("30")), Api::VatAdjustment.new("26", d("100")),
    ])).value!
    view.amount("23").should eq(d("530"))
    view.amount("25").should eq(d("124"))
    view.amount("27").should eq(d("24"))

    closed = Api.close_vat_return(system, id).value!
    entry = Api.entry(system, ReferentialSpec.present(closed.settlement_entry_id))
    EntrySpec.lines_by_account(entry).should eq({
      "445661"   => [{"credit", d("300")}],
      "44566015" => [{"credit", d("200")}],
      "44571"    => [{"debit", d("200")}],
      "44572"    => [{"debit", d("5.50")}],
      "4457015"  => [{"debit", d("200")}],
      # Crédit reporté (22) repris, crédit à reporter (27) : net au crédit.
      "44567" => [{"credit", d("6")}],
      "44583" => [{"debit", d("100")}],
      # Crédit déclaré (94) inférieur au crédit au centime (94,50).
      "658" => [{"debit", d("0.50")}],
    })
  end

  it "liquide une TVA nette due vers la TVA à décaisser" do
    data = fr_dataset
    VatReturnSpec.sale(data.customer, [EntrySpec.item("1000", "NOR", account: "706")], "2026-03-25")
    view = Api.preview_vat_return(system, VatReturnSpec.input("fr_ca3")).value!
    view.amount("16").should eq(d("606"))
    view.amount("28").should eq(d("106"))
    view.amount("32").should eq(d("106"))

    id = VatReturnSpec.create(VatReturnSpec.input("fr_ca3"))
    entry = Api.entry(system, ReferentialSpec.present(Api.close_vat_return(system, id).value!.settlement_entry_id))
    # Montant déclaré (28), écart d'arrondi en charge.
    lines = EntrySpec.lines_by_account(entry)
    lines["44551"].should eq([{"credit", d("106")}])
    lines["658"].should eq([{"debit", d("0.50")}])
  end

  it "déclare la TVA d'un taux exigible à l'encaissement au mois du paiement complet" do
    data = fr_dataset
    services = ReferentialSpec.vat_rate("SERV", "20", label: "Services à l'encaissement", sale_on_payment: true)
    Api.set_vat_rate_accounts(system, Api::VatRateAccountsInput.new(services.id, "445661", "44571")).value!
    %w[08.base 08.tax].each do |box|
      source = box.ends_with?("base") ? "base" : "collected"
      Api.set_vat_box_rules(system, "fr", box, [
        Api::VatBoxRuleInput.new(vat_rate_code: "NOR", ledger_kind: "sale", source: source),
        Api::VatBoxRuleInput.new(vat_rate_code: "SERV", ledger_kind: "sale", source: source),
        Api::VatBoxRuleInput.new(vat_rate_code: "INTS", ledger_kind: "purchase", source: source),
      ]).value!
    end
    invoice = VatReturnSpec.sale(data.customer, [EntrySpec.item("1000", "SERV", account: "706")], "2026-03-10")

    q1 = VatReturnSpec.input("fr_ca3", "quarter", 1)
    q2 = VatReturnSpec.input("fr_ca3", "quarter", 2)
    Api.preview_vat_return(system, q1).value!.amount("08.base").should eq(d("2000"))
    Api.preview_vat_return(system, q1.copy_with(exigibility: "operation")).value!.amount("08.base").should eq(d("3000"))

    # Paiement partiel : rien d'exigible.
    line = invoice.lines.find! { |item| item.card_id == data.customer.id && item.vat_role.nil? }
    Api.post_financial(system, Api::FinancialInput.new(ledger_id: EntrySpec.ledger("F01").id,
      date: EntrySpec.date("2026-04-05"), lines: [Api::PaymentLineInput.new(d("200"), card: data.customer.code,
      match_line_ids: [line.id])])).value!
    Api.preview_vat_return(system, q2).value!.amount("08.base").should eq(d("0"))

    # Solde payé en mai, lettré avec le premier paiement : exigible au
    # deuxième trimestre (date du dernier paiement), pas au premier.
    second = Api.post_financial(system, Api::FinancialInput.new(ledger_id: EntrySpec.ledger("F01").id,
      date: EntrySpec.date("2026-05-12"), lines: [Api::PaymentLineInput.new(d("1000"), card: data.customer.code)])).value!.first
    second_line = second.lines.find! { |item| item.card_id == data.customer.id }.id
    Api.match_lines(system, [line.id, second_line]).value!.balanced?.should be_true
    view = Api.preview_vat_return(system, q2).value!
    view.amount("08.base").should eq(d("1000"))
    view.amount("08.tax").should eq(d("200"))
    Api.preview_vat_return(system, q1).value!.amount("08.base").should eq(d("2000"))
  end

  it "applique l'exigibilité au paiement à tous les taux sur demande" do
    data = fr_dataset
    Api.preview_vat_return(system, VatReturnSpec.input("fr_ca3", exigibility: "payment")).value!
      .amount("A1").should eq(d("0"))
    sale = VatReturnSpec.sale(data.customer, [EntrySpec.item("100", "NOR", account: "706")], "2026-03-01")
    VatReturnSpec.pay(sale, data.customer, "2026-03-15")
    Api.preview_vat_return(system, VatReturnSpec.input("fr_ca3", exigibility: "payment")).value!
      .amount("A1").should eq(d("100"))
  end

  it "calcule la CA12 annuelle : acomptes versés, solde à payer ou excédent" do
    data = fr_dataset
    VatReturnSpec.sale(data.customer, [EntrySpec.item("3000", "NOR", account: "706")], "2026-09-01")
    id = VatReturnSpec.create(VatReturnSpec.input("fr_ca12", "year"))
    view = Api.vat_return(system, id)
    view.amount("16").should eq(d("1006"))
    view.amount("28").should eq(d("506"))
    view.amount("sp").should eq(d("506"))

    adjusted = Api.update_vat_return(system, id, Api::VatReturnUpdateInput.new(
      adjustments: [Api::VatAdjustment.new("ac", d("600"))])).value!
    adjusted.amount("sp").should eq(d("0"))
    adjusted.amount("ex").should eq(d("94"))

    Api.vat_returns(system, form: "fr_ca12").map(&.id).should eq([id])
    Api.vat_returns(system, year: 2025).should be_empty
    Api.vat_return_file(system, id, Api::VatFileFormat::Xml).error_keys
      .should eq(["accounting.errors.vat_return.format.xml"])
    Api.delete_vat_return(system, id).value!
    expect_raises(Partiduo::Api::NotFound) { Api.vat_return(system, id) }
  end

  it "prend des bornes données (exercice décalé) et refuse des bornes inversées" do
    fr_dataset
    view = Api.preview_vat_return(system, VatReturnSpec.input("fr_ca12", "year",
      date_from: EntrySpec.date("2026-03-01"), date_to: EntrySpec.date("2026-03-31"))).value!
    view.amount("B2").should eq(d("1000"))
    view.amount("A1").should eq(d("0"))
    Api.preview_vat_return(system, VatReturnSpec.input("fr_ca12", "year",
      date_from: EntrySpec.date("2026-04-01"), date_to: EntrySpec.date("2026-03-31"))).error_keys
      .should eq(["accounting.errors.vat_return.dates.order"])
  end
end
