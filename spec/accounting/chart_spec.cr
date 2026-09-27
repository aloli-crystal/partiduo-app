# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias Api = Partiduo::Api::Accounting

private def input(number, label = "Compte #{number}", parent = nil, kind = nil, direct_use = true)
  Api::AccountInput.new(number, label, parent, kind, direct_use)
end

private def system
  Partiduo::Api::Actor.system
end

describe "Plan comptable : module inactif (ADR-006 D2)" do
  it "refuse requêtes et commandes par ModuleDisabled" do
    with_active_modules("invoicing") do
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.chart(system) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.create_account(system, input("1")) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.default_accounts(system) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.load_initial_data(system, "fr") }
    end
  end
end

describe_module "ACCOUNTING", "Plan comptable (tmp_pcmn)" do
  describe "droits" do
    it "exige la lecture pour consulter, l'écriture pour modifier" do
      expect_raises(Partiduo::Api::Forbidden) { Api.chart(actor_with) }
      expect_raises(Partiduo::Api::Forbidden) { Api.create_account(actor_with("accounting.account.read"), input("1")) }
      expect_raises(Partiduo::Api::Forbidden) { Api.chart(Partiduo::Api::Actor.anonymous) }
      Api.chart(actor_with("accounting.account.read")).should be_empty
    end
  end

  describe ".create_account" do
    it "normalise le numéro comme format_account et rattache au plus long préfixe existant" do
      AccountingSpec.create_account("4", kind: Api::AccountKind::Asset)
      AccountingSpec.create_account("40", "Fournisseurs")

      view = Api.create_account(actor_with("accounting.account.write"), input(" 40-01.é ", "Fournisseur Dupont")).value!

      view.number.should eq("4001E")
      view.parent_number.should eq("40")
      view.kind.should eq(Api::AccountKind::Asset) # hérité du parent (find_pcm_type)
      view.direct_use.should be_true
    end

    it "accepte une racine d'un caractère, de type contexte par défaut, et un parent explicite" do
      root = AccountingSpec.create_account("6")
      root.parent_id.should be_nil
      root.kind.should eq(Api::AccountKind::Context)

      AccountingSpec.create_account("60", kind: Api::AccountKind::Expense)
      view = AccountingSpec.create_account("6040001", parent: "6")
      view.parent_number.should eq("6")
    end

    it "refuse les saisies invalides, erreurs par champ en clés i18n" do
      AccountingSpec.create_account("4")
      AccountingSpec.create_account("40")

      Api.create_account(system, input("40")).error_keys.should eq(["accounting.errors.account.number.taken"])
      Api.create_account(system, input("")).error_keys.should contain("accounting.errors.account.number.blank")
      Api.create_account(system, input("4ñ")).error_keys.should eq(["accounting.errors.account.number.invalid"])
      Api.create_account(system, input("4" * 41)).error_keys.should eq(["accounting.errors.account.number.too_long"])
      Api.create_account(system, input("401", " ")).error_keys.should eq(["accounting.errors.account.label.blank"])
      Api.create_account(system, input("401", parent: "99")).errors_for("parent").map(&.key)
        .should eq(["accounting.errors.account.parent.not_found"])
      Api.create_account(system, input("401", parent: "401")).error_keys.should eq(["accounting.errors.account.parent.self"])
      Api.create_account(system, input("71")).error_keys.should eq(["accounting.errors.account.parent.required"])
    end

    it "fournit un message dans chaque langue pour chaque erreur" do
      result = Api.create_account(system, input("", " "))
      Partiduo::LOCALES.each do |locale|
        I18n.with_locale(locale) { result.errors.each(&.message.should_not(contain("missing"))) }
      end
    end
  end

  describe ".update_account" do
    it "modifie libellé, type et parent, et refuse un parent descendant" do
      AccountingSpec.create_account("4")
      forty = AccountingSpec.create_account("40")
      AccountingSpec.create_account("400")
      AccountingSpec.create_account("5")

      view = Api.update_account(system, forty.id, input("40", "Fournisseurs", parent: "4", kind: Api::AccountKind::Liability)).value!
      view.label.should eq("Fournisseurs")
      view.kind.should eq(Api::AccountKind::Liability)

      Api.update_account(system, forty.id, input("40", parent: "400")).error_keys
        .should eq(["accounting.errors.account.parent.cycle"])
      Api.update_account(system, forty.id, input("40", parent: "5")).value!.parent_number.should eq("5")
    end

    it "lève NotFound pour un compte inconnu" do
      expect_raises(Partiduo::Api::NotFound) { Api.update_account(system, 999_i64, input("1")) }
    end
  end

  describe ".chart" do
    it "renvoie l'arbre par SQL récursif : parents avant enfants, profondeur, nombre d'enfants" do
      AccountingSpec.create_account("7")
      AccountingSpec.create_account("6")
      AccountingSpec.create_account("61")
      AccountingSpec.create_account("60")
      AccountingSpec.create_account("604")
      AccountingSpec.create_account("6A")

      lines = Api.chart(system)
      lines.map(&.account.number).should eq(%w[6 60 604 61 6A 7])
      lines.map(&.depth).should eq([0, 1, 2, 1, 1, 0])
      lines.first.children_count.should eq(3)
      lines.find!(&.account.number.==("604")).leaf?.should be_true

      subtree = Api.chart(system, root: "60")
      subtree.map { |line| {line.account.number, line.depth} }.should eq([{"60", 0}, {"604", 1}])
      expect_raises(Partiduo::Api::NotFound) { Api.chart(system, root: "99") }
    end
  end

  describe "requêtes de lecture" do
    it "trouve un compte par numéro, par identifiant, et par recherche" do
      AccountingSpec.create_account("5")
      bank = AccountingSpec.create_account("512", "Banque Populaire")
      AccountingSpec.create_account("53", "Caisse", direct_use: false)

      Api.account(system, " 512 ").id.should eq(bank.id)
      Api.account_by_id(system, bank.id).label.should eq("Banque Populaire")
      expect_raises(Partiduo::Api::NotFound) { Api.account(system, "999") }

      Api.search_accounts(system, "5").map(&.number).should eq(%w[5 512 53])
      Api.search_accounts(system, "banque").map(&.number).should eq(%w[512])
      Api.search_accounts(system, "5", direct_use_only: true).map(&.number).should eq(%w[5 512])
      Api.search_accounts(system, " ").should be_empty
    end
  end

  describe ".delete_account" do
    it "refuse un compte parent ou utilisé, efface les autres" do
      AccountingSpec.create_account("5")
      bank = AccountingSpec.create_account("512")
      five = Api.account(system, "5")

      Api.delete_account(system, five.id).error_keys.should eq(["accounting.errors.account.has_children"])
      Api.set_default_account(system, "bank", "512").success?.should be_true
      Api.delete_account(system, bank.id).error_keys.should eq(["accounting.errors.account.in_use"])

      Api.set_default_account(system, "bank", nil).success?.should be_true
      Api.delete_account(system, bank.id).success?.should be_true
      expect_raises(Partiduo::Api::NotFound) { Api.account(system, "512") }
    end
  end

  describe "comptes par défaut (parm_code)" do
    it "définit, lit et retire le compte d'un usage connu" do
      AccountingSpec.create_account("4")
      AccountingSpec.create_account("411", "Clients")

      Api.set_default_account(system, "customer", "411").success?.should be_true
      Api.default_account(system, "customer").try(&.number).should eq("411")
      Api.default_accounts(system).map(&.code).should eq(["customer"])

      Api.set_default_account(system, "unknown", "411").error_keys.should eq(["accounting.errors.default_account.code.invalid"])
      Api.set_default_account(system, "supplier", "401").error_keys
        .should eq(["accounting.errors.default_account.account.not_found"])

      Api.set_default_account(system, "customer", nil).success?.should be_true
      Api.default_account(system, "customer").should be_nil
    end
  end

  describe "contraintes en base (ADR-001 § PL/pgSQL)" do
    it "refuse un numéro non normalisé et un parent circulaire, même hors du contrat" do
      AccountingSpec.create_account("4")
      forty = AccountingSpec.create_account("40")
      four = Api.account(system, "4")

      expect_raises(Exception, /accounting_account_number_check/) do
        Partiduo::Accounting::Account.create!(number: "4 1", label: "x", kind: "asset")
      end
      expect_raises(Exception, /parent circulaire/) do
        Marten::DB::Connection.default.open do |db|
          db.exec("UPDATE accounting_account SET parent_id = $1 WHERE id = $2", forty.id, four.id)
        end
      end
    end
  end
end
