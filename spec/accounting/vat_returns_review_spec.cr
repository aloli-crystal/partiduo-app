# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Déclarations de TVA (lot 4, relecture) : exigibilité à l'encaissement
# jamais antérieure à l'opération (avoir lettré avec sa facture, extourne,
# acompte reçu avant la facture), liquidation sur les montants déclarés
# (arrondi à l'euro, acomptes, cases corrigées), liquidation après coup
# d'une déclaration dont les écritures ont changé, chevauchements entre
# formulaires, bornes libres, contrôles des grilles belges et des numéros
# de TVA des fichiers Intervat.

private alias Api = Partiduo::Api::Accounting

private def system
  Partiduo::Api::Actor.system
end

private def d(text : String) : BigDecimal
  BigDecimal.new(text)
end

# Dossier français : une vente au taux normal (février), un taux de
# services exigible à l'encaissement (`SERV`) retenu dans la ligne 08.
private def fr_on_payment : Partiduo::Api::Cards::CardView
  VatReturnSpec.setup("fr")
  customer = VatReturnSpec.card("CUSTOMER", "Client Durand")
  VatReturnSpec.sale(customer, [EntrySpec.item("1000", "NOR", account: "706")])
  services = ReferentialSpec.vat_rate("SERV", "20", label: "Services à l'encaissement", sale_on_payment: true)
  Api.set_vat_rate_accounts(system, Api::VatRateAccountsInput.new(services.id, "445661", "44571")).value!
  %w[08.base 08.tax].each do |box|
    source = box.ends_with?("base") ? "base" : "collected"
    Api.set_vat_box_rules(system, "fr", box, [
      Api::VatBoxRuleInput.new(vat_rate_code: "NOR", ledger_kind: "sale", source: source),
      Api::VatBoxRuleInput.new(vat_rate_code: "SERV", ledger_kind: "sale", source: source),
    ]).value!
  end
  customer
end

private def customer_line(entry : Api::EntryView, customer : Partiduo::Api::Cards::CardView) : Int64
  entry.lines.find! { |line| line.card_id == customer.id && line.vat_role.nil? }.id
end

private def base08(periodicity : String, number : Int32) : BigDecimal
  Api.preview_vat_return(system, VatReturnSpec.input("fr_ca3", periodicity, number)).value!.amount("08.base")
end

