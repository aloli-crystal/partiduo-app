# SPDX-License-Identifier: AGPL-3.0-or-later

require "json"

module Partiduo
  module Api
    # Contrat du socle — fiches : tiers (clients, fournisseurs, banques,
    # salariés, contacts), articles et services, catégories et attributs
    # propres (ADR-001 D3, ADR-004 D5, ADR-006 D1). Successeur de `Fiche`,
    # `Fiche_Def` et `Card_Property`.
    #
    # Chaque enregistrement d'une fiche publie `card.saved`.
    module Cards
      KINDS = Partiduo::Cards::CardRules::KINDS
      UNITS = Partiduo::Cards::Units::CODES

      # --- Entrées ---------------------------------------------------------------

      # Adresse ; vide, elle est ignorée. Pays vide : celui de la société.
      record AddressInput,
        line1 : String? = nil,
        line2 : String? = nil,
        postcode : String? = nil,
        city : String? = nil,
        country_code : String? = nil,
        label : String? = nil

      # Saisie d'une fiche ; décrit la fiche entière, sauf `code` : `nil` ou
      # vide génère le quick code à la création et le conserve à la
      # modification. `extra` : attributs propres de la catégorie (texte,
      # nombre *en chaîne* ou entier, date `AAAA-MM-JJ`, booléen, identifiant
      # de fiche). La première adresse de livraison est celle par défaut.
      record CardInput,
        category_id : Int64,
        name : String,
        code : String? = nil,
        description : String? = nil,
        enabled : Bool = true,
        vat_number : String? = nil,
        siren : String? = nil,
        siret : String? = nil,
        routing_id : String? = nil,
        iban : String? = nil,
        bic : String? = nil,
        email : String? = nil,
        phone : String? = nil,
        contact_name : String? = nil,
        address : AddressInput? = nil,
        delivery_addresses : Array(AddressInput) = [] of AddressInput,
        unit_code : String? = nil,
        sale_price : BigDecimal? = nil,
        purchase_price : BigDecimal? = nil,
        vat_rate_id : Int64? = nil,
        extra : Hash(String, JSON::Any) = {} of String => JSON::Any

      # Attribut propre d'une catégorie. `value_type` : `text`, `number`,
      # `date`, `boolean`, `card`.
      record AttributeInput,
        key : String,
        label : String,
        value_type : String = "text",
        required : Bool = false,
        max_length : Int32? = nil,
        decimals : Int32? = nil

      # Saisie d'une catégorie ; `attributes` décrit la liste entière, dans
      # l'ordre d'affichage. `code` ne change plus après la création.
      record CategoryInput,
        code : String,
        name : String,
        kind : String,
        description : String? = nil,
        attributes : Array(AttributeInput) = [] of AttributeInput

      # Critères de recherche (`Fiche::build_sql`, `count_by_modele`).
      # `search` : nom, quick code, numéro de TVA, SIREN, SIRET, description ;
      # `extra` : valeurs d'attributs propres exigées (recherche par
      # inclusion, servie par l'index GIN).
      record CardQuery,
        category_id : Int64? = nil,
        kind : String? = nil,
        search : String? = nil,
        enabled : Bool? = true,
        extra : Hash(String, JSON::Any)? = nil,
        limit : Int32 = 100,
        offset : Int32 = 0

      # --- Vues ------------------------------------------------------------------

      record AddressView,
        kind : String,
        position : Int32,
        label : String,
        line1 : String,
        line2 : String,
        postcode : String,
        city : String,
        country_code : String do
        def to_input : AddressInput
          AddressInput.new(line1: line1, line2: line2, postcode: postcode, city: city,
            country_code: country_code, label: label)
        end
      end

      record AttributeView,
        key : String,
        label : String,
        value_type : String,
        required : Bool,
        max_length : Int32?,
        decimals : Int32?,
        position : Int32

      record CategoryView,
        id : Int64,
        code : String,
        name : String,
        kind : String,
        description : String,
        attributes : Array(AttributeView),
        card_count : Int32 do
        # Clé i18n de la nature (`cards.kinds.customer`).
        def kind_key : String
          "cards.kinds.#{kind}"
        end

        def item? : Bool
          kind == "item"
        end

        def to_input : CategoryInput
          inputs = attributes.map do |attribute|
            AttributeInput.new(key: attribute.key, label: attribute.label, value_type: attribute.value_type,
              required: attribute.required, max_length: attribute.max_length, decimals: attribute.decimals)
          end
          CategoryInput.new(code: code, name: name, kind: kind, description: description, attributes: inputs)
        end
      end

      record CardView,
        id : Int64,
        code : String,
        name : String,
        category_id : Int64,
        category_code : String,
        category_name : String,
        kind : String,
        description : String,
        enabled : Bool,
        vat_number : String,
        siren : String,
        siret : String,
        routing_id : String,
        iban : String,
        bic : String,
        email : String,
        phone : String,
        contact_name : String,
        address : AddressView?,
        delivery_addresses : Array(AddressView),
        unit_code : String,
        sale_price : BigDecimal?,
        purchase_price : BigDecimal?,
        vat_rate_id : Int64?,
        vat_rate_code : String?,
        extra : Hash(String, JSON::Any),
        created_at : Time,
        updated_at : Time do
        def item? : Bool
          kind == "item"
        end

        # Adresse de livraison par défaut (la première), sinon `nil`.
        def default_delivery_address : AddressView?
          delivery_addresses.first?
        end

        # Adresse électronique de l'annuaire : `SIREN`, `SIREN_SIRET` ou
        # `SIREN_SIRET_CODEROUTAGE` (schéma `0225`) ; `nil` sans SIREN.
        def electronic_address : String?
          return if siren.empty?
          parts = [siren]
          parts << siret unless siret.empty?
          parts << routing_id unless routing_id.empty?
          parts.join('_')
        end

        # Clé i18n de l'unité (`cards.units.c62`).
        def unit_key : String?
          unit_code.empty? ? nil : "cards.units.#{unit_code.downcase}"
        end

        def to_input : CardInput
          CardInput.new(
            category_id: category_id, name: name, code: code, description: description, enabled: enabled,
            vat_number: vat_number, siren: siren, siret: siret, routing_id: routing_id, iban: iban, bic: bic,
            email: email, phone: phone, contact_name: contact_name, address: address.try(&.to_input),
            delivery_addresses: delivery_addresses.map(&.to_input), unit_code: unit_code.presence,
            sale_price: sale_price, purchase_price: purchase_price, vat_rate_id: vat_rate_id, extra: extra,
          )
        end
      end

      # --- Catégories ------------------------------------------------------------

      def self.categories(actor : Actor, kind : String? = nil) : Array(CategoryView)
        Guard.authorize!(actor, "cards.card.read", module_code: "CARDS")
        query = Partiduo::Cards::Category.all
        query = query.filter(kind: kind) if kind
        query.order(:name).map { |category| category_view(category) }
      end

      def self.category(actor : Actor, id : Int64) : CategoryView
        Guard.authorize!(actor, "cards.card.read", module_code: "CARDS")
        category_view(find_category(id))
      end

      def self.category_by_code(actor : Actor, code : String) : CategoryView?
        Guard.authorize!(actor, "cards.card.read", module_code: "CARDS")
        Partiduo::Cards::Category.filter(code: code.strip.upcase).first.try { |category| category_view(category) }
      end

      def self.check_category(actor : Actor, input : CategoryInput, id : Int64? = nil) : Result(Nil)
        Guard.authorize!(actor, "cards.category.manage", module_code: "CARDS")
        current = id.try { |value| find_category(value) }
        errors = Partiduo::Cards::CategoryRules.validate(Partiduo::Cards::CategoryRules.normalize(input), current)
        errors.empty? ? Result(Nil).success(nil) : Result(Nil).failure(errors)
      end

      def self.create_category(actor : Actor, input : CategoryInput) : Result(CategoryView)
        Guard.authorize!(actor, "cards.category.manage", module_code: "CARDS")
        Transaction.run do
          values = Partiduo::Cards::CategoryRules.normalize(input)
          errors = Partiduo::Cards::CategoryRules.validate(values)
          next Result(CategoryView).failure(errors) unless errors.empty?

          category = Partiduo::Cards::CategoryRules.save(Partiduo::Cards::Category.new, values)
          Result(CategoryView).success(category_view(category))
        end
      end

      # Modifie une catégorie. Un attribut retiré est effacé des fiches.
      def self.update_category(actor : Actor, id : Int64, input : CategoryInput) : Result(CategoryView)
        Guard.authorize!(actor, "cards.category.manage", module_code: "CARDS")
        Transaction.run do
          category = Partiduo::Cards::Category.all.lock.filter(id: id).first || raise NotFound.new("card_category", id)
          values = Partiduo::Cards::CategoryRules.normalize(input)
          errors = Partiduo::Cards::CategoryRules.validate(values, category)
          next Result(CategoryView).failure(errors) unless errors.empty?

          Partiduo::Cards::CategoryRules.save(category, values)
          Result(CategoryView).success(category_view(category))
        end
      end

      # Supprime une catégorie sans fiche (NOALYSS supprimait en silence les
      # fiches inutilisées, D-REF-007).
      def self.delete_category(actor : Actor, id : Int64) : Result(Nil)
        Guard.authorize!(actor, "cards.category.manage", module_code: "CARDS")
        Transaction.run do
          Partiduo::Cards::Category.all.lock.filter(id: id).first || raise NotFound.new("card_category", id)
          if Partiduo::Cards::Card.filter(category_id: id).exists?
            next Result(Nil).failure(Partiduo::Cards::CategoryRules.error("base", "has_cards"))
          end
          deleted = Partiduo::Core::Db.delete_unless_referenced([
            {"DELETE FROM cards_category_attribute WHERE category_id = $1", [id] of ::DB::Any},
            {"DELETE FROM cards_category WHERE id = $1", [id] of ::DB::Any},
          ])
          next Result(Nil).failure(Partiduo::Cards::CategoryRules.error("base", "in_use")) unless deleted
          Result(Nil).success(nil)
        end
      end

      # Charge les catégories par défaut (jeu de données initial), libellés
      # dans la langue `locale`. Une catégorie déjà présente (même code) est
      # laissée telle quelle. Renvoie les codes créés.
      def self.load_default_categories(actor : Actor, locale : String = "fr") : Array(String)
        raise Forbidden.new("cards.category.manage") unless actor.system
        Guard.authorize!(actor, "cards.category.manage", module_code: "CARDS")
        locale = "fr" unless Partiduo::LOCALES.includes?(locale)
        I18n.with_locale(locale) do
          Partiduo::Cards::Defaults::CATEGORIES.compact_map do |definition|
            next if Partiduo::Cards::Category.filter(code: definition.code).exists?
            attributes = definition.attributes.map do |(key, type)|
              AttributeInput.new(key: key, label: I18n.t("cards.initial.attributes.#{key}"), value_type: type)
            end
            input = CategoryInput.new(
              code: definition.code,
              name: I18n.t("cards.initial.categories.#{definition.code.downcase}"),
              kind: definition.kind,
              attributes: attributes,
            )
            result = create_category(actor, input)
            raise ArgumentError.new("catégorie #{definition.code} refusée : #{result.error_keys.join(", ")}") if result.failure?
            definition.code
          end
        end
      end

      # --- Fiches ----------------------------------------------------------------

      def self.cards(actor : Actor, query : CardQuery = CardQuery.new) : Array(CardView)
        Guard.authorize!(actor, "cards.card.read", module_code: "CARDS")
        limit = query.limit.clamp(1, 1000)
        offset = query.offset.clamp(0, nil)
        records = card_query(query).order(:name, :id)[offset...(offset + limit)].to_a
        card_views(records)
      end

      def self.count_cards(actor : Actor, query : CardQuery = CardQuery.new) : Int64
        Guard.authorize!(actor, "cards.card.read", module_code: "CARDS")
        card_query(query).count.to_i64
      end

      def self.card(actor : Actor, id : Int64) : CardView
        Guard.authorize!(actor, "cards.card.read", module_code: "CARDS")
        card_views([find_card(id)]).first
      end

      # Fiche par quick code (`Fiche::get_by_qcode`), casse et accents
      # ignorés comme à la saisie ; `nil` si aucune.
      def self.card_by_code(actor : Actor, code : String) : CardView?
        Guard.authorize!(actor, "cards.card.read", module_code: "CARDS")
        formatted = Partiduo::Cards::QuickCode.format(code)
        return if formatted.empty?
        Partiduo::Cards::Card.filter(code: formatted).first.try { |card| card_views([card]).first }
      end

      # Format d'un quick code saisi (`comptaproc.format_quickcode`).
      def self.format_code(code : String) : String
        Partiduo::Cards::QuickCode.format(code)
      end

      def self.check_card(actor : Actor, input : CardInput, id : Int64? = nil) : Result(Nil)
        Guard.authorize!(actor, "cards.card.write", module_code: "CARDS")
        current = id.try { |value| find_card(value) }
        _values, errors = Partiduo::Cards::CardRules.check(input, current)
        errors.empty? ? Result(Nil).success(nil) : Result(Nil).failure(errors)
      end

      def self.create_card(actor : Actor, input : CardInput) : Result(CardView)
        Guard.authorize!(actor, "cards.card.write", module_code: "CARDS")
        Transaction.run do
          lock_codes
          values, errors = Partiduo::Cards::CardRules.check(input)
          next Result(CardView).failure(errors) if values.nil? || !errors.empty?

          card = Partiduo::Cards::CardRules.save(Partiduo::Cards::Card.new, values)
          saved(card, actor)
        end
      end

      def self.update_card(actor : Actor, id : Int64, input : CardInput) : Result(CardView)
        Guard.authorize!(actor, "cards.card.write", module_code: "CARDS")
        Transaction.run do
          lock_codes
          card = Partiduo::Cards::Card.all.lock.filter(id: id).first || raise NotFound.new("card", id)
          values, errors = Partiduo::Cards::CardRules.check(input, card)
          next Result(CardView).failure(errors) if values.nil? || !errors.empty?

          Partiduo::Cards::CardRules.save(card, values)
          saved(card, actor)
        end
      end

      # Active ou désactive une fiche (`f_enable`).
      def self.set_card_enabled(actor : Actor, id : Int64, enabled : Bool) : Result(CardView)
        Guard.authorize!(actor, "cards.card.write", module_code: "CARDS")
        Transaction.run do
          card = Partiduo::Cards::Card.all.lock.filter(id: id).first || raise NotFound.new("card", id)
          card.enabled = enabled
          card.save!
          saved(card, actor)
        end
      end

      # La fiche est-elle citée (écriture, facture, attribut d'une autre
      # fiche) ? (`Fiche::is_used`)
      def self.card_in_use?(actor : Actor, id : Int64) : Bool
        Guard.authorize!(actor, "cards.card.read", module_code: "CARDS")
        card = find_card(id)
        cited_by_card?(card.id!.to_i64) || Partiduo::Core::Db.referenced?(card_delete_statements(card.id!.to_i64))
      end

      # Supprime une fiche que rien ne cite (`Fiche::remove`) ; sinon, la
      # désactiver.
      def self.delete_card(actor : Actor, id : Int64) : Result(Nil)
        Guard.authorize!(actor, "cards.card.write", module_code: "CARDS")
        Transaction.run do
          card = Partiduo::Cards::Card.all.lock.filter(id: id).first || raise NotFound.new("card", id)
          in_use = Result(Nil).failure(Partiduo::Cards::CardRules.error("base", "in_use"))
          next in_use if cited_by_card?(card.id!.to_i64)
          next in_use unless Partiduo::Core::Db.delete_unless_referenced(card_delete_statements(card.id!.to_i64))
          Result(Nil).success(nil)
        end
      end

      # --- Interne ---------------------------------------------------------------

      private def self.saved(card : Partiduo::Cards::Card, actor : Actor) : Result(CardView)
        Partiduo::Events.publish("card.saved", {"card_id" => card.id!.to_i64.to_s}, actor_user_id: actor.user_id)
        Result(CardView).success(card_views([card]).first)
      end

      # Sérialise l'attribution des quick codes (la contrainte d'unicité reste
      # le dernier rempart).
      private def self.lock_codes : Nil
        Marten::DB::Connection.default.open do |db|
          db.exec("SELECT pg_advisory_xact_lock(hashtext('cards_card_code'))")
        end
      end

      private def self.card_delete_statements(id : Int64) : Array({String, Array(::DB::Any)})
        [
          {"DELETE FROM cards_address WHERE card_id = $1", [id] of ::DB::Any},
          {"DELETE FROM cards_card WHERE id = $1", [id] of ::DB::Any},
        ]
      end

      # Une autre fiche cite-t-elle celle-ci par un attribut de type `card` ?
      private def self.cited_by_card?(id : Int64) : Bool
        Partiduo::Cards::CategoryAttribute.filter(value_type: "card").to_a.any? do |attribute|
          Partiduo::Cards::Card.filter(category_id: attribute.category_id)
            .filter("extra @> ?::jsonb", {attribute.key! => id}.to_json).exists?
        end
      end

      private def self.card_query(query : CardQuery)
        records = Partiduo::Cards::Card.all
        records = records.filter(category_id: query.category_id) if query.category_id
        if kind = query.kind
          ids = Partiduo::Cards::Category.filter(kind: kind).pluck(:id).map { |row| row.first.as(Int64) }
          records = records.filter(category_id__in: ids)
        end
        records = records.filter(enabled: query.enabled) unless query.enabled.nil?
        if (search = query.search.try(&.strip)) && !search.empty?
          code = Partiduo::Cards::QuickCode.format(search)
          compact = Partiduo::Core::Identifiers.compact(search)
          records = records.filter do
            q(name__icontains: search) | q(description__icontains: search) |
              q(code__icontains: code.presence || search) | q(vat_number__icontains: compact) |
              q(siren__startswith: compact) | q(siret__startswith: compact)
          end
        end
        if (extra = query.extra) && !extra.empty?
          records = records.filter("extra @> ?::jsonb", extra.to_json)
        end
        records
      end

      private def self.find_category(id : Int64) : Partiduo::Cards::Category
        Partiduo::Cards::Category.filter(id: id).first || raise NotFound.new("card_category", id)
      end

      private def self.find_card(id : Int64) : Partiduo::Cards::Card
        Partiduo::Cards::Card.filter(id: id).first || raise NotFound.new("card", id)
      end

      private def self.category_view(category : Partiduo::Cards::Category) : CategoryView
        attributes = Partiduo::Cards::CategoryAttribute.filter(category_id: category.id).order(:position, :id).map do |attribute|
          AttributeView.new(key: attribute.key!, label: attribute.label!, value_type: attribute.value_type!,
            required: attribute.required!, max_length: attribute.max_length.try(&.to_i32), decimals: attribute.decimals.try(&.to_i32),
            position: attribute.position!.to_i32)
        end
        CategoryView.new(id: category.id!.to_i64, code: category.code!, name: category.name!, kind: category.kind!,
          description: category.description.to_s, attributes: attributes,
          card_count: Partiduo::Cards::Card.filter(category_id: category.id).count.to_i32)
      end

      # Vues d'un lot de fiches : catégories, adresses et taux lus en trois
      # requêtes.
      private def self.card_views(cards : Array(Partiduo::Cards::Card)) : Array(CardView)
        return [] of CardView if cards.empty?
        ids = cards.map(&.id!.to_i64)
        categories = Partiduo::Cards::Category.filter(id__in: cards.map(&.category_id!.as(Int).to_i64).uniq!).to_a.to_h { |category| {category.id!.to_i64, category} }
        addresses = Partiduo::Cards::Address.filter(card_id__in: ids).order(:position, :id).to_a.group_by(&.card_id!.as(Int).to_i64)
        rate_ids = cards.compact_map(&.vat_rate_id.try(&.as(Int).to_i64)).uniq!
        rates = rate_ids.empty? ? {} of Int64 => String : Partiduo::Vat::Rate.filter(id__in: rate_ids).to_a.to_h { |rate| {rate.id!.to_i64, rate.code!} }

        cards.map do |card|
          category = categories[card.category_id!.as(Int).to_i64]
          card_addresses = (addresses[card.id!.to_i64]? || [] of Partiduo::Cards::Address).map { |address| address_view(address) }
          CardView.new(
            id: card.id!.to_i64,
            code: card.code!,
            name: card.name!,
            category_id: category.id!.to_i64,
            category_code: category.code!,
            category_name: category.name!,
            kind: category.kind!,
            description: card.description.to_s,
            enabled: card.enabled!,
            vat_number: card.vat_number.to_s,
            siren: card.siren.to_s,
            siret: card.siret.to_s,
            routing_id: card.routing_id.to_s,
            iban: card.iban.to_s,
            bic: card.bic.to_s,
            email: card.email.to_s,
            phone: card.phone.to_s,
            contact_name: card.contact_name.to_s,
            address: card_addresses.find(&.kind.==("main")),
            delivery_addresses: card_addresses.select(&.kind.==("delivery")),
            unit_code: card.unit_code.to_s,
            sale_price: card.sale_price,
            purchase_price: card.purchase_price,
            vat_rate_id: card.vat_rate_id.try(&.as(Int).to_i64),
            vat_rate_code: card.vat_rate_id.try { |id| rates[id.as(Int).to_i64]? },
            extra: card.extra.try(&.as_h?) || {} of String => JSON::Any,
            created_at: card.created_at!,
            updated_at: card.updated_at!,
          )
        end
      end

      private def self.address_view(address : Partiduo::Cards::Address) : AddressView
        AddressView.new(kind: address.kind!, position: address.position!.to_i32, label: address.label.to_s,
          line1: address.line1.to_s, line2: address.line2.to_s, postcode: address.postcode.to_s,
          city: address.city.to_s, country_code: address.country_code!)
      end
    end
  end
end
