# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Achats et ventes avec TVA (`Acc_Ledger_Purchase::insert`,
# `Acc_Ledger_Sale::insert`, `Acc_Compute::compute_vat`, `tva_rate.tva_poste`),
# d'après `acc_ledger_purchaseTest.php`, `acc_ledger_saleTest.php` et
# `acc_computeTest.php`.

private alias Api = Partiduo::Api::Accounting

private def system
  Partiduo::Api::Actor.system
end

private def d(text : String) : BigDecimal
  BigDecimal.new(text)
end

describe_module "ACCOUNTING", "Achats et ventes avec TVA" do
  describe ".post_purchase" do
    it "ventile hors taxe, TVA déductible et fournisseur (TVA calculée par taux)" do
      EntrySpec.setup
      supplier = EntrySpec.card("SUPPLIER", "Papeterie Durand")
      paper = EntrySpec.card("PURCHASE", "Papier")
      input = EntrySpec.document("A01", supplier.code, [
        EntrySpec.item("100", item: paper.code),
        EntrySpec.item("50", "TR55", account: "603", label: "Livres"),
        EntrySpec.item("0", item: paper.code), # ligne vide ignorée
      ], due_date: EntrySpec.date("2026-04-14"), label: "Facture 118")

      view = Api.post_purchase(system, input).value!

      lines = EntrySpec.lines_by_account(view)
      lines[EntrySpec.card_account(paper)].should eq([{"debit", d("100")}])
      lines["603"].should eq([{"debit", d("50")}])
      lines["445661"].should eq([{"debit", d("20.00")}])
      lines["445662"].should eq([{"debit", d("2.75")}])
      lines[EntrySpec.card_account(supplier)].should eq([{"credit", d("172.75")}])
      view.amount.should eq(d("172.75"))
      view.ledger_kind.purchase?.should be_true
      view.due_date.should eq(EntrySpec.date("2026-04-14"))
      view.label.should eq("Facture 118")

      base = view.lines.find! { |line| line.account_number == "603" }
      base.vat_rate_code.should eq("TR55")
      base.vat_role.should eq("base")
      view.lines.find! { |line| line.account_number == "445661" }.vat_role.should eq("tax")
      view.lines.last.card_id.should eq(supplier.id)
      view.lines.first.card_id.should eq(paper.id)
    end

    it "calcule la TVA au demi-centime supérieur (Acc_Compute, 1212,5 × 21 % = 254,63)" do
      EntrySpec.setup("be")
      supplier = EntrySpec.card("SUPPLIER", "Leverancier")
      view = Api.post_purchase(system, EntrySpec.document("A01", supplier.code, [
        EntrySpec.item("1212.5", "21G", account: "604"),
      ])).value!
      EntrySpec.lines_by_account(view)["4111"].should eq([{"debit", d("254.63")}])
      view.amount.should eq(d("1467.13"))
    end

    it "prend la TVA saisie et le prix unitaire × quantité (e_march_price, e_quant)" do
      EntrySpec.setup
      supplier = EntrySpec.card("SUPPLIER", "Grossiste")
      view = Api.post_purchase(system, EntrySpec.document("A01", supplier.code, [
        EntrySpec.item("0", account: "603", unit_price: d("33.333"), quantity: d("3")),
        EntrySpec.item("10", account: "603", vat_amount: d("1.99")),
      ])).value!
      view.lines.select { |line| line.account_number == "603" }.map(&.amount).should eq([d("100.00"), d("10")])
      view.lines.find! { |line| line.account_number == "603" }.quantity.should eq(d("3"))
      EntrySpec.lines_by_account(view)["445661"].should eq([{"debit", d("21.99")}])
    end

    it "passe la TVA autoliquidée au débit et au crédit, hors du fournisseur (tva_both_side)" do
      EntrySpec.setup
      supplier = EntrySpec.card("SUPPLIER", "Supplier GmbH")
      view = Api.post_purchase(system, EntrySpec.document("A01", supplier.code, [
        EntrySpec.item("1000", "INTS", account: "603"),
      ])).value!
      lines = EntrySpec.lines_by_account(view)
      lines["44566015"].should eq([{"debit", d("200.00")}])
      lines["4457015"].should eq([{"credit", d("200.00")}])
      lines[EntrySpec.card_account(supplier)].should eq([{"credit", d("1000")}])
      view.total_debit.should eq(d("1200.00"))
    end

    it "inverse les sens d'un avoir (montants négatifs, insert_jrnx)" do
      EntrySpec.setup
      supplier = EntrySpec.card("SUPPLIER", "Papeterie Durand")
      view = Api.post_purchase(system, EntrySpec.document("A01", supplier.code, [
        EntrySpec.item("-100", account: "603"),
      ])).value!
      lines = EntrySpec.lines_by_account(view)
      lines["603"].should eq([{"credit", d("100")}])
      lines["445661"].should eq([{"credit", d("20.00")}])
      lines[EntrySpec.card_account(supplier)].should eq([{"debit", d("120.00")}])
    end

    it "refuse avec des erreurs par champ (verify_operation)" do
      EntrySpec.setup
      Partiduo::Api::Vat.create_rate(system, Partiduo::Api::Vat::RateInput.new(code: "SANS", label: "Sans compte",
        rate: d("7"))).value!
      input = EntrySpec.document("A01", "INCONNU", [
        EntrySpec.item("10", "XX", account: "603"),
        EntrySpec.item("10", "SANS", account: "603"),
        EntrySpec.item("10.12345", account: "603"),
        EntrySpec.item("10", nil, account: "603", vat_amount: d("2")),
        EntrySpec.item("10", item: "NOPE"),
      ])
      result = Api.post_purchase(system, input)
      result.errors_for("third_party").map(&.key).should eq(["accounting.errors.entry.card.not_found"])
      result.errors_for("lines[0].vat_rate").map(&.key).should eq(["accounting.errors.entry.vat_rate.not_found"])
      result.errors_for("lines[1].vat_rate").map(&.key).should eq(["accounting.errors.entry.vat_rate.no_account"])
      result.errors_for("lines[2].amount").map(&.key).should eq(["accounting.errors.entry.too_many_decimals"])
      result.errors_for("lines[3].vat_rate").map(&.key).should eq(["accounting.errors.entry.vat_rate.required"])
      result.errors_for("lines[4].item").map(&.key).should eq(["accounting.errors.entry.card.not_found"])
      ReferentialSpec.expect_translated(result)

      supplier = EntrySpec.card("SUPPLIER", "Fournisseur")
      Api.post_purchase(system, EntrySpec.document("A01", supplier.code, [EntrySpec.item("0")]))
        .error_keys.should eq(["accounting.errors.entry.no_items"])
      Api.post_purchase(system, EntrySpec.document("A01", " ", [EntrySpec.item("1", account: "603")]))
        .error_keys.should eq(["accounting.errors.entry.third_party.required"])
      Api.post_purchase(system, EntrySpec.document("V01", supplier.code, [EntrySpec.item("1", account: "603")]))
        .error_keys.should eq(["accounting.errors.entry.ledger.not_purchase"])
    end
  end

  describe ".post_sale" do
    it "ventile hors taxe et TVA collectée au crédit, client toutes taxes au débit" do
      EntrySpec.setup
      customer = EntrySpec.card("CUSTOMER", "Client Dupont")
      service = EntrySpec.card("SALE", "Conseil")
      view = Api.post_sale(system, EntrySpec.document("V01", customer.code, [
        EntrySpec.item("1000", item: service.code),
        EntrySpec.item("200", "INT", item: service.code),
      ], source: "invoice:7")).value!
      lines = EntrySpec.lines_by_account(view)
      lines[EntrySpec.card_account(service)].should eq([{"credit", d("1000")}, {"credit", d("200")}])
      # Une ligne de TVA par taux (NOR, INT), même sur un compte commun.
      lines["44571"].should eq([{"credit", d("200.00")}, {"credit", d("20.00")}])
      lines[EntrySpec.card_account(customer)].should eq([{"debit", d("1420.00")}])
      view.source.should eq("invoice:7")
      view.receipt.should eq(EntrySpec.ledger("V01").receipt_prefix + "1".rjust(EntrySpec.ledger("V01").receipt_padding, '0'))
    end

    it "refuse un journal d'achats" do
      EntrySpec.setup
      customer = EntrySpec.card("CUSTOMER", "Client")
      Api.post_sale(system, EntrySpec.document("A01", customer.code, [EntrySpec.item("1", account: "706")]))
        .error_keys.should eq(["accounting.errors.entry.ledger.not_sale"])
    end
  end

  describe ".check_document" do
    it "calcule lignes et totaux sans écrire (retour instantané)" do
      EntrySpec.setup
      customer = EntrySpec.card("CUSTOMER", "Client")
      draft = Api.check_document(system, EntrySpec.document("V01", customer.code, [
        EntrySpec.item("100", account: "706"), EntrySpec.item("100", "TR55", account: "706"),
      ])).value!
      draft.total_excluding_vat.should eq(d("200"))
      draft.total_vat.should eq(d("25.50"))
      draft.total_including_vat.should eq(d("225.50"))
      draft.balanced?.should be_true
      draft.lines.map(&.vat_role).should eq(["base", "base", "tax", "tax", nil])
      Api.count_entries(system).should eq(0)
    end

    it "refuse un journal financier" do
      EntrySpec.setup
      customer = EntrySpec.card("CUSTOMER", "Client")
      Api.check_document(system, EntrySpec.document("F01", customer.code, [EntrySpec.item("1", account: "706")]))
        .error_keys.should eq(["accounting.errors.entry.ledger.not_document"])
    end
  end
end
