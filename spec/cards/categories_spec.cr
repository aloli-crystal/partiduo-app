# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias Api = Partiduo::Api::Cards
private alias R = ReferentialSpec

private def manager : Partiduo::Api::Actor
  actor_with("cards.category.manage", "cards.card.read", "cards.card.write")
end

private def attribute(key : String, type : String = "text", **options) : Api::AttributeInput
  Api::AttributeInput.new(key: key, label: key.capitalize, value_type: type).copy_with(**options)
end

private def category_input(**options) : Api::CategoryInput
  Api::CategoryInput.new(code: "PROJECT", name: "Projets", kind: "other").copy_with(**options)
end

describe "Partiduo::Api::Cards — catégories de fiches (fiche_def)" do
  it "crée une catégorie et ses attributs propres, dans l'ordre" do
    view = Api.create_category(manager, category_input(attributes: [
      attribute("budget", "number", decimals: 2), attribute("start_on", "date"), attribute("manager", "card"),
    ])).value!
    view.code.should eq("PROJECT")
    view.kind_key.should eq("cards.kinds.other")
    view.attributes.map(&.key).should eq(%w[budget start_on manager])
    view.attributes.map(&.position).should eq([10, 20, 30])
    view.card_count.should eq(0)
    R.present(Api.category_by_code(manager, "project")).id.should eq(view.id)
  end

  it "reprend les contrôles de Fiche_Def::Add : nom obligatoire et unique, modèle obligatoire" do
    Api.create_category(manager, category_input(name: "Projets"))
    result = Api.create_category(manager, category_input(code: "PROJ2", name: "PROJETS", kind: ""))
    result.error_keys.should eq(["cards.errors.category.name.taken", "cards.errors.category.kind.invalid"])
    blank = Api.create_category(manager, category_input(code: "3X", name: " "))
    blank.error_keys.should eq(["cards.errors.category.code.invalid", "cards.errors.category.name.blank"])
    R.expect_translated(result)
    R.expect_translated(blank)
  end

  it "contrôle les attributs" do
    result = Api.create_category(manager, category_input(attributes: [
      attribute("1budget"), attribute("note"), attribute("note"), attribute("x", "color"),
      attribute("y", "text", max_length: 0),
    ]))
    result.error_keys.should eq([
      "cards.errors.category.attribute.key.invalid",
      "cards.errors.category.attribute.key.duplicate",
      "cards.errors.category.attribute.value_type.invalid",
      "cards.errors.category.attribute.max_length.out_of_range",
    ])
    result.errors.map(&.field).should eq(["attributes[0].key", "attributes[2].key", "attributes[3].value_type",
                                          "attributes[4].max_length"])
    R.expect_translated(result)
  end

  it "retire un attribut et l'efface des fiches (removeAttribut)" do
    category = Api.create_category(manager, category_input(attributes: [attribute("note"), attribute("code_chantier")])).value!
    card = R.card(category.id, "Chantier A", extra: {"note" => R.json("urgent"), "code_chantier" => R.json("CH-1")})
    updated = Api.update_category(manager, category.id, category.to_input.copy_with(attributes: [attribute("code_chantier")]))
    updated.value!.attributes.map(&.key).should eq(["code_chantier"])
    Api.card(manager, card.id).extra.should eq({"code_chantier" => R.json("CH-1")})
  end

  it "garde le type d'un attribut renseigné et refuse de rendre obligatoire un attribut manquant" do
    category = Api.create_category(manager, category_input(attributes: [attribute("note"), attribute("ref")])).value!
    R.card(category.id, "Chantier A", extra: {"note" => R.json("x")})
    result = Api.update_category(manager, category.id, category.to_input.copy_with(attributes: [
      attribute("note", "number"), attribute("ref", required: true), attribute("new_one", required: true),
    ]))
    result.error_keys.should eq([
      "cards.errors.category.attribute.value_type.in_use",
      "cards.errors.category.attribute.required.missing_values",
      "cards.errors.category.attribute.required.missing_values",
    ])
    R.expect_translated(result)
  end

  it "refuse de changer le code, ou la nature d'une catégorie qui a des fiches" do
    category = Api.create_category(manager, category_input).value!
    R.card(category.id, "Chantier A")
    result = Api.update_category(manager, category.id, category.to_input.copy_with(code: "OTHER", kind: "customer"))
    result.error_keys.should eq(["cards.errors.category.code.immutable", "cards.errors.category.kind.in_use"])
  end

  it "supprime une catégorie vide, pas une catégorie qui a des fiches" do
    category = Api.create_category(manager, category_input).value!
    card = R.card(category.id, "Chantier A")
    Api.delete_category(manager, category.id).error_keys.should eq(["cards.errors.category.base.has_cards"])
    Api.delete_card(manager, card.id).success?.should be_true
    Api.delete_category(manager, category.id).success?.should be_true
    expect_raises(Partiduo::Api::NotFound) { Api.category(manager, category.id) }
  end

  it "charge les catégories par défaut dans la langue du dossier" do
    codes = Api.load_default_categories(R.system, "en")
    codes.should contain("CUSTOMER")
    R.present(Api.category_by_code(manager, "CUSTOMER")).name.should eq("Customers")
    contact = R.present(Api.category_by_code(manager, "CONTACT"))
    contact.attributes.map(&.value_type).should eq(%w[text card])
    Api.categories(manager, kind: "item").map(&.code).sort!.should eq(%w[EXPENSE PURCHASE SALE])
    Api.load_default_categories(R.system, "en").should be_empty
  end

  it "exige la permission cards.category.manage pour écrire" do
    expect_raises(Partiduo::Api::Forbidden) { Api.create_category(actor_with("cards.card.write"), category_input) }
    expect_raises(Partiduo::Api::Forbidden) { Api.categories(actor_with) }
  end
end
