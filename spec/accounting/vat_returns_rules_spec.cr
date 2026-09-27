# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Déclarations de TVA (lot 4), cas limites et règles de gestion reprises de
# l'extension TVA de noalyss-plugins : seuil du listing des clients
# (`Ext_List_Assujetti::get_data`, `amount < amount_min` écarté), relevé
# intracommunautaire par code (`Ext_List_Intra`), chevauchements et
# liquidation (`Ext_Tva::propose_form`), contrôles des paramètres et des
# règles (`parameter_chld`), mandataire (`representative`), droits.

private alias Api = Partiduo::Api::Accounting

private def system
  Partiduo::Api::Actor.system
end

private def d(text : String) : BigDecimal
  BigDecimal.new(text)
end

private def be_basic : Partiduo::Api::Cards::CardView
  VatReturnSpec.setup("be")
  client = VatReturnSpec.card("CUSTOMER", "Client Belge", "BE0123456749")
  VatReturnSpec.sale(client, [EntrySpec.item("1000", "21G", account: "700")])
  client
end

describe_module "ACCOUNTING", "Déclarations de TVA : règles de gestion et cas limites" do
  describe "listing des clients assujettis" do
    it "retient un client au seuil exact, écarte ceux sous le seuil, sans numéro ou hors Belgique" do
      VatReturnSpec.setup("be")
      exact = VatReturnSpec.card("CUSTOMER", "Au Seuil", "BE0400000086")
      below = VatReturnSpec.card("CUSTOMER", "Sous le Seuil", "BE0400000185")
      credited = VatReturnSpec.card("CUSTOMER", "Avoir", "BE0123456749")
      none = VatReturnSpec.card("CUSTOMER", "Particulier")
      foreign = VatReturnSpec.card("CUSTOMER", "Client Français", "FR44732829320")
      VatReturnSpec.sale(exact, [EntrySpec.item("250", "21G", account: "700")])
      VatReturnSpec.sale(below, [EntrySpec.item("249.99", "21G", account: "700")])
      VatReturnSpec.sale(credited, [EntrySpec.item("400", "21G", account: "700")])
      VatReturnSpec.sale(credited, [EntrySpec.item("-200", "21G", account: "700")], "2026-05-02")
      VatReturnSpec.sale(none, [EntrySpec.item("5000", "21G", account: "700")])
      VatReturnSpec.sale(foreign, [EntrySpec.item("5000", "21G", account: "700")])

      view = Api.preview_vat_return(system, VatReturnSpec.input("be_client_listing", "year")).value!
      view.lines.map { |line| {line.card_id, line.amount, line.vat} }.should eq([{exact.id, d("250"), d("52.50")}])
      view.lines.first.card_code.should eq(exact.code)

      # Seuil nul : tous les assujettis belges, avoirs déduits.
      lines = Api.preview_vat_return(system, VatReturnSpec.input("be_client_listing", "year",
        threshold: d("0"))).value!.lines
      lines.map { |line| {line.vat_number, line.amount} }.should eq([
        {"BE0123456749", d("200")}, {"BE0400000086", d("250")}, {"BE0400000185", d("249.99")},
      ])
      Api.preview_vat_return(system, VatReturnSpec.input("be_client_listing", "year", threshold: d("-1")))
        .error_keys.should eq(["accounting.errors.vat_return.threshold.negative"])
    end

    it "sans client à déclarer, garde une déclaration vide et le fichier sans client" do
      VatReturnSpec.setup("be")
      view = Api.create_vat_return(system, VatReturnSpec.input("be_client_listing", "year")).value!
      view.lines.should be_empty
      text = String.new(Api.vat_return_file(system, ReferentialSpec.present(view.id), Api::VatFileFormat::Xml).value!.content)
      text.should contain(%(ClientsNbr="0"))
      Api.close_vat_return(system, ReferentialSpec.present(view.id)).value!.settlement_entry_id.should be_nil
    end

    it "refuse de clore un listing dont les écritures ont changé, puis le recalcule" do
      client = be_basic
      id = VatReturnSpec.create(VatReturnSpec.input("be_client_listing", "year"))
      VatReturnSpec.sale(client, [EntrySpec.item("100", "21G", account: "700")], "2026-11-02")
      Api.close_vat_return(system, id).error_keys.should eq(["accounting.errors.vat_return.stale"])
      Api.recompute_vat_return(system, id).value!.lines.first.amount.should eq(d("1100"))
      Api.close_vat_return(system, id).value!.closed?.should be_true
    end
  end

  describe "relevé intracommunautaire" do
    it "sépare livraisons de biens (L) et services (S) selon les règles, sans client belge ni sans numéro" do
      VatReturnSpec.setup("be")
      AccountingSpec.create_account("7061", "Prestations de services")
      foreign = VatReturnSpec.card("CUSTOMER", "Client Français", "FR44732829320")
      german = VatReturnSpec.card("CUSTOMER", "Kunde", "DE136695976")
      belgian = VatReturnSpec.card("CUSTOMER", "Client Belge", "BE0123456749")
      anonymous = VatReturnSpec.card("CUSTOMER", "Sans numéro")
      VatReturnSpec.sale(foreign, [EntrySpec.item("2000", "INTL", account: "700"), EntrySpec.item("500", "INTL", account: "7061")])
      VatReturnSpec.sale(german, [EntrySpec.item("300", "INTL", account: "700")])
      VatReturnSpec.sale(belgian, [EntrySpec.item("100", "INTL", account: "700")])
      VatReturnSpec.sale(anonymous, [EntrySpec.item("100", "INTL", account: "700")])

      Api.set_vat_box_rules(system, "be", "intra_l", [
        Api::VatBoxRuleInput.new(vat_rate_code: "INTL", ledger_kind: "sale", excluded_accounts: "7061"),
      ]).value!
      Api.set_vat_box_rules(system, "be", "intra_s", [
        Api::VatBoxRuleInput.new(vat_rate_code: "INTL", ledger_kind: "sale", accounts: "7061"),
      ]).value!

      view = Api.preview_vat_return(system, VatReturnSpec.input("be_intra_listing", "quarter", 1)).value!
      view.lines.map { |line| {line.vat_number, line.code, line.amount} }.should eq([
        {"DE136695976", "L", d("300")}, {"FR44732829320", "L", d("2000")}, {"FR44732829320", "S", d("500")},
      ])
      Api.preview_vat_return(system, VatReturnSpec.input("be_intra_listing", "year")).error_keys
        .should eq(["accounting.errors.vat_return.periodicity.invalid"])
    end
  end

  describe "chevauchements et doublons" do
    it "refuse de clore une déclaration dont la période chevauche une déclaration close du même formulaire" do
      be_basic
      month = VatReturnSpec.create(VatReturnSpec.input("be_periodic", "month", 1))
      quarter = VatReturnSpec.create(VatReturnSpec.input("be_periodic", "quarter", 1))
      april = VatReturnSpec.create(VatReturnSpec.input("be_periodic", "month", 4))
      Api.close_vat_return(system, quarter, nil).value!

      Api.close_vat_return(system, month, nil).error_keys.should eq(["accounting.errors.vat_return.overlap"])
      Api.close_vat_return(system, april, nil).value!.closed?.should be_true
      # Un autre formulaire n'est pas concerné.
      intra = VatReturnSpec.create(VatReturnSpec.input("be_intra_listing", "month", 1))
      Api.close_vat_return(system, intra).value!.closed?.should be_true
      # Le brouillon chevauchant reste supprimable.
      Api.delete_vat_return(system, month).value!
      Api.vat_returns(system, form: "be_periodic").map(&.id).should eq([april, quarter])
    end

    it "admet un brouillon d'une autre période, et un nouveau brouillon après suppression" do
      be_basic
      first = VatReturnSpec.create(VatReturnSpec.input("be_periodic", "month", 1))
      VatReturnSpec.create(VatReturnSpec.input("be_periodic", "month", 2))
      Api.delete_vat_return(system, first).value!
      EntrySpec.scalar("SELECT count(*) FROM vat_return_box WHERE vat_return_id = $1", first).should eq(0)
      VatReturnSpec.create(VatReturnSpec.input("be_periodic", "month", 1))
    end
  end

  describe "liquidation" do
    it "refuse de liquider un brouillon, un relevé ou une déclaration sans TVA" do
      be_basic
      draft = VatReturnSpec.create(VatReturnSpec.input("be_periodic"))
      Api.settle_vat_return(system, draft).error_keys.should eq(["accounting.errors.vat_return.not_closed"])

      listing = VatReturnSpec.create(VatReturnSpec.input("be_client_listing", "year"))
      Api.close_vat_return(system, listing).value!
      Api.settle_vat_return(system, listing).error_keys.should eq(["accounting.errors.vat_return.not_settled_form"])

      empty = VatReturnSpec.create(VatReturnSpec.input("be_periodic", "quarter", 3))
      Api.close_vat_return(system, empty).value!.settlement_entry_id.should be_nil
      Api.settle_vat_return(system, empty).error_keys.should eq(["accounting.errors.vat_return.nothing_to_settle"])
    end

    it "laisse le brouillon intact si l'écriture de liquidation est refusée (période close, journal absent)" do
      be_basic
      id = VatReturnSpec.create(VatReturnSpec.input("be_periodic"))
      Partiduo::Api::Core.close_period(system, EntrySpec.period("2026-03-31").id).value!

      refused = Api.close_vat_return(system, id)
      refused.error_keys.should eq(["accounting.errors.entry.date.period_closed"])
      refused.errors.first.field.should eq("settlement.date")
      Api.vat_return(system, id).status.should eq("draft")
      EntrySpec.scalar("SELECT count(*) FROM accounting_entry WHERE source = $1", "vat_return:#{id}").should eq(0)

      Api.close_vat_return(system, id, Api::VatSettlementInput.new(ledger_id: 999_999_i64)).error_keys
        .should eq(["accounting.errors.vat_return.settlement.ledger_missing"])

      view = Api.close_vat_return(system, id, Api::VatSettlementInput.new(date: EntrySpec.date("2026-04-10"))).value!
      Api.entry(system, ReferentialSpec.present(view.settlement_entry_id)).date.should eq(EntrySpec.date("2026-04-10"))
    end

    it "prend les comptes de liquidation donnés et n'inclut pas l'écriture de liquidation dans les soldes" do
      be_basic
      EntrySpec.post_misc([EntrySpec.debit("640", "15"), EntrySpec.credit("4519", "15")], "2026-03-10")
      Api.set_vat_box_rules(system, "be", "61", [
        Api::VatBoxRuleInput.new(ledger_kind: "misc", accounts: "451", source: "balance", operation: "subtract"),
      ]).value!
      id = VatReturnSpec.create(VatReturnSpec.input("be_periodic"))
      Api.vat_return(system, id).amount("61").should eq(d("15"))

      view = Api.close_vat_return(system, id, Api::VatSettlementInput.new(payable_account: "4512")).value!
      entry = Api.entry(system, ReferentialSpec.present(view.settlement_entry_id))
      EntrySpec.lines_by_account(entry)["4512"].should eq([{"credit", d("210")}])
      # L'écriture de liquidation (O01, 451…) ne modifie pas la grille 61.
      Api.preview_vat_return(system, VatReturnSpec.input("be_periodic")).value!.amount("61").should eq(d("15"))
    end
  end

  describe "exigibilité" do
    it "au paiement, n'inclut pas un achat impayé et le déclare au trimestre de son paiement" do
      VatReturnSpec.setup("be")
      supplier = VatReturnSpec.card("SUPPLIER", "Fournisseur")
      purchase = VatReturnSpec.purchase(supplier, [EntrySpec.item("400", "21G", account: "604")], "2026-03-10")
      q1 = VatReturnSpec.input("be_periodic", exigibility: "payment")
      Api.preview_vat_return(system, q1).value!.amount("81").should eq(d("0"))
      Api.preview_vat_return(system, VatReturnSpec.input("be_periodic")).value!.amount("81").should eq(d("400"))

      VatReturnSpec.pay(purchase, supplier, "2026-04-03")
      Api.preview_vat_return(system, q1).value!.amount("81").should eq(d("0"))
      q2 = Api.preview_vat_return(system, VatReturnSpec.input("be_periodic", number: 2, exigibility: "payment")).value!
      q2.amount("81").should eq(d("400"))
      q2.amount("59").should eq(d("84"))
      q2.amount("72").should eq(d("84"))
      Api.preview_vat_return(system, VatReturnSpec.input("be_periodic", exigibility: "nope")).error_keys
        .should eq(["accounting.errors.vat_return.exigibility.invalid"])
    end
  end

  describe "paramètres" do
    it "contrôle l'année et les bornes, et ramène un mois donné à la période annuelle" do
      be_basic
      Api.preview_vat_return(system, Api::VatReturnInput.new(form: "be_periodic", year: 1800)).error_keys
        .should eq(["accounting.errors.vat_return.year.invalid"])
      Api.preview_vat_return(system, VatReturnSpec.input("be_periodic", "month", 0)).error_keys
        .should eq(["accounting.errors.vat_return.number.invalid"])
      view = Api.preview_vat_return(system, VatReturnSpec.input("be_client_listing", "year", 7)).value!
      view.number.should eq(1)
      view.date_to.should eq(EntrySpec.date("2026-12-31"))
      february = Api.preview_vat_return(system, VatReturnSpec.input("be_periodic", "month", 2)).value!
      february.date_to.should eq(EntrySpec.date("2026-02-28"))
      february.amount("03").should eq(d("1000"))
      Api.preview_vat_return(system, VatReturnSpec.input(" BE_PERIODIC ", " Month ", 2)).value!.form
        .should eq("be_periodic")
    end

    it "contrôle le mandataire des fichiers Intervat et l'efface avec un nom vide" do
      be_basic
      refused = Api.update_vat_settings(system, Api::VatSettingsInput.new(representative_name: "Fiduciaire",
        representative_issued_by: "Belgique", representative_country_code: "B1"))
      refused.error_keys.should eq(["accounting.errors.vat_settings.representative_id.required",
                                    "accounting.errors.vat_settings.country.invalid",
                                    "accounting.errors.vat_settings.country.invalid"])
      Api.vat_settings(system).representative?.should be_false

      Api.update_vat_settings(system, Api::VatSettingsInput.new(representative_name: " Fiduciaire ",
        representative_id: "0123456749", representative_issued_by: "be", representative_id_type: "tin")).value!
        .representative_id_type.should eq("TIN")
      id = VatReturnSpec.create(VatReturnSpec.input("be_periodic"))
      String.new(Api.vat_return_file(system, id, Api::VatFileFormat::Xml).value!.content).should contain("Representative")

      Api.update_vat_settings(system, Api::VatSettingsInput.new).value!.representative?.should be_false
      EntrySpec.scalar("SELECT count(*) FROM vat_setting").should eq(1)
      String.new(Api.vat_return_file(system, id, Api::VatFileFormat::Xml).value!.content).should_not contain("Representative")
    end

    it "contrôle les règles : régime, taux, journal et nature, source d'un document" do
      be_basic
      Api.vat_box_rules(system, "de").should be_empty
      Api.set_vat_box_rules(system, "de", "03", [] of Api::VatBoxRuleInput).error_keys
        .should eq(["accounting.errors.vat_rule.regime.invalid"])
      Api.set_vat_box_rules(system, "be", "03", [
        Api::VatBoxRuleInput.new(vat_rate_code: "ZZZ"),
        Api::VatBoxRuleInput.new(ledger_kind: "sale", ledger_code: "A01"),
        Api::VatBoxRuleInput.new(ledger_kind: "misc", source: "base"),
        Api::VatBoxRuleInput.new(sign: "both", operation: "multiply"),
      ]).error_keys.should eq([
        "accounting.errors.vat_rule.vat_rate_code.not_found", "accounting.errors.vat_rule.ledger_code.kind",
        "accounting.errors.vat_rule.ledger_kind.document", "accounting.errors.vat_rule.sign.invalid",
        "accounting.errors.vat_rule.operation.invalid",
      ])
      # Rien n'est enregistré après un refus.
      Api.vat_box_rules(system, "be").all?(&.default).should be_true

      # Le journal donne sa nature ; les préfixes « 60% » sont admis.
      rule = Api.set_vat_box_rules(system, "be", "03", [
        Api::VatBoxRuleInput.new(ledger_code: "v01", accounts: "70%", vat_rate_code: "21g"),
      ]).value!.first
      rule.ledger_kind.should eq("sale")
      rule.ledger_code.should eq("V01")
      rule.accounts.should eq("70")
      rule.vat_rate_code.should eq("21G")
      Api.preview_vat_return(system, VatReturnSpec.input("be_periodic")).value!.amount("03").should eq(d("1000"))
      # Le paramétrage français n'est pas touché.
      Api.vat_box_rules(system, "fr").all?(&.default).should be_true
    end
  end

  describe "corrections" do
    it "n'admet que des euros entiers dans une déclaration française, des centimes en Belgique" do
      VatReturnSpec.setup("fr")
      id = VatReturnSpec.create(VatReturnSpec.input("fr_ca3"))
      refused = Api.update_vat_return(system, id, Api::VatReturnUpdateInput.new(
        adjustments: [Api::VatAdjustment.new("22", d("10.50"))]))
      refused.error_keys.should eq(["accounting.errors.vat_return.box.whole_euros"])
      refused.errors.first.field.should eq("adjustments[0].amount")
      view = Api.update_vat_return(system, id, Api::VatReturnUpdateInput.new(
        adjustments: [Api::VatAdjustment.new("22", d("10.00"))])).value!
      view.amount("22").should eq(d("10"))
      view.amount("25").should eq(d("10"))
    end

    it "garde les corrections d'un brouillon recalculé et recalcule ses totaux" do
      client = be_basic
      id = VatReturnSpec.create(VatReturnSpec.input("be_periodic"))
      Api.update_vat_return(system, id, Api::VatReturnUpdateInput.new(
        adjustments: [Api::VatAdjustment.new("59", d("10.25"))])).value!.amount("71").should eq(d("199.75"))
      VatReturnSpec.sale(client, [EntrySpec.item("100", "21G", account: "700")], "2026-03-20")
      view = Api.recompute_vat_return(system, id).value!
      view.amount("54").should eq(d("231"))
      view.box("59").try(&.adjusted).should be_true
      view.amount("71").should eq(d("220.75"))
      Api.update_vat_return(system, id, Api::VatReturnUpdateInput.new(
        adjustments: [Api::VatAdjustment.new("nope", d("1"))])).error_keys
        .should eq(["accounting.errors.vat_return.box.not_editable"])
    end
  end

  describe "contrôles en base" do
    it "fige les cases et les lignes d'une déclaration close, pas celles d'un brouillon" do
      be_basic
      draft = VatReturnSpec.create(VatReturnSpec.input("be_client_listing", "year"))
      EntrySpec.sql_transaction { |db| db.exec("UPDATE vat_return_line SET amount = 1 WHERE vat_return_id = $1", draft) }
      closed = VatReturnSpec.create(VatReturnSpec.input("be_periodic"))
      Api.close_vat_return(system, closed, nil).value!

      expect_raises(Exception, /modification interdite/) do
        EntrySpec.sql_transaction do |db|
          db.exec("INSERT INTO vat_return_box (vat_return_id, code, computed, amount, adjusted) VALUES ($1, 'zz', 0, 0, false)", closed)
        end
      end
      expect_raises(Exception, /modification interdite/) do
        EntrySpec.sql_transaction { |db| db.exec("DELETE FROM vat_return_box WHERE vat_return_id = $1", closed) }
      end
      expect_raises(Exception, /close, modification interdite/) do
        EntrySpec.sql_transaction { |db| db.exec("UPDATE vat_return SET status = 'draft', closed_at = NULL WHERE id = $1", closed) }
      end
    end

    it "n'admet l'écriture de liquidation qu'une fois, sans autre changement" do
      be_basic
      id = Api.close_vat_return(system, VatReturnSpec.create(VatReturnSpec.input("be_periodic")), nil).value!.id
      entry_id = EntrySpec.scalar("SELECT max(id) FROM accounting_entry").as(Int64)

      expect_raises(Exception, /modification interdite/) do
        EntrySpec.sql_transaction do |db|
          db.exec("UPDATE vat_return SET settlement_entry_id = $1, ask_restitution = true WHERE id = $2", entry_id, id)
        end
      end
      EntrySpec.sql_transaction { |db| db.exec("UPDATE vat_return SET settlement_entry_id = $1 WHERE id = $2", entry_id, id) }
      expect_raises(Exception, /modification interdite/) do
        EntrySpec.sql_transaction { |db| db.exec("UPDATE vat_return SET settlement_entry_id = NULL WHERE id = $1", id) }
      end
    end

    it "contrôle l'état, les bornes, le formulaire et l'unicité d'une déclaration close" do
      be_basic
      insert = "INSERT INTO vat_return (regime, form, year, periodicity, period_number, date_from, date_to, " \
               "exigibility, status, client_listing_nihil, ask_restitution, closed_at, created_at, updated_at) " \
               "VALUES ('be', $1, 2026, 'month', 1, $2::date, $3::date, 'rates', $4, false, false, $5, now(), now())"
      closed_at = Time.utc
      expect_raises(Exception, /vat_return_closed_check/) do
        EntrySpec.sql_transaction { |db| db.exec(insert, "be_periodic", "2026-01-01", "2026-01-31", "closed", nil) }
      end
      expect_raises(Exception, /vat_return_dates_check/) do
        EntrySpec.sql_transaction { |db| db.exec(insert, "be_periodic", "2026-02-01", "2026-01-31", "draft", nil) }
      end
      expect_raises(Exception, /vat_return_form_check/) do
        EntrySpec.sql_transaction { |db| db.exec(insert, "be_625", "2026-01-01", "2026-01-31", "draft", nil) }
      end
      expect_raises(Exception, /vat_return_closed_unique/) do
        EntrySpec.sql_transaction do |db|
          db.exec(insert, "be_periodic", "2026-01-01", "2026-01-31", "closed", closed_at)
          db.exec(insert, "be_periodic", "2026-01-01", "2026-03-31", "closed", closed_at)
        end
      end
      EntrySpec.scalar("SELECT count(*) FROM vat_return").should eq(0)
    end

    it "contrôle la source, le signe, l'opération et la nature de journal d'une règle" do
      be_basic
      insert = "INSERT INTO vat_box_rule (regime, box, position, ledger_kind, accounts, excluded_accounts, source, " \
               "sign, operation, created_at, updated_at) VALUES ($1, '03', 1, $2, '', '', $3, $4, $5, now(), now())"
      {
        "vat_box_rule_regime_check"      => {"de", nil, "base", "all", "add"},
        "vat_box_rule_ledger_kind_check" => {"be", "bank", "base", "all", "add"},
        "vat_box_rule_source_check"      => {"be", nil, "total", "all", "add"},
        "vat_box_rule_sign_check"        => {"be", nil, "base", "zero", "add"},
        "vat_box_rule_operation_check"   => {"be", nil, "base", "all", "divide"},
      }.each do |constraint, values|
        expect_raises(Exception, /#{constraint}/) do
          EntrySpec.sql_transaction(&.exec(insert, *values))
        end
      end
    end
  end

  describe "droits" do
    it "ne passe l'écriture de liquidation qu'avec le droit de saisir : le brouillon reste intact" do
      be_basic
      id = VatReturnSpec.create(VatReturnSpec.input("be_periodic"))
      declarer = actor_with("accounting.vat.declare")
      expect_raises(Partiduo::Api::Forbidden) { Api.close_vat_return(declarer, id) }
      Api.vat_return(system, id).status.should eq("draft")
      Api.close_vat_return(declarer, id, nil).value!.closed_by_id.should eq(1_i64)
      expect_raises(Partiduo::Api::Forbidden) { Api.settle_vat_return(declarer, id) }
      Api.vat_return(system, id).settlement_entry_id.should be_nil
    end

    it "refuse chaque opération sans la permission, et signale une déclaration inconnue" do
      be_basic
      id = VatReturnSpec.create(VatReturnSpec.input("be_periodic"))
      actor = actor_with("accounting.entry.read", "accounting.entry.post")
      input = VatReturnSpec.input("be_periodic")
      calls = [
        -> { Api.vat_forms(actor); nil }, -> { Api.vat_box_rules(actor, "be"); nil },
        -> { Api.set_vat_box_rules(actor, "be", "03", [] of Api::VatBoxRuleInput); nil },
        -> { Api.reset_vat_box_rules(actor, "be"); nil }, -> { Api.vat_settings(actor); nil },
        -> { Api.update_vat_settings(actor, Api::VatSettingsInput.new); nil },
        -> { Api.preview_vat_return(actor, input); nil }, -> { Api.create_vat_return(actor, input); nil },
        -> { Api.recompute_vat_return(actor, id); nil },
        -> { Api.update_vat_return(actor, id, Api::VatReturnUpdateInput.new); nil },
        -> { Api.delete_vat_return(actor, id); nil }, -> { Api.close_vat_return(actor, id); nil },
        -> { Api.settle_vat_return(actor, id); nil }, -> { Api.vat_return(actor, id); nil },
        -> { Api.vat_returns(actor); nil }, -> { Api.vat_return_details(actor, id); nil },
        -> { Api.vat_return_file(actor, id, Api::VatFileFormat::Csv); nil },
      ] of -> Nil
      calls.each { |call| expect_raises(Partiduo::Api::Forbidden) { call.call } }
      Api.vat_return(system, id).status.should eq("draft")

      unknown = id + 1000
      expect_raises(Partiduo::Api::NotFound) { Api.vat_return(system, unknown) }
      expect_raises(Partiduo::Api::NotFound) { Api.vat_return_details(system, unknown) }
      expect_raises(Partiduo::Api::NotFound) { Api.vat_return_file(system, unknown, Api::VatFileFormat::Pdf) }
      expect_raises(Partiduo::Api::NotFound) { Api.close_vat_return(system, unknown) }
      expect_raises(Partiduo::Api::NotFound) { Api.delete_vat_return(system, unknown) }
      expect_raises(Partiduo::Api::NotFound) { Api.recompute_vat_return(system, unknown) }
    end
  end
end

describe "Déclarations de TVA, module Comptabilité inactif" do
  it "refuse chaque opération du contrat (ModuleDisabled)" do
    with_active_modules("invoicing") do
      input = Partiduo::Api::Accounting::VatReturnInput.new(form: "be_periodic", year: 2026)
      calls = [
        -> { Api.vat_forms(system); nil }, -> { Api.vat_box_rules(system, "be"); nil },
        -> { Api.set_vat_box_rules(system, "be", "03", [] of Api::VatBoxRuleInput); nil },
        -> { Api.reset_vat_box_rules(system, "be"); nil }, -> { Api.vat_settings(system); nil },
        -> { Api.update_vat_settings(system, Api::VatSettingsInput.new); nil },
        -> { Api.preview_vat_return(system, input); nil }, -> { Api.create_vat_return(system, input); nil },
        -> { Api.recompute_vat_return(system, 1_i64); nil },
        -> { Api.update_vat_return(system, 1_i64, Api::VatReturnUpdateInput.new); nil },
        -> { Api.delete_vat_return(system, 1_i64); nil }, -> { Api.close_vat_return(system, 1_i64); nil },
        -> { Api.settle_vat_return(system, 1_i64); nil }, -> { Api.vat_return(system, 1_i64); nil },
        -> { Api.vat_returns(system); nil }, -> { Api.vat_return_details(system, 1_i64); nil },
        -> { Api.vat_return_file(system, 1_i64, Api::VatFileFormat::Xml); nil },
      ] of -> Nil
      calls.each { |call| expect_raises(Partiduo::Api::ModuleDisabled) { call.call } }
    end
  end
end
