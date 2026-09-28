# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias Api = Partiduo::Api::Accounting

private def system
  Partiduo::Api::Actor.system
end

private def bank_account : Nil
  AccountingSpec.create_account("5")
  AccountingSpec.create_account("512", "Banque")
  AccountingSpec.create_account("51", "Banques", direct_use: false)
  nil
end

describe "Journaux : module inactif (ADR-006 D2)" do
  it "refuse requêtes et commandes par ModuleDisabled" do
    with_active_modules("invoicing") do
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.ledgers(system) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.create_ledger(system, AccountingSpec.ledger_input) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.ledger_access(system, 1_i64) }
    end
  end
end

describe_module "ACCOUNTING", "Journaux (jrn_def)" do
  describe ".create_ledger" do
    it "attribue un code comme l'application d'origine et prépare la numérotation des pièces" do
      AccountingSpec.base_currency
      _, actor = AccountingSpec.user_actor("erin@example.com", "accounting.ledger.write")
      first = Api.create_ledger(actor, AccountingSpec.ledger_input("Achats", receipt_prefix: "ACH-", receipt_padding: 4)).value!
      second = Api.create_ledger(actor, AccountingSpec.ledger_input("Frais généraux")).value!
      sale = Api.create_ledger(actor, AccountingSpec.ledger_input("Ventes", Api::LedgerKind::Sale, code: " v10 ")).value!

      first.code.should eq("A01")
      first.next_receipt.should eq("ACH-0001")
      first.currency_code.should eq("EUR")
      first.enabled.should be_true
      second.code.should eq("A02")
      second.next_receipt.should eq("1")
      sale.code.should eq("V10")
    end

    it "exige la fiche Banque d'un journal financier, dont le compte devient celui du journal (D-ACC-010)" do
      bank_account
      AccountingSpec.base_currency
      bank = ReferentialSpec.category("BANK", "bank")
      customers = ReferentialSpec.category("CUSTOMER", "customer")
      card = ReferentialSpec.card(bank.id, "Banque du Centre")
      unlinked = ReferentialSpec.card(bank.id, "Banque sans compte")
      client = ReferentialSpec.card(customers.id, "Client")
      Api.assign_card_account(system, Api::AssignCardAccountInput.new(card.id, "512")).value!

      financial = ->(code : String?) { AccountingSpec.ledger_input("Banque", Api::LedgerKind::Financial, bank_card: code) }
      Api.create_ledger(system, financial.call(nil)).error_keys.should eq(["accounting.errors.ledger.bank_card.required"])
      Api.create_ledger(system, financial.call("INCONNU")).error_keys.should eq(["accounting.errors.ledger.bank_card.not_found"])
      Api.create_ledger(system, financial.call(client.code)).error_keys.should eq(["accounting.errors.ledger.bank_card.not_bank"])
      Api.create_ledger(system, financial.call(unlinked.code)).error_keys.should eq(["accounting.errors.ledger.bank_card.no_account"])

      view = Api.create_ledger(system, financial.call(card.code)).value!
      view.code.should eq("F01")
      view.bank_card_id.should eq(card.id)
      view.bank_card_code.should eq(card.code)
      view.default_account.try(&.number).should eq("512") # compte de la fiche, pas stocké

      # La fiche citée par un journal ne s'efface pas.
      Partiduo::Api::Cards.delete_card(system, card.id).failure?.should be_true
    end

    it "refuse en base un journal financier sans fiche Banque" do
      AccountingSpec.base_currency
      expect_raises(Exception, /accounting_ledger_financial_bank_card_check/) do
        Marten::DB::Connection.default.open do |db|
          db.exec("INSERT INTO accounting_ledger (code, name, kind, description, enabled, receipt_prefix, receipt_padding, " \
                  "last_receipt_number, currency_code, created_at, updated_at) " \
                  "VALUES ('F09', 'Sans banque', 'financial', '', true, '', 0, 0, 'EUR', now(), now())")
        end
      end
    end

    it "prend la devise de tenue du dossier quand la saisie n'en donne pas" do
      Partiduo::Api::Core.ensure_base_currency(system, "CHF", "Franc suisse")
      AccountingSpec.create_ledger("Achats").currency_code.should eq("CHF")
    end

    it "refuse nom ou code déjà pris, champs invalides, devise non déclarée au socle" do
      AccountingSpec.create_ledger("Achats", code: "ACH")

      Api.check_ledger(system, AccountingSpec.ledger_input("Achats")).error_keys
        .should eq(["accounting.errors.ledger.name.taken"])
      Api.check_ledger(system, AccountingSpec.ledger_input("Autres", code: "ach")).error_keys
        .should eq(["accounting.errors.ledger.code.taken"])
      Api.check_ledger(system, AccountingSpec.ledger_input("Autres", code: "A-1")).error_keys
        .should eq(["accounting.errors.ledger.code.invalid"])
      Api.check_ledger(system, AccountingSpec.ledger_input(" ")).error_keys
        .should eq(["accounting.errors.ledger.name.blank"])
      Api.check_ledger(system, AccountingSpec.ledger_input("Autres", receipt_padding: 21, next_receipt_number: 0_i64,
        receipt_prefix: "P" * 21)).error_keys.sort.should eq([
        "accounting.errors.ledger.next_receipt_number.invalid",
        "accounting.errors.ledger.receipt_padding.invalid",
        "accounting.errors.ledger.receipt_prefix.too_long",
      ])
      Api.check_ledger(system, AccountingSpec.ledger_input("Autres", currency_code: "EURO")).error_keys
        .should eq(["accounting.errors.ledger.currency_code.invalid"])
      result = Api.check_ledger(system, AccountingSpec.ledger_input("Autres", currency_code: "usd"))
      result.error_keys.should eq(["accounting.errors.ledger.currency_code.unknown"])
      result.errors.first.params["code"].should eq("USD")
    end
  end

  describe ".update_ledger" do
    it "modifie le journal et repositionne la numérotation des pièces (jrn_def_pj_seq)" do
      ledger = AccountingSpec.create_ledger("Achats", receipt_prefix: "A-", receipt_padding: 3)

      view = Api.update_ledger(system, ledger.id, AccountingSpec.ledger_input("Achats 2026", receipt_prefix: "A26-",
        receipt_padding: 3, next_receipt_number: 42_i64, enabled: false, description: "Exercice 2026")).value!

      view.code.should eq("A01")
      view.name.should eq("Achats 2026")
      view.enabled.should be_false
      view.last_receipt_number.should eq(41)
      view.next_receipt.should eq("A26-042")
      Api.ledgers(system, enabled_only: true).should be_empty
      Api.ledgers(system, kind: Api::LedgerKind::Purchase).size.should eq(1)
    end
  end

  describe ".delete_ledger" do
    it "efface un journal" do
      ledger = AccountingSpec.create_ledger
      Api.delete_ledger(system, ledger.id).success?.should be_true
      expect_raises(Partiduo::Api::NotFound) { Api.ledger(system, ledger.id) }
    end
  end

  describe "numérotation des pièces" do
    it "réserve des numéros consécutifs, sans trou quand la transaction est annulée" do
      ledger = AccountingSpec.create_ledger("Ventes", Api::LedgerKind::Sale, receipt_prefix: "V-", receipt_padding: 5)

      Partiduo::Accounting::Receipts.take!(ledger.id).should eq("V-00001")
      Marten::DB::Connection.default.transaction do
        Partiduo::Accounting::Receipts.take!(ledger.id).should eq("V-00002")
        raise Marten::DB::Errors::Rollback.new
      end
      Partiduo::Accounting::Receipts.take!(ledger.id).should eq("V-00002")
      Api.ledger(system, ledger.id).next_receipt.should eq("V-00003")
    end
  end

  describe "droits par journal (user_sec_jrn, D-AUTH-010)" do
    it "ne montre à un utilisateur sous sécurité des journaux que ses journaux, avec son droit" do
      purchases = AccountingSpec.create_ledger("Achats")
      sales = AccountingSpec.create_ledger("Ventes", Api::LedgerKind::Sale)
      misc = AccountingSpec.create_ledger("OD", Api::LedgerKind::Misc)
      user_id, actor = AccountingSpec.user_actor("bob@example.com", "accounting.ledger.read")
      Partiduo::Api::Auth.set_ledger_security(system, user_id, true).success?.should be_true
      Partiduo::Api::Auth.set_ledger_access(system, user_id, purchases.id, "R").success?.should be_true
      Partiduo::Api::Auth.set_ledger_access(system, user_id, sales.id, "W").success?.should be_true

      Api.ledgers(actor).map { |ledger| {ledger.code, ledger.access} }.should eq([
        {"A01", Api::LedgerAccess::Read}, {"V01", Api::LedgerAccess::Write},
      ])
      Api.ledger_access(actor, misc.id).should eq(Api::LedgerAccess::None)
      Api.ledger_access(actor, sales.id).writable?.should be_true
      expect_raises(Partiduo::Api::NotFound) { Api.ledger(actor, misc.id) }
      expect_raises(Partiduo::Api::NotFound) { Api.ledger_access(actor, 999_i64) }
    end

    it "donne l'écriture partout sans sécurité des journaux, et tout montre à qui administre les journaux" do
      ledger = AccountingSpec.create_ledger("Achats")
      _, reader = AccountingSpec.user_actor("carol@example.com", "accounting.ledger.read")
      Api.ledger(reader, ledger.id).access.should eq(Api::LedgerAccess::Write)

      admin_id, admin = AccountingSpec.user_actor("dave@example.com", "accounting.ledger.read", "accounting.ledger.write")
      Partiduo::Api::Auth.set_ledger_security(system, admin_id, true)
      view = Api.ledger(admin, ledger.id)
      view.access.should eq(Api::LedgerAccess::None)
    end

    it "exige la permission de lecture des journaux" do
      expect_raises(Partiduo::Api::Forbidden) { Api.ledgers(actor_with) }
      expect_raises(Partiduo::Api::Forbidden) { Api.create_ledger(actor_with("accounting.ledger.read"), AccountingSpec.ledger_input) }
    end
  end
end
