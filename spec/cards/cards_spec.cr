# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias Api = Partiduo::Api::Cards
private alias R = ReferentialSpec

private def writer : Partiduo::Api::Actor
  actor_with("cards.card.read", "cards.card.write")
end

private def customers : Api::CategoryView
  R.category("CUSTOMER", "customer", "Clients")
end

private def items : Api::CategoryView
  R.category("SALE", "item", "Ventes")
end

describe "Partiduo::Api::Cards — fiches (fiche, fiche_detail)" do
  describe "tiers" do
    it "crée un client avec ses identifiants, ses adresses, et publie card.saved" do
      category = customers
      R.capture_events("card.saved") do |events|
        input = R.card_input(category.id, "  Boulangerie Martin ",
          siren: "732 829 320", siret: "73282932000074", routing_id: "SERVICE-COMPTA",
          vat_number: "fr 44 732829320", iban: "FR76 3000 6000 0112 3456 7890 189", bic: "bnpafrpp",
          email: "Compta@Martin.example", phone: "+33 1 23 45 67 89", contact_name: "Mme Martin",
          address: Api::AddressInput.new(line1: "1 rue du Four", postcode: "75006", city: "Paris", country_code: "fr"),
          delivery_addresses: [
            Api::AddressInput.new(label: "Atelier", line1: "5 rue Neuve", postcode: "93100", city: "Montreuil", country_code: "FR"),
            Api::AddressInput.new(label: "Boutique", line1: "8 place Haute", postcode: "75011", city: "Paris", country_code: "FR"),
            Api::AddressInput.new,
          ])
        view = Api.create_card(writer, input).value!
        view.name.should eq("Boulangerie Martin")
        view.code.should eq("BOULAN")
        view.kind.should eq("customer")
        view.siren.should eq("732829320")
        view.vat_number.should eq("FR44732829320")
        view.iban.should eq("FR7630006000011234567890189")
        view.bic.should eq("BNPAFRPP")
        view.email.should eq("compta@martin.example")
        R.present(view.address).country_code.should eq("FR")
        view.delivery_addresses.map(&.label).should eq(["Atelier", "Boutique"])
        R.present(view.default_delivery_address).city.should eq("Montreuil")
        view.electronic_address.should eq("732829320_73282932000074_SERVICE-COMPTA")
        view.enabled.should be_true
        events.map(&.["card_id"]).should eq([view.id.to_s])
      end
    end

    it "prend le pays de la société pour une adresse sans pays" do
      provision_instance(settings_input(tax_regime: "be", siren: nil, rcs: nil, vat_number: nil))
      category = R.present(Api.category_by_code(writer, "CUSTOMER"))
      view = R.card(category.id, "Dupont", address: Api::AddressInput.new(line1: "Rue Haute 1", city: "Bruxelles"))
      R.present(view.address).country_code.should eq("BE")
    end

    it "déduit le SIREN du SIRET et contrôle leur cohérence" do
      category = customers
      R.card(category.id, "Martin", siret: "732 829 320 00074").siren.should eq("732829320")
      result = Api.create_card(writer, R.card_input(category.id, siren: "552100554", siret: "73282932000074"))
      result.error_keys.should eq(["cards.errors.card.siret.siren_mismatch"])
      R.expect_translated(result)
    end

    it "contrôle SIREN, SIRET, identifiant de routage, TVA, IBAN, BIC et adresse électronique" do
      category = customers
      result = Api.create_card(writer, R.card_input(category.id,
        siren: "732829321", siret: "73282932000075", vat_number: "FR00732829320",
        iban: "FR7630006000011234567890188", bic: "BNP", email: "pas-une-adresse"))
      result.error_keys.should eq([
        "cards.errors.card.email.invalid",
        "cards.errors.card.siren.invalid",
        "cards.errors.card.siret.invalid",
        "cards.errors.card.vat_number.invalid",
        "cards.errors.card.iban.invalid",
        "cards.errors.card.bic.invalid",
      ])
      R.expect_translated(result)

      routing = Api.create_card(writer, R.card_input(category.id, routing_id: "SERVICE"))
      routing.error_keys.should eq(["cards.errors.card.routing_id.siren_required"])
      mismatch = Api.create_card(writer, R.card_input(category.id, siren: "552100554", vat_number: "FR44732829320"))
      mismatch.error_keys.should eq(["cards.errors.card.vat_number.siren_mismatch"])
      Api.create_card(writer, R.card_input(category.id, vat_number: "BE0403170701")).success?.should be_true
    end

    it "refuse un nom vide (NOALYSS mettait « Nom vide », D-REF-005)" do
      result = Api.create_card(writer, R.card_input(customers.id, " "))
      result.error_keys.should eq(["cards.errors.card.name.blank"])
    end

    it "refuse les champs d'article sur un tiers" do
      result = Api.create_card(writer, R.card_input(customers.id, unit_code: "HUR", sale_price: BigDecimal.new("10")))
      result.error_keys.should eq(["cards.errors.card.unit_code.not_applicable", "cards.errors.card.sale_price.not_applicable"])
      R.expect_translated(result)
    end

    it "contrôle le pays et la longueur des adresses" do
      result = Api.create_card(writer, R.card_input(customers.id,
        address: Api::AddressInput.new(line1: "x" * 300, country_code: "France")))
      result.errors.map(&.field).should eq(["address.line1", "address.country_code"])
      R.expect_translated(result)
    end
  end

  describe "articles et services" do
    it "crée un article avec unité UN/ECE, prix et taux de TVA par défaut" do
      rate = R.vat_rate("NOR", "20")
      category = items
      view = R.card(category.id, "Heure de conseil", unit_code: "hur", sale_price: BigDecimal.new("85.5"),
        purchase_price: BigDecimal.new("0.1234"), vat_rate_id: rate.id)
      view.item?.should be_true
      view.unit_code.should eq("HUR")
      view.unit_key.should eq("cards.units.hur")
      view.sale_price.should eq(BigDecimal.new("85.5"))
      view.purchase_price.should eq(BigDecimal.new("0.1234"))
      view.vat_rate_code.should eq("NOR")
      R.card(category.id, "Forfait").unit_code.should eq("C62")
    end

    it "contrôle l'unité, les prix, le taux et refuse les champs de tiers" do
      category = items
      disabled = R.vat_rate("OLD", "19.6", enabled: false)
      result = Api.create_card(writer, R.card_input(category.id, unit_code: "XYZ",
        sale_price: BigDecimal.new("-1"), purchase_price: BigDecimal.new("1.23456"), vat_rate_id: disabled.id,
        siren: "732829320", delivery_addresses: [Api::AddressInput.new(city: "Paris", country_code: "FR")]))
      result.error_keys.should eq([
        "cards.errors.card.siren.not_applicable",
        "cards.errors.card.delivery_addresses.not_applicable",
        "cards.errors.card.unit_code.invalid",
        "cards.errors.card.sale_price.negative",
        "cards.errors.card.purchase_price.too_precise",
        "cards.errors.card.vat_rate_id.disabled",
      ])
      R.expect_translated(result)
      Api.create_card(writer, R.card_input(category.id, vat_rate_id: 999_999_i64)).error_keys
        .should eq(["cards.errors.card.vat_rate_id.not_found"])
    end

    it "traduit chaque unité proposée" do
      Partiduo::Api::Cards::UNITS.each do |code|
        Partiduo::LOCALES.each do |locale|
          I18n.with_locale(locale) { I18n.t("cards.units.#{code.downcase}").should_not contain("missing") }
        end
      end
    end
  end

  describe "quick code" do
    it "garde le code saisi, le formate, et refuse un code déjà pris" do
      category = customers
      R.card(category.id, "Martin", code: " a a a a").code.should eq("AAAA")
      result = Api.create_card(writer, R.card_input(category.id, "Autre", code: "aaaa"))
      result.error_keys.should eq(["cards.errors.card.code.taken"])
      R.expect_translated(result)
    end

    it "conserve le code quand la saisie le vide (testUpdateEmptyQuickCode)" do
      category = customers
      card = R.card(category.id, "Martin", code: "QC")
      {"", ",,,,", "####"}.each do |code|
        Api.update_card(writer, card.id, card.to_input.copy_with(code: code)).value!.code.should eq("QC")
      end
      Api.update_card(writer, card.id, card.to_input.copy_with(code: "a+z+1-5")).value!.code.should eq("AZ1-5")
      Api.update_card(writer, card.id, card.to_input.copy_with(code: nil, name: "Renommé")).value!.code.should eq("AZ1-5")
    end

    it "génère un code à partir du nom quand la saisie n'en donne pas (testInsertEmptyQuickCode)" do
      category = customers
      R.card(category.id, "none", code: "").code.should eq("NONE")
      R.card(category.id, ",,,,", code: ",,,,").code.should eq("CRD")
      R.card(category.id, "àz-5&é").code.should eq("AZ-5E")
    end

    it "trouve une fiche par son quick code, saisi en minuscules ou avec accents" do
      card = R.card(customers.id, "Martin", code: "MARTIN")
      R.present(Api.card_by_code(writer, " martin ")).id.should eq(card.id)
      Api.card_by_code(writer, "INCONNU").should be_nil
      Api.card_by_code(writer, "###").should be_nil
    end
  end

  describe "modification" do
    it "active et désactive une fiche (ficheTest::testUpdateEnable)" do
      card = R.card(customers.id)
      R.capture_events("card.saved") do |events|
        Api.set_card_enabled(writer, card.id, false).value!.enabled.should be_false
        Api.update_card(writer, card.id, card.to_input.copy_with(enabled: true)).value!.enabled.should be_true
        events.size.should eq(2)
      end
    end

    it "remplace les adresses de livraison et change de catégorie sans changer de nature" do
      suppliers = R.category("SUPPLIER", "supplier", "Fournisseurs")
      card = R.card(customers.id, delivery_addresses: [Api::AddressInput.new(city: "Lyon", country_code: "FR")])
      moved = Api.update_card(writer, card.id, card.to_input.copy_with(category_id: suppliers.id,
        delivery_addresses: [] of Api::AddressInput)).value!
      moved.category_code.should eq("SUPPLIER")
      moved.delivery_addresses.should be_empty
      Api.update_card(writer, card.id, moved.to_input.copy_with(category_id: items.id)).error_keys
        .should eq(["cards.errors.card.category_id.kind_mismatch"])
    end

    it "garde un taux désactivé déjà rattaché" do
      rate = R.vat_rate("NOR", "20")
      card = R.card(items.id, "Conseil", vat_rate_id: rate.id)
      Partiduo::Api::Vat.update_rate(R.system, rate.id, rate.to_input.copy_with(enabled: false))
      Api.update_card(writer, card.id, card.to_input.copy_with(name: "Conseil senior")).success?.should be_true
    end

    it "exige la permission cards.card.write" do
      expect_raises(Partiduo::Api::Forbidden) { Api.create_card(actor_with("cards.card.read"), R.card_input(customers.id)) }
      expect_raises(Partiduo::Api::Forbidden) { Api.cards(actor_with) }
    end
  end

  describe "attributs propres (extra jsonb)" do
    it "valide et normalise les valeurs selon la catégorie" do
      category = R.category("PROJECT", "other", "Projets", [
        Api::AttributeInput.new(key: "budget", label: "Budget", value_type: "number", decimals: 2),
        Api::AttributeInput.new(key: "start_on", label: "Début", value_type: "date"),
        Api::AttributeInput.new(key: "billable", label: "Facturable", value_type: "boolean"),
        Api::AttributeInput.new(key: "note", label: "Note", value_type: "text", max_length: 5, required: true),
        Api::AttributeInput.new(key: "owner", label: "Responsable", value_type: "card"),
      ])
      owner = R.card(customers.id, "Martin")
      view = R.card(category.id, "Chantier", extra: {
        "budget" => R.json("1500.50"), "start_on" => R.json("2026-02-01"), "billable" => R.json(true),
        "note" => R.json(" court "), "owner" => R.json(owner.id),
      })
      view.extra["budget"].should eq(R.json("1500.5"))
      view.extra["note"].should eq(R.json("court"))
      view.extra["owner"].should eq(R.json(owner.id))

      result = Api.create_card(writer, R.card_input(category.id, "Autre", extra: {
        "budget" => R.json(12.5), "start_on" => R.json("2026-02-30"), "billable" => R.json("oui"),
        "note" => R.json("trop long"), "owner" => R.json(999_999), "colour" => R.json("bleu"),
      }))
      result.error_keys.should eq([
        "cards.errors.card.extra.unknown",
        "cards.errors.card.extra.invalid_number",
        "cards.errors.card.extra.invalid_date",
        "cards.errors.card.extra.invalid_boolean",
        "cards.errors.card.extra.too_long",
        "cards.errors.card.extra.card_not_found",
      ])
      result.errors.map(&.field).should contain("extra.budget")
      R.expect_translated(result)

      missing = Api.create_card(writer, R.card_input(category.id, "Sans note"))
      missing.error_keys.should eq(["cards.errors.card.extra.required"])
      precise = Api.create_card(writer, R.card_input(category.id, "Précis", extra: {"note" => R.json("x"), "budget" => R.json("1.234")}))
      precise.error_keys.should eq(["cards.errors.card.extra.too_precise"])
    end

    it "recherche par valeur d'attribut grâce à l'index GIN" do
      category = R.category("PROJECT", "other", "Projets", [Api::AttributeInput.new(key: "site", label: "Site")])
      R.card(category.id, "A", extra: {"site" => R.json("Lyon")})
      R.card(category.id, "B", extra: {"site" => R.json("Paris")})
      found = Api.cards(writer, Api::CardQuery.new(extra: {"site" => R.json("Paris")}))
      found.map(&.name).should eq(["B"])
      indexes = Marten::DB::Connection.default.open do |db|
        db.query_all("SELECT indexdef FROM pg_indexes WHERE tablename = 'cards_card'", as: String)
      end
      indexes.any?(&.includes?("USING gin (extra jsonb_path_ops)")).should be_true
    end
  end

  describe "recherche" do
    it "cherche par nom, quick code, TVA, SIREN, filtre par catégorie, nature et activation" do
      category = customers
      martin = R.card(category.id, "Boulangerie Martin", siren: "732829320")
      R.card(category.id, "Dupont", vat_number: "BE0403170701")
      inactive = R.card(category.id, "Ancien client")
      Api.set_card_enabled(writer, inactive.id, false)
      R.card(items.id, "Pain de campagne")

      Api.cards(writer, Api::CardQuery.new(search: "martin")).map(&.id).should eq([martin.id])
      Api.cards(writer, Api::CardQuery.new(search: "7328")).map(&.id).should eq([martin.id])
      Api.cards(writer, Api::CardQuery.new(search: "be 0403")).map(&.name).should eq(["Dupont"])
      Api.cards(writer, Api::CardQuery.new(kind: "customer")).map(&.name).should eq(["Boulangerie Martin", "Dupont"])
      Api.cards(writer, Api::CardQuery.new(enabled: nil, category_id: category.id)).size.should eq(3)
      Api.count_cards(writer, Api::CardQuery.new(kind: "item")).should eq(1)
      Api.cards(writer, Api::CardQuery.new(limit: 1, offset: 1)).map(&.name).should eq(["Dupont"])
    end
  end

  describe "suppression (Fiche::remove, is_used)" do
    it "supprime une fiche libre et ses adresses" do
      card = R.card(customers.id, address: Api::AddressInput.new(city: "Paris", country_code: "FR"))
      Api.card_in_use?(writer, card.id).should be_false
      Api.delete_card(writer, card.id).success?.should be_true
      expect_raises(Partiduo::Api::NotFound) { Api.card(writer, card.id) }
    end

    it "refuse de supprimer une fiche citée par une autre fiche (attribut de type card)" do
      contacts = R.category("CONTACT", "contact", "Contacts",
        [Api::AttributeInput.new(key: "company", label: "Société", value_type: "card")])
      company = R.card(customers.id, "Martin")
      R.card(contacts.id, "Mme Martin", extra: {"company" => R.json(company.id)})
      Api.card_in_use?(writer, company.id).should be_true
      result = Api.delete_card(writer, company.id)
      result.error_keys.should eq(["cards.errors.card.base.in_use"])
      R.expect_translated(result)
    end

    it "refuse de supprimer une fiche citée par un module, sans l'emporter en cascade" do
      card = R.card(customers.id)
      Marten::DB::Connection.default.open do |db|
        db.exec("CREATE TABLE spec_card_ref (id bigserial PRIMARY KEY, card_id bigint REFERENCES cards_card (id) " \
                "DEFERRABLE INITIALLY DEFERRED)")
      end
      begin
        Marten::DB::Connection.default.open { |db| db.exec("INSERT INTO spec_card_ref (card_id) VALUES ($1)", card.id) }
        Api.card_in_use?(writer, card.id).should be_true
        Api.delete_card(writer, card.id).error_keys.should eq(["cards.errors.card.base.in_use"])
        Api.card(writer, card.id).name.should eq(card.name)
      ensure
        Marten::DB::Connection.default.open(&.exec("DROP TABLE spec_card_ref"))
      end
    end
  end

  describe "contraintes en base" do
    it "impose un quick code unique et en majuscules, un extra objet" do
      card = R.card(customers.id, code: "UNIQUE")
      expect_raises(Exception, /cards_card_code_check/) do
        Marten::DB::Connection.default.open { |db| db.exec("UPDATE cards_card SET code = 'minuscule' WHERE id = $1", card.id) }
      end
      expect_raises(Exception, /cards_card_extra_object/) do
        Marten::DB::Connection.default.open { |db| db.exec("UPDATE cards_card SET extra = '[]' WHERE id = $1", card.id) }
      end
    end
  end
end