describe_module "ACCOUNTING", "Déclarations de TVA : relecture du lot 4" do
  describe "exigibilité à l'encaissement" do
    it "déclare une facture et l'avoir lettré avec elle dans la même période, sans reste" do
      customer = fr_on_payment
      invoice = VatReturnSpec.sale(customer, [EntrySpec.item("1000", "SERV", account: "706")], "2026-02-20")
      credit = VatReturnSpec.sale(customer, [EntrySpec.item("-1000", "SERV", account: "706")], "2026-05-05")
      Api.match_lines(system, [customer_line(invoice, customer), customer_line(credit, customer)]).value!.balanced?
        .should be_true

      base08("quarter", 1).should eq(d("1000"))
      q2 = Api.preview_vat_return(system, VatReturnSpec.input("fr_ca3", "quarter", 2)).value!
      q2.amount("08.base").should eq(d("0"))
      q2.amount("08.tax").should eq(d("0"))
      base08("quarter", 3).should eq(d("0"))
    end

    it "déclare une écriture extournée et son extourne dans la période de l'extourne" do
      customer = fr_on_payment
      invoice = VatReturnSpec.sale(customer, [EntrySpec.item("1000", "SERV", account: "706")], "2026-03-10")
      Api.cancel_entry(system, Api::CancelEntryInput.new(invoice.id, EntrySpec.date("2026-04-15"))).value!

      base08("quarter", 1).should eq(d("1000"))
      base08("quarter", 2).should eq(d("0"))
      Api.preview_vat_return(system, VatReturnSpec.input("fr_ca3", "quarter", 2, exigibility: "operation")).value!
        .amount("08.base").should eq(d("-1000"))
    end

    it "déclare une facture payée d'avance (acompte) au mois de la facture" do
      customer = fr_on_payment
      payment = Api.post_financial(system, Api::FinancialInput.new(ledger_id: EntrySpec.ledger("F01").id,
        date: EntrySpec.date("2026-01-20"), lines: [Api::PaymentLineInput.new(d("1200"), card: customer.code)])).value!.first
      invoice = VatReturnSpec.sale(customer, [EntrySpec.item("1000", "SERV", account: "706")], "2026-02-10")
      Api.match_lines(system, [customer_line(invoice, customer), customer_line(payment, customer)]).value!.balanced?
        .should be_true

      base08("month", 1).should eq(d("0"))
      base08("month", 2).should eq(d("2000"))
      Api.preview_vat_return(system, VatReturnSpec.input("fr_ca3", "month", 2)).value!.amount("08.tax").should eq(d("400"))
      base08("month", 3).should eq(d("0"))
    end

    it "garde le client d'une vente dont la dernière ligne sans TVA ne porte pas de fiche" do
      VatReturnSpec.setup("be")
      client = VatReturnSpec.card("CUSTOMER", "Client Belge", "BE0123456749")
      sale = VatReturnSpec.sale(client, [EntrySpec.item("1000", "21G", account: "700"),
                                         EntrySpec.item("100", nil, account: "740")])
      # Ligne client placée en tête, comme dans une écriture reprise ou
      # générique : la dernière ligne sans TVA (740) ne porte pas de fiche.
      customer = sale.lines.find! { |line| line.card_id == client.id }
      EntrySpec.sql("UPDATE accounting_entry_line SET position = -1 WHERE id = $1", customer.id)
      lines = Api.preview_vat_return(system, VatReturnSpec.input("be_client_listing", "year")).value!.lines
      lines.map { |line| {line.vat_number, line.amount, line.vat} }.should eq([{"BE0123456749", d("1000"), d("210")}])
    end
  end

  describe "liquidation" do
    it "liquide une CA12 sur les montants déclarés : acomptes, solde, excédent et arrondi" do
      VatReturnSpec.setup("fr")
      customer = VatReturnSpec.card("CUSTOMER", "Client Durand")
      VatReturnSpec.sale(customer, [EntrySpec.item("1000", "NOR", account: "706"), EntrySpec.item("100", "TR55", account: "706")])
      id = VatReturnSpec.create(VatReturnSpec.input("fr_ca12", "year"))
      Api.vat_return(system, id).amount("28").should eq(d("206"))
      Api.update_vat_return(system, id, Api::VatReturnUpdateInput.new(
        adjustments: [Api::VatAdjustment.new("ac", d("150"))])).value!.amount("sp").should eq(d("56"))

      entry = Api.entry(system, ReferentialSpec.present(Api.close_vat_return(system, id).value!.settlement_entry_id))
      # TVA déclarée (206) supérieure à la TVA au centime (205,50) : charge.
      lines = EntrySpec.lines_by_account(entry)
      lines["44551"].should eq([{"credit", d("56")}])
      lines["44581"].should eq([{"credit", d("150")}])
      lines["658"].should eq([{"debit", d("0.50")}])
      entry.lines.sum(d("0")) { |line| line.side.debit? ? line.amount : -line.amount }.should eq(d("0"))
    end

    it "prend les comptes d'arrondi donnés et passe un gain d'arrondi en produit" do
      VatReturnSpec.setup("fr")
      supplier = VatReturnSpec.card("SUPPLIER", "Fournisseur Martin")
      AccountingSpec.create_account("6061", "Fournitures non stockables")
      AccountingSpec.create_account("7581", "Produits divers")
      VatReturnSpec.purchase(supplier, [EntrySpec.item("102.50", "NOR", account: "6061")])
      id = VatReturnSpec.create(VatReturnSpec.input("fr_ca3"))
      # TVA déductible 20,50 déclarée 21 : crédit arrondi au-dessus.
      Api.vat_return(system, id).amount("25").should eq(d("21"))
      view = Api.close_vat_return(system, id, Api::VatSettlementInput.new(rounding_income_account: "7581",
        rounding_expense_account: "658")).value!
      lines = EntrySpec.lines_by_account(Api.entry(system, ReferentialSpec.present(view.settlement_entry_id)))
      lines["445661"].should eq([{"credit", d("20.50")}])
      lines["44567"].should eq([{"debit", d("21")}])
      lines["7581"].should eq([{"credit", d("0.50")}])
    end

    it "refuse la liquidation automatique d'une case calculée corrigée ou d'une case sans contrepartie" do
      VatReturnSpec.setup("fr")
      customer = VatReturnSpec.card("CUSTOMER", "Client Durand")
      VatReturnSpec.sale(customer, [EntrySpec.item("1000", "NOR", account: "706")])
      id = VatReturnSpec.create(VatReturnSpec.input("fr_ca3"))
      Api.update_vat_return(system, id, Api::VatReturnUpdateInput.new(
        adjustments: [Api::VatAdjustment.new("08.tax", d("210")), Api::VatAdjustment.new("29", d("5"))])).value!
      refused = Api.close_vat_return(system, id)
      refused.error_keys.should eq(["accounting.errors.vat_return.settlement.adjusted"])
      refused.errors.first.params["codes"].should eq("08.tax, 29")
      Api.vat_return(system, id).status.should eq("draft")

      closed = Api.close_vat_return(system, id, nil).value!
      Api.settle_vat_return(system, id).error_keys.should eq(["accounting.errors.vat_return.settlement.adjusted"])
      closed.settlement_entry_id.should be_nil
    end

    it "refuse la liquidation si la TVA des écritures n'est pas toute reprise par les règles" do
      VatReturnSpec.setup("fr")
      customer = VatReturnSpec.card("CUSTOMER", "Client Durand")
      VatReturnSpec.sale(customer, [EntrySpec.item("1000", "NOR", account: "706")])
      Api.set_vat_box_rules(system, "fr", "08.tax", [] of Api::VatBoxRuleInput).value!
      id = VatReturnSpec.create(VatReturnSpec.input("fr_ca3"))
      Api.close_vat_return(system, id).error_keys.should eq(["accounting.errors.vat_return.settlement.mismatch"])
    end

    it "refuse de liquider après coup une déclaration dont les écritures ont changé depuis la clôture" do
      VatReturnSpec.setup("be")
      client = VatReturnSpec.card("CUSTOMER", "Client Belge", "BE0123456749")
      VatReturnSpec.sale(client, [EntrySpec.item("1000", "21G", account: "700")])
      id = Api.close_vat_return(system, VatReturnSpec.create(VatReturnSpec.input("be_periodic")), nil).value!.id
      VatReturnSpec.sale(client, [EntrySpec.item("50", "21G", account: "700")], "2026-03-20")
      Api.settle_vat_return(system, ReferentialSpec.present(id)).error_keys
        .should eq(["accounting.errors.vat_return.settle_stale"])
    end
  end

  describe "chevauchements et concurrence" do
    it "refuse une CA12 sur une période couverte par une CA3 close, et l'inverse" do
      VatReturnSpec.setup("fr")
      ca3 = VatReturnSpec.create(VatReturnSpec.input("fr_ca3", "month", 3))
      Api.close_vat_return(system, ca3, nil).value!
      Api.create_vat_return(system, VatReturnSpec.input("fr_ca12", "year")).error_keys
        .should eq(["accounting.errors.vat_return.overlap"])
      Api.create_vat_return(system, VatReturnSpec.input("fr_ca3", "quarter", 1)).error_keys
        .should eq(["accounting.errors.vat_return.overlap"])
      VatReturnSpec.create(VatReturnSpec.input("fr_ca3", "quarter", 2))
    end

    it "n'admet qu'un brouillon par formulaire et par période, en base" do
      VatReturnSpec.setup("be")
      insert = "INSERT INTO vat_return (regime, form, year, periodicity, period_number, date_from, date_to, " \
               "exigibility, status, client_listing_nihil, ask_restitution, created_at, updated_at) " \
               "VALUES ('be', 'be_periodic', 2026, 'month', 1, '2026-01-01', '2026-01-31', 'rates', 'draft', " \
               "false, false, now(), now())"
      expect_raises(Exception, /vat_return_draft_unique/) do
        EntrySpec.sql_transaction do |db|
          db.exec(insert)
          db.exec(insert)
        end
      end
    end
  end

  describe "paramètres et fichiers" do
    it "refuse des bornes libres hors CA12, admet celles de la période" do
      VatReturnSpec.setup("be")
      refused = Api.preview_vat_return(system, VatReturnSpec.input("be_periodic",
        date_from: EntrySpec.date("2026-01-15")))
      refused.error_keys.should eq(["accounting.errors.vat_return.dates.not_allowed"])
      refused.errors.first.field.should eq("date_from")
      Api.preview_vat_return(system, VatReturnSpec.input("be_intra_listing", "month", 1,
        date_to: EntrySpec.date("2026-02-28"))).error_keys.should eq(["accounting.errors.vat_return.dates.not_allowed"])
      Api.preview_vat_return(system, VatReturnSpec.input("be_periodic", date_from: EntrySpec.date("2026-01-01"),
        date_to: EntrySpec.date("2026-03-31"))).value!.date_to.should eq(EntrySpec.date("2026-03-31"))
    end

    it "refuse une grille belge négative" do
      VatReturnSpec.setup("be")
      id = VatReturnSpec.create(VatReturnSpec.input("be_periodic"))
      refused = Api.update_vat_return(system, id, Api::VatReturnUpdateInput.new(
        adjustments: [Api::VatAdjustment.new("61", d("-1"))]))
      refused.error_keys.should eq(["accounting.errors.vat_return.box.negative"])
      refused.errors.first.field.should eq("adjustments[0].amount")
    end

    it "refuse le fichier Intervat d'un listing dont un client a un numéro de TVA invalide" do
      VatReturnSpec.setup("be")
      client = VatReturnSpec.card("CUSTOMER", "Client Erroné", "BE0123456749")
      VatReturnSpec.sale(client, [EntrySpec.item("1000", "21G", account: "700")])
      id = VatReturnSpec.create(VatReturnSpec.input("be_client_listing", "year"))
      # Numéro repris d'une reprise de données, sans contrôle de la fiche.
      EntrySpec.sql("UPDATE vat_return_line SET vat_number = 'BE0123456789' WHERE vat_return_id = $1", id)
      refused = Api.vat_return_file(system, id, Api::VatFileFormat::Xml)
      refused.error_keys.should eq(["accounting.errors.vat_return.client_vat_number"])
      refused.errors.first.field.should eq("lines[0].vat_number")
      Api.vat_return_file(system, id, Api::VatFileFormat::Csv).value!
    end

    it "refuse le fichier Intervat sans numéro de TVA belge valide pour la société" do
      VatReturnSpec.setup("be")
      id = VatReturnSpec.create(VatReturnSpec.input("be_periodic"))
      Api.vat_return_file(system, id, Api::VatFileFormat::Xml).value!
      settings = Partiduo::Core::Settings.all.first!
      settings.vat_number = ""
      settings.save!
      refused = Api.vat_return_file(system, id, Api::VatFileFormat::Xml)
      refused.error_keys.should eq(["accounting.errors.vat_return.declarant_vat_number"])
      refused.errors.first.field.should eq("vat_number")
    end

    it "refuse de revenir aux règles par défaut d'un régime inconnu" do
      VatReturnSpec.setup("be")
      Api.reset_vat_box_rules(system, "de").error_keys.should eq(["accounting.errors.vat_rule.regime.invalid"])
    end

    it "range les biens d'investissement (classes 20 à 27) en 83 et les autres achats hors 60 en 82" do
      VatReturnSpec.setup("be")
      supplier = VatReturnSpec.card("SUPPLIER", "Fournisseur")
      AccountingSpec.create_account("2100", "Logiciels")
      AccountingSpec.create_account("2600", "Mobilier")
      VatReturnSpec.purchase(supplier, [EntrySpec.item("300", "21G", account: "2100"),
                                        EntrySpec.item("200", "21G", account: "2600"),
                                        EntrySpec.item("100", "21G", account: "604"),
                                        EntrySpec.item("50", "21G", account: "640")])
      view = Api.preview_vat_return(system, VatReturnSpec.input("be_periodic")).value!
      view.amount("81").should eq(d("100"))
      view.amount("82").should eq(d("50"))
      view.amount("83").should eq(d("500"))
    end
  end
end
