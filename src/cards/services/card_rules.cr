# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Cards
    # Règles d'une fiche : normalisation de la saisie, validation,
    # enregistrement. Reprend `Fiche::insert`, `Fiche::update` et
    # `Card_Property::update`, en les durcissant (l'application d'origine n'imposait aucun
    # contrôle sur les valeurs ; seuls le quick code et le taux de TVA étaient
    # vérifiés).
    module CardRules
      alias FieldError = Partiduo::Api::FieldError
      alias Api = Partiduo::Api::Cards

      KINDS       = %w[customer supplier item bank employee contact other]
      PARTY_KINDS = KINDS - %w[item]
      # Nature d'un client (ADR-004 D9), vide : pas encore précisée.
      CUSTOMER_NATURES = %w[individual business public]

      MAX_SIZES = {
        "name"         => 255,
        "description"  => 4000,
        "email"        => 254,
        "phone"        => 32,
        "contact_name" => 128,
      }
      ADDRESS_SIZES          = {"label" => 100, "line1" => 255, "line2" => 255, "postcode" => 16, "city" => 128}
      MAX_DELIVERY_ADDRESSES = 20
      PRICE_DECIMALS         =  4
      MAX_PRICE              = BigDecimal.new(10) ** 16

      EMAIL_FORMAT   = /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/
      COUNTRY_FORMAT = /\A[A-Z]{2}\z/
      # Code de routage de l'annuaire : lettres, chiffres, `.`, `_`, `-`.
      ROUTING_FORMAT = /\A[A-Za-z0-9._\-]{1,100}\z/

      record AddressValues,
        label : String,
        line1 : String,
        line2 : String,
        postcode : String,
        city : String,
        country_code : String

      record Values,
        category : Category,
        code : String,
        code_given : Bool,
        name : String,
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
        address : AddressValues?,
        delivery_addresses : Array(AddressValues),
        unit_code : String,
        sale_price : BigDecimal?,
        purchase_price : BigDecimal?,
        vat_rate_id : Int64?,
        extra : Hash(String, JSON::Any),
        customer_nature : String,
        pdf_copy : Bool

      # Normalise et valide. Renvoie les valeurs (même en cas d'erreur, pour
      # le contrôle instantané) et les erreurs par champ.
      def self.check(input : Api::CardInput, current : Card? = nil) : {Values?, Array(FieldError)}
        errors = [] of FieldError
        category = Category.filter(id: input.category_id).first
        if category.nil?
          errors << error("category_id", "not_found")
          return {nil, errors}
        end

        kind = category.kind!
        siren = compact_digits(input.siren)
        siret = compact_digits(input.siret)
        siren = siret[0, 9] if siren.empty? && siret.size == 14

        attributes = CategoryAttribute.filter(category_id: category.id).order(:position, :id).to_a
        extra, extra_errors = Extra.normalize(attributes, input.extra, current.try(&.id))
        errors.concat(extra_errors)

        values = Values.new(
          category: category,
          code: QuickCode.format(input.code || ""),
          code_given: !input.code.nil?,
          name: text(input.name),
          description: text(input.description),
          enabled: input.enabled,
          vat_number: Partiduo::Core::Identifiers.compact(text(input.vat_number)),
          siren: siren,
          siret: siret,
          routing_id: text(input.routing_id),
          iban: Partiduo::Core::Identifiers.compact(text(input.iban)),
          bic: Partiduo::Core::Identifiers.compact(text(input.bic)),
          email: text(input.email).downcase,
          phone: text(input.phone),
          contact_name: text(input.contact_name),
          address: input.address.try { |address| normalize_address(address) },
          delivery_addresses: input.delivery_addresses.compact_map { |address| normalize_address(address) },
          unit_code: text(input.unit_code).upcase.presence || (kind == "item" ? Units::DEFAULT : ""),
          sale_price: input.sale_price,
          purchase_price: input.purchase_price,
          vat_rate_id: input.vat_rate_id,
          extra: extra,
          customer_nature: input.customer_nature.try(&.strip) ||
                           (kind == "customer" ? current.try(&.customer_nature).to_s : ""),
          pdf_copy: input.pdf_copy.nil? ? current.try(&.pdf_copy) != false : input.pdf_copy == true,
        )

        validate(values, current, errors)
        {values, errors}
      end

      private def self.validate(values : Values, current : Card?, errors : Array(FieldError)) : Nil
        errors << error("name", "blank") if values.name.empty?
        MAX_SIZES.each do |field, max|
          errors << error(field, "too_long", {"max" => max.to_s}) if field_value(values, field).size > max
        end
        validate_code(values, current, errors)
        validate_nature(values, errors)
        if current && current.category_id != values.category.id && current_kind_conflict?(current, values)
          errors << error("category_id", "kind_mismatch")
        end
        unless values.email.empty? || values.email.matches?(EMAIL_FORMAT)
          errors << error("email", "invalid")
        end
        if values.category.kind == "item"
          validate_item(values, current, errors)
        else
          validate_party(values, errors)
        end
        if main = values.address
          validate_address("address", main, errors)
        end
        values.delivery_addresses.each_with_index do |delivery, index|
          validate_address("delivery_addresses[#{index}]", delivery, errors)
        end
        if values.delivery_addresses.size > MAX_DELIVERY_ADDRESSES
          errors << error("delivery_addresses", "too_many", {"max" => MAX_DELIVERY_ADDRESSES.to_s})
        end
      end

      # Le quick code saisi est formaté ; vide, il est généré depuis le nom
      # (création) ou conservé (modification), comme `insert_quick_code` et
      # `update_quick_code`. Un code saisi déjà pris est refusé (l'application d'origine
      # ajoutait un suffixe en silence, D-REF-006).
      private def self.validate_code(values : Values, current : Card?, errors) : Nil
        code = values.code
        return if code.empty?
        if code.size > QuickCode::MAX_SIZE
          errors << error("code", "too_long", {"max" => QuickCode::MAX_SIZE.to_s})
        elsif QuickCode.taken?(code, current.try(&.id))
          errors << error("code", "taken", {"value" => code})
        end
      end

      # Nature d'un client : une valeur connue, sur une fiche de client
      # seulement (ADR-004 D9).
      private def self.validate_nature(values : Values, errors) : Nil
        nature = values.customer_nature
        return if nature.empty?
        if values.category.kind != "customer"
          errors << error("customer_nature", "not_applicable")
        elsif !CUSTOMER_NATURES.includes?(nature)
          errors << error("customer_nature", "invalid", {"value" => nature})
        end
      end

      # Proposition de nature d'après les identifiants (ADR-004 D9) : les
      # SIREN des personnes morales de droit public commencent par 1 ou 2.
      def self.propose_nature(siren : String, vat_number : String) : String
        siren = siren.strip
        siren = Partiduo::Vat::Fr::VatNumber.siren(vat_number.strip).to_s if siren.empty? && vat_number.strip.starts_with?("FR")
        return "public" if siren.size == 9 && siren[0].in?('1', '2')
        siren.empty? && vat_number.strip.empty? ? "individual" : "business"
      end

      # Une fiche change de catégorie (`Fiche::move_to`) sans changer de
      # nature : un article ne devient pas un tiers.
      private def self.current_kind_conflict?(current : Card, values : Values) : Bool
        old_kind = current.category!.kind
        (old_kind == "item") != (values.category.kind == "item")
      end

      private def self.validate_party(values : Values, errors) : Nil
        {"unit_code" => !values.unit_code.empty?, "sale_price" => !values.sale_price.nil?,
         "purchase_price" => !values.purchase_price.nil?, "vat_rate_id" => !values.vat_rate_id.nil?}.each do |field, set|
          errors << error(field, "not_applicable") if set
        end

        validate_company_ids(values, errors)
        validate_bank_ids(values, errors)
      end

      # SIREN, SIRET, identifiant de routage (ADR-004 D5), numéro de TVA.
      private def self.validate_company_ids(values : Values, errors) : Nil
        identifiers = Partiduo::Core::Identifiers
        unless values.siren.empty? || identifiers.valid_siren?(values.siren)
          errors << error("siren", "invalid", {"value" => values.siren})
        end
        unless values.siret.empty?
          if !identifiers.valid_siret?(values.siret)
            errors << error("siret", "invalid", {"value" => values.siret})
          elsif !values.siret.starts_with?(values.siren)
            errors << error("siret", "siren_mismatch", {"siren" => values.siren})
          end
        end
        unless values.routing_id.empty?
          if values.siren.empty?
            errors << error("routing_id", "siren_required")
          elsif !values.routing_id.matches?(ROUTING_FORMAT)
            errors << error("routing_id", "invalid", {"value" => values.routing_id})
          end
        end
        validate_vat_number(values, errors)
      end

      private def self.validate_vat_number(values : Values, errors) : Nil
        identifiers = Partiduo::Core::Identifiers
        unless values.vat_number.empty?
          if !Partiduo::Core::SettingsRules.valid_vat_number?(values.vat_number)
            errors << error("vat_number", "invalid", {"value" => values.vat_number})
          elsif values.vat_number.starts_with?("FR") && identifiers.valid_siren?(values.siren) &&
                Partiduo::Vat::Fr::VatNumber.siren(values.vat_number) != values.siren
            errors << error("vat_number", "siren_mismatch", {"siren" => values.siren})
          end
        end
      end

      private def self.validate_bank_ids(values : Values, errors) : Nil
        identifiers = Partiduo::Core::Identifiers
        unless values.iban.empty? || identifiers.valid_iban?(values.iban)
          errors << error("iban", "invalid", {"value" => values.iban})
        end
        unless values.bic.empty? || identifiers.valid_bic?(values.bic)
          errors << error("bic", "invalid", {"value" => values.bic})
        end
      end

      private def self.validate_item(values : Values, current : Card?, errors) : Nil
        {"siren" => values.siren, "siret" => values.siret, "routing_id" => values.routing_id,
         "vat_number" => values.vat_number, "iban" => values.iban, "bic" => values.bic}.each do |field, value|
          errors << error(field, "not_applicable") unless value.empty?
        end
        errors << error("delivery_addresses", "not_applicable") unless values.delivery_addresses.empty?

        unless Units.valid?(values.unit_code)
          errors << error("unit_code", "invalid", {"value" => values.unit_code})
        end
        {"sale_price" => values.sale_price, "purchase_price" => values.purchase_price}.each do |field, price|
          next if price.nil?
          if price < 0
            errors << error(field, "negative")
          elsif price.round(PRICE_DECIMALS) != price
            errors << error(field, "too_precise", {"decimals" => PRICE_DECIMALS.to_s})
          elsif price >= MAX_PRICE
            errors << error(field, "too_large")
          end
        end
        if rate_id = values.vat_rate_id
          rate = Partiduo::Vat::Rate.filter(id: rate_id).first
          if rate.nil?
            errors << error("vat_rate_id", "not_found")
          elsif !rate.enabled && current.try(&.vat_rate_id) != rate_id
            errors << error("vat_rate_id", "disabled", {"code" => rate.code!})
          end
        end
      end

      private def self.validate_address(path : String, address : AddressValues, errors) : Nil
        ADDRESS_SIZES.each do |field, max|
          value = address_value(address, field)
          if value.size > max
            errors << FieldError.new("#{path}.#{field}", "cards.errors.card.address.too_long", {"max" => max.to_s})
          end
        end
        unless address.country_code.matches?(COUNTRY_FORMAT)
          errors << FieldError.new("#{path}.country_code", "cards.errors.card.address.country_invalid",
            {"value" => address.country_code})
        end
      end

      # Adresse entièrement vide : absente. Pays vide : celui de la société.
      private def self.normalize_address(input : Api::AddressInput) : AddressValues?
        values = AddressValues.new(
          label: text(input.label),
          line1: text(input.line1),
          line2: text(input.line2),
          postcode: text(input.postcode).upcase,
          city: text(input.city),
          country_code: text(input.country_code).upcase,
        )
        return if [values.label, values.line1, values.line2, values.postcode, values.city, values.country_code]
                    .all?(&.empty?)
        return values unless values.country_code.empty?
        values.copy_with(country_code: Partiduo::Core::SettingsRules.current.try(&.country_code).to_s)
      end

      # Enregistre la fiche et ses adresses (sans publier l'événement).
      def self.save(card : Card, values : Values) : Card
        card.category = values.category
        code = values.code
        if code.empty?
          code = card.persisted? ? card.code! : QuickCode.available(QuickCode.base_from_name(values.name), card.id)
        end
        card.code = code
        card.name = values.name
        card.description = values.description
        card.enabled = values.enabled
        card.vat_number = values.vat_number
        card.siren = values.siren
        card.siret = values.siret
        card.routing_id = values.routing_id
        card.iban = values.iban
        card.bic = values.bic
        card.email = values.email
        card.phone = values.phone
        card.contact_name = values.contact_name
        card.unit_code = values.unit_code
        card.sale_price = values.sale_price
        card.purchase_price = values.purchase_price
        card.vat_rate_id = values.vat_rate_id
        card.extra = JSON::Any.new(values.extra)
        card.customer_nature = values.category.kind == "customer" ? values.customer_nature : ""
        card.pdf_copy = values.pdf_copy
        card.save!

        Address.filter(card_id: card.id).delete(raw: true)
        if main = values.address
          create_address(card, "main", 0, main)
        end
        values.delivery_addresses.each_with_index { |address, index| create_address(card, "delivery", index, address) }
        card
      end

      private def self.create_address(card : Card, kind : String, position : Int32, values : AddressValues) : Nil
        Address.create!(card: card, kind: kind, position: position, label: values.label, line1: values.line1,
          line2: values.line2, postcode: values.postcode, city: values.city, country_code: values.country_code)
      end

      private def self.compact_digits(value : String?) : String
        text(value).gsub(/[\s.\-]/, "")
      end

      private def self.text(value : String?) : String
        value.try(&.strip) || ""
      end

      private def self.field_value(values : Values, field : String) : String
        case field
        when "name"         then values.name
        when "description"  then values.description
        when "email"        then values.email
        when "phone"        then values.phone
        when "contact_name" then values.contact_name
        else                     raise ArgumentError.new("champ inconnu : #{field}")
        end
      end

      private def self.address_value(address : AddressValues, field : String) : String
        case field
        when "label"    then address.label
        when "line1"    then address.line1
        when "line2"    then address.line2
        when "postcode" then address.postcode
        when "city"     then address.city
        else                 raise ArgumentError.new("champ inconnu : #{field}")
        end
      end

      def self.error(field : String, code : String, params = {} of String => String) : FieldError
        FieldError.new(field, "cards.errors.card.#{field}.#{code}", params)
      end
    end
  end
end
