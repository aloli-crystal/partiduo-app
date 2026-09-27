# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Cards
    # Règles d'une catégorie de fiches, reprises de `Fiche_Def::Add`
    # (nom obligatoire et unique sans tenir compte de la casse, modèle de
    # catégorie obligatoire), `insertAttribut`, `removeAttribut` et `remove`.
    module CategoryRules
      alias FieldError = Partiduo::Api::FieldError
      alias Api = Partiduo::Api::Cards

      CODE_FORMAT    = /\A[A-Z][A-Z0-9_]{0,31}\z/
      KEY_FORMAT     = /\A[a-z][a-z0-9_]{0,39}\z/
      MAX_NAME       = 100
      MAX_LABEL      = 100
      MAX_ATTRIBUTES =  50

      record AttributeValues,
        key : String,
        label : String,
        value_type : String,
        required : Bool,
        max_length : Int32?,
        decimals : Int32?

      record Values,
        code : String,
        name : String,
        kind : String,
        description : String,
        attributes : Array(AttributeValues)

      def self.normalize(input : Api::CategoryInput) : Values
        Values.new(
          code: input.code.strip.upcase,
          name: input.name.strip,
          kind: input.kind.strip.downcase,
          description: input.description.try(&.strip) || "",
          attributes: input.attributes.map do |attribute|
            AttributeValues.new(
              key: attribute.key.strip.downcase,
              label: attribute.label.strip,
              value_type: attribute.value_type.strip.downcase,
              required: attribute.required,
              max_length: attribute.value_type == "text" ? attribute.max_length : nil,
              decimals: attribute.value_type == "number" ? attribute.decimals : nil,
            )
          end,
        )
      end

      def self.validate(values : Values, current : Category? = nil) : Array(FieldError)
        errors = [] of FieldError
        validate_code(values, current, errors)
        validate_name(values, current, errors)
        if !CardRules::KINDS.includes?(values.kind)
          errors << error("kind", "invalid", {"value" => values.kind})
        elsif current && current.kind != values.kind && Card.filter(category_id: current.id).exists?
          errors << error("kind", "in_use")
        end
        validate_attributes(values, current, errors)
        errors
      end

      private def self.validate_code(values : Values, current : Category?, errors) : Nil
        if current && current.code != values.code
          errors << error("code", "immutable")
        elsif !values.code.matches?(CODE_FORMAT)
          errors << error("code", "invalid", {"value" => values.code})
        elsif current.nil? && Category.filter(code: values.code).exists?
          errors << error("code", "taken", {"value" => values.code})
        end
      end

      private def self.validate_name(values : Values, current : Category?, errors) : Nil
        if values.name.empty?
          errors << error("name", "blank")
        elsif values.name.size > MAX_NAME
          errors << error("name", "too_long", {"max" => MAX_NAME.to_s})
        else
          query = Category.filter(name__iexact: values.name)
          query = query.exclude(id: current.id) if current
          errors << error("name", "taken", {"value" => values.name}) if query.exists?
        end
      end

      private def self.validate_attributes(values : Values, current : Category?, errors) : Nil
        if values.attributes.size > MAX_ATTRIBUTES
          errors << error("attributes", "too_many", {"max" => MAX_ATTRIBUTES.to_s})
        end
        existing = {} of String => CategoryAttribute
        if current
          CategoryAttribute.filter(category_id: current.id).each { |attribute| existing[attribute.key!] = attribute }
        end
        seen = Set(String).new

        values.attributes.each_with_index do |attribute, index|
          path = "attributes[#{index}]"
          validate_definition(attribute, path, seen, errors)
          next unless current
          validate_change(attribute, path, current, existing[attribute.key]?, errors)
        end
      end

      # Définition d'un attribut : clé, libellé, type, bornes.
      private def self.validate_definition(attribute : AttributeValues, path : String, seen : Set(String), errors) : Nil
        if !attribute.key.matches?(KEY_FORMAT)
          errors << attribute_error(path, "key", "invalid", {"value" => attribute.key})
        elsif !seen.add?(attribute.key)
          errors << attribute_error(path, "key", "duplicate", {"value" => attribute.key})
        end
        if attribute.label.empty?
          errors << attribute_error(path, "label", "blank")
        elsif attribute.label.size > MAX_LABEL
          errors << attribute_error(path, "label", "too_long", {"max" => MAX_LABEL.to_s})
        end
        unless Extra::VALUE_TYPES.includes?(attribute.value_type)
          errors << attribute_error(path, "value_type", "invalid", {"value" => attribute.value_type})
        end
        if (max = attribute.max_length) && !(1 <= max <= Extra::MAX_TEXT)
          errors << attribute_error(path, "max_length", "out_of_range", {"max" => Extra::MAX_TEXT.to_s})
        end
        if (decimals = attribute.decimals) && !(0 <= decimals <= Extra::MAX_DECIMALS)
          errors << attribute_error(path, "decimals", "out_of_range", {"max" => Extra::MAX_DECIMALS.to_s})
        end
      end

      # Un attribut déjà renseigné ne change pas de type ; il ne devient
      # obligatoire — ou n'est ajouté obligatoire — que si toutes les fiches
      # le renseignent.
      private def self.validate_change(attribute : AttributeValues, path : String, current : Category,
                                       old : CategoryAttribute?, errors) : Nil
        if old && old.value_type != attribute.value_type && used?(current, attribute.key)
          errors << attribute_error(path, "value_type", "in_use")
        end
        return if !attribute.required || old.try(&.required)
        if missing?(current, attribute.key)
          errors << attribute_error(path, "required", "missing_values")
        end
      end

      # Une fiche de la catégorie renseigne-t-elle `key` ?
      def self.used?(category : Category, key : String) : Bool
        Card.filter(category_id: category.id).filter("jsonb_exists(extra, ?)", key).exists?
      end

      private def self.missing?(category : Category, key : String) : Bool
        Card.filter(category_id: category.id).filter("NOT jsonb_exists(extra, ?)", key).exists?
      end

      # Enregistre la catégorie et ses attributs ; les valeurs d'un attribut
      # retiré sont effacées des fiches (`removeAttribut`).
      def self.save(category : Category, values : Values) : Category
        category.code = values.code
        category.name = values.name
        category.kind = values.kind
        category.description = values.description
        category.save!

        kept = values.attributes.map(&.key)
        CategoryAttribute.filter(category_id: category.id).to_a.each do |attribute|
          next if kept.includes?(attribute.key!)
          Marten::DB::Connection.default.open do |db|
            db.exec("UPDATE cards_card SET extra = extra - $1 WHERE category_id = $2", attribute.key!, category.id!.to_i64)
          end
          attribute.delete
        end
        values.attributes.each_with_index do |attribute, index|
          record = CategoryAttribute.filter(category_id: category.id, key: attribute.key).first ||
                   CategoryAttribute.new(category: category, key: attribute.key)
          record.label = attribute.label
          record.value_type = attribute.value_type
          record.required = attribute.required
          record.max_length = attribute.max_length
          record.decimals = attribute.decimals
          record.position = (index + 1) * 10
          record.save!
        end
        category
      end

      def self.error(field : String, code : String, params = {} of String => String) : FieldError
        FieldError.new(field, "cards.errors.category.#{field}.#{code}", params)
      end

      private def self.attribute_error(path : String, field : String, code : String,
                                       params = {} of String => String) : FieldError
        FieldError.new("#{path}.#{field}", "cards.errors.category.attribute.#{field}.#{code}", params)
      end
    end
  end
end
