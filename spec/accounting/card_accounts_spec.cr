# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias Api = Partiduo::Api::Accounting
private alias Cards = Partiduo::Api::Cards

private def system
  Partiduo::Api::Actor.system
end

private def category_id(code : String) : Int64
  (Cards.category_by_code(system, code) || raise "catégorie #{code} absente").id
end

# Fiche créée par le contrat du socle : publie `card.saved`.
private def create_card(category : String, name : String) : Int64
  Cards.create_card(system, Cards::CardInput.new(category_id: category_id(category), name: name)).value!.id
end

private def assign(card_id : Int64, account : String? = nil)
  Api.assign_card_account(system, Api::AssignCardAccountInput.new(card_id, account))
end

private def account_of(card_id : Int64) : String?
  Api.card_account(system, card_id).try(&.account.number)
end

describe "Rattachement fiche → compte : module inactif (ADR-006 D2)" do
  it "refuse par ModuleDisabled, et une fiche créée n'a pas de compte" do
    Cards.load_default_categories(system)
    with_active_modules("invoicing") do
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.card_account(system, 1_i64) }
      expect_raises(Partiduo::Api::ModuleDisabled) { assign(1_i64) }
      create_card("CUSTOMER", "Dupont SA")
    end
    Partiduo::Accounting::CardAccount.all.count.should eq(0)
  end
end

describe_module "ACCOUNTING", "Rattachement fiche → compte (account_insert)" do
  it "paramètre les catégories par défaut du socle au chargement du plan (fiche_def)" do
    AccountingSpec.load("fr").card_categories.should eq(6)
    customer = Api.card_category_account(system, category_id("CUSTOMER")).should_not be_nil
    customer.base_account.try(&.number).should eq("410")
    customer.create_account.should be_true
    Api.card_category_account(system, category_id("CONTACT")).should be_nil
  end

  it "crée le compte d'une fiche neuve sous le compte de base de sa catégorie (card.saved, account_compute)" do
    AccountingSpec.load("fr")

    # 410 a déjà l'enfant 4100001 (« Clients divers ») : numéro suivant.
    dupont = create_card("CUSTOMER", "Dupont SA")
    durand = create_card("CUSTOMER", "Durand")
    account_of(dupont).should eq("4100002")
    account_of(durand).should eq("4100003")

    account = Api.account(system, "4100002")
    account.label.should eq("Dupont SA")
    account.parent_number.should eq("410")
    account.kind.should eq(Api::AccountKind::Asset)
    Api.card_ids_for_account(system, "4100003").should eq([durand])

    # Une nouvelle sauvegarde de la fiche ne change pas son compte.
    Cards.update_card(system, dupont, Cards::CardInput.new(category_id: category_id("CUSTOMER"), name: "Dupont & fils"))
    account_of(dupont).should eq("4100002")
  end

  it "numérote B0001 sous un compte de base sans enfant (PCMN belge)" do
    AccountingSpec.load("be")
    account_of(create_card("SUPPLIER", "Fournisseur A")).should eq("4400001")
  end

  it "rattache au compte de base quand la catégorie ne crée pas de compte" do
    AccountingSpec.load("fr")
    Api.set_card_category_account(system, Api::CardCategoryAccountInput.new(category_id("SUPPLIER"), "400")).success?
      .should be_true
    card = create_card("SUPPLIER", "Durand SARL")
    account_of(card).should eq("400")
    Api.card_ids_for_account(system, "400").should eq([card])
  end

  it "rattache au compte donné, créé s'il n'existe pas, et remplace le rattachement" do
    AccountingSpec.load("fr")
    card = create_card("CONTACT", "Client export")
    account_of(card).should be_nil # catégorie sans compte de base

    assign(card, "707").value!.account.number.should eq("707")
    created = assign(card, "4 EXPORT").value!
    created.account.number.should eq("4EXPORT")
    created.account.label.should eq("Client export")
    created.account.parent_number.should eq("4")
    account_of(card).should eq("4EXPORT")
    Api.card_ids_for_account(system, "707").should be_empty

    Api.unassign_card_account(system, card).success?.should be_true
    account_of(card).should be_nil
    Api.account(system, "4EXPORT").label.should eq("Client export") # le compte reste
  end

  it "refuse un compte non utilisable directement, une fiche sans compte déterminable ou inconnue" do
    AccountingSpec.load("fr")
    card = create_card("CONTACT", "Martin")
    assign(card, "51").error_keys.should eq(["accounting.errors.card_account.account.not_direct_use"])
    assign(card).error_keys.should eq(["accounting.errors.card_account.account.required"])
    assign(999_i64, "707").error_keys.should eq(["accounting.errors.card_account.card_id.not_found"])
  end

  it "refuse d'effacer un compte rattaché ; efface le rattachement avec la fiche" do
    AccountingSpec.load("fr")
    card = create_card("CUSTOMER", "Dupont SA")
    account = Api.account(system, account_of(card) || raise "fiche sans compte")
    Api.delete_account(system, account.id).error_keys.should eq(["accounting.errors.account.in_use"])

    Cards.delete_card(system, card).success?.should be_true
    account_of(card).should be_nil
    Api.delete_account(system, account.id).success?.should be_true
  end

  it "contrôle le paramétrage d'une catégorie" do
    AccountingSpec.load("fr")
    contact = category_id("CONTACT")
    Api.set_card_category_account(system, Api::CardCategoryAccountInput.new(contact, nil, true)).error_keys
      .should eq(["accounting.errors.card_category.base_account.required"])
    Api.set_card_category_account(system, Api::CardCategoryAccountInput.new(contact, "999")).error_keys
      .should eq(["accounting.errors.card_category.base_account.not_found"])
    Api.set_card_category_account(system, Api::CardCategoryAccountInput.new(999_i64, "61")).error_keys
      .should eq(["accounting.errors.card_category.category_id.not_found"])
    Api.set_card_category_account(system, Api::CardCategoryAccountInput.new(contact, "61")).value!.create_account
      .should be_false
    Api.set_card_category_account(system, Api::CardCategoryAccountInput.new(contact)).value!.base_account.should be_nil
  end

  it "exige les droits du plan comptable" do
    expect_raises(Partiduo::Api::Forbidden) { Api.card_account(actor_with, 1_i64) }
    expect_raises(Partiduo::Api::Forbidden) do
      Api.assign_card_account(actor_with("accounting.account.read"), Api::AssignCardAccountInput.new(1_i64))
    end
  end
end
