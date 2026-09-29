# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias Api = Partiduo::Api::Cards
private alias R = ReferentialSpec

private def suppliers : Api::CategoryView
  R.category("SUPPLIER", "supplier", "Fournisseurs")
end

private def sql_error(sql : String) : String?
  Marten::DB::Connection.default.open(&.exec(sql))
  nil
rescue ex : PQ::PQError
  ex.message
end

# Fournisseur personne physique (DAS2, DECISIONS D-R5-001).
describe "Partiduo::Api::Cards — fournisseur personne physique" do
  it "enregistre nom, prénoms et date de naissance, et compose le nom de la fiche" do
    view = R.card(suppliers.id, "", supplier_nature: "individual", last_name: " DURAND ",
      first_names: "Paul Marie", birth_date: Time.utc(1971, 4, 2, 13, 0, 0))
    view.name.should eq("DURAND Paul Marie")
    view.individual_supplier?.should be_true
    view.supplier_nature_key.should eq("cards.supplier_natures.individual")
    {view.last_name, view.first_names}.should eq({"DURAND", "Paul Marie"})
    view.birth_date.should eq(Time.utc(1971, 4, 2))
  end

  it "garde la raison sociale saisie d'une personne physique" do
    view = R.card(suppliers.id, "Cabinet Durand", supplier_nature: "individual", last_name: "Durand", first_names: "Paul")
    view.name.should eq("Cabinet Durand")
    view.birth_date.should be_nil
  end

  it "exige nom et prénoms d'une personne physique et contrôle la date" do
    category = suppliers
    result = Api.create_card(R.system, R.card_input(category.id, "X", supplier_nature: "individual",
      birth_date: Time.utc(2030, 1, 1)))
    result.error_keys.should eq([
      "cards.errors.card.last_name.blank",
      "cards.errors.card.first_names.blank",
      "cards.errors.card.birth_date.invalid",
    ])
    R.expect_translated(result)
    old = Api.create_card(R.system, R.card_input(category.id, "X", supplier_nature: "individual",
      last_name: "A" * 129, first_names: "B", birth_date: Time.utc(1899, 12, 31)))
    old.error_keys.should eq(["cards.errors.card.last_name.too_long", "cards.errors.card.birth_date.invalid"])
    R.expect_translated(old)
  end

  it "refuse la nature et l'identité hors fournisseur ou hors personne physique" do
    customers = R.category("CUSTOMER", "customer", "Clients")
    category = suppliers
    result = Api.create_card(R.system, R.card_input(customers.id, "Client", supplier_nature: "individual",
      last_name: "Durand", first_names: "Paul"))
    result.error_keys.should eq(["cards.errors.card.supplier_nature.not_applicable"])
    business = Api.create_card(R.system, R.card_input(category.id, "SARL", supplier_nature: "business",
      last_name: "Durand", first_names: "Paul", birth_date: Time.utc(1980, 1, 1)))
    business.error_keys.should eq([
      "cards.errors.card.last_name.not_applicable",
      "cards.errors.card.first_names.not_applicable",
      "cards.errors.card.birth_date.not_applicable",
    ])
    unknown = Api.create_card(R.system, R.card_input(category.id, "SARL", supplier_nature: "company"))
    unknown.error_keys.should eq(["cards.errors.card.supplier_nature.invalid"])
    [result, business, unknown].each { |item| R.expect_translated(item) }
  end

  it "conserve l'identité quand la saisie ne donne pas la nature, et l'efface quand la fiche cesse d'être une personne physique" do
    category = suppliers
    view = R.card(category.id, "Durand", supplier_nature: "individual", last_name: "Durand", first_names: "Paul",
      birth_date: Time.utc(1971, 4, 2))
    kept = Api.update_card(R.system, view.id, R.card_input(category.id, "Durand consultant")).value!
    {kept.supplier_nature, kept.last_name, kept.first_names, kept.birth_date}
      .should eq({"individual", "Durand", "Paul", Time.utc(1971, 4, 2)})
    reentered = Api.update_card(R.system, view.id, kept.to_input.copy_with(birth_date: nil)).value!
    reentered.birth_date.should be_nil
    company = Api.update_card(R.system, view.id, R.card_input(category.id, "Durand SARL", supplier_nature: "business")).value!
    {company.supplier_nature, company.last_name, company.first_names, company.birth_date}
      .should eq({"business", "", "", nil})
  end

  it "rend une saisie complète par to_input (aller-retour sans perte)" do
    view = R.card(suppliers.id, "Durand", supplier_nature: "individual", last_name: "Durand", first_names: "Paul",
      birth_date: Time.utc(1971, 4, 2))
    again = Api.update_card(R.system, view.id, view.to_input).value!
    {again.supplier_nature, again.last_name, again.first_names, again.birth_date}
      .should eq({"individual", "Durand", "Paul", Time.utc(1971, 4, 2)})
    customer = R.card(R.category("CUSTOMER", "customer", "Clients").id, "Client")
    customer.to_input.supplier_nature.should be_nil
  end

  it "vide la nature de fournisseur d'une fiche passée dans une autre catégorie de tiers" do
    view = R.card(suppliers.id, "Durand", supplier_nature: "individual", last_name: "Durand", first_names: "Paul")
    contacts = R.category("CONTACT", "contact", "Contacts")
    moved = Api.update_card(R.system, view.id, R.card_input(contacts.id, "Durand")).value!
    {moved.supplier_nature, moved.last_name, moved.first_names}.should eq({"", "", ""})
  end

  it "est gardée par des contraintes en base" do
    view = R.card(suppliers.id, "Dupont SARL")
    sql_error("UPDATE cards_card SET supplier_nature = 'x' WHERE id = #{view.id}").to_s
      .should contain("cards_card_supplier_nature_check")
    sql_error("UPDATE cards_card SET last_name = 'Dupont' WHERE id = #{view.id}").to_s
      .should contain("cards_card_person_check")
  end
end
