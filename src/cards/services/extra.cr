# SPDX-License-Identifier: AGPL-3.0-or-later

require "json"

module Partiduo
  module Cards
    # Validation applicative de `Card#extra` selon la définition de la
    # catégorie (ADR-001 D3), qui remplace le stockage `ad_value text` sans
    # contrôle de `fiche_detail`.
    module Extra
      VALUE_TYPES     = %w[text number date boolean card]
      DEFAULT_TEXT    =  255
      MAX_TEXT        = 4000
      DEFAULT_DECIMAL =    4
      MAX_DECIMALS    =    8
      DATE_FORMAT     = /\A\d{4}-\d{2}-\d{2}\z/
      NUMBER_FORMAT   = /\A-?\d{1,20}(\.\d+)?\z/

      alias FieldError = Partiduo::Api::FieldError

      # Valeurs normalisées (clés triées selon l'ordre des attributs) et
      # erreurs. Une valeur vide (`nil`, chaîne blanche) est omise.
      def self.normalize(attributes : Array(CategoryAttribute), input : Hash(String, JSON::Any),
                         card_id : Int64 | Int32? = nil) : {Hash(String, JSON::Any), Array(FieldError)}
        errors = [] of FieldError
        values = {} of String => JSON::Any
        known = attributes.map(&.key!)

        input.each_key do |key|
          next if known.includes?(key)
          errors << error(key, "unknown", {"key" => key})
        end

        attributes.each do |attribute|
          key = attribute.key!
          raw = input[key]?
          if raw.nil? || blank?(raw)
            errors << error(key, "required", {"label" => attribute.label!}) if attribute.required
            next
          end
          value = coerce(attribute, raw, card_id, errors)
          values[key] = value if value
        end
        {values, errors}
      end

      private def self.coerce(attribute : CategoryAttribute, raw : JSON::Any, card_id : Int64 | Int32?,
                              errors : Array(FieldError)) : JSON::Any?
        case attribute.value_type
        when "number"  then coerce_number(attribute, raw, errors)
        when "date"    then coerce_date(attribute, raw, errors)
        when "boolean" then coerce_boolean(attribute, raw, errors)
        when "card"    then coerce_card(attribute, raw, card_id, errors)
        else                coerce_text(attribute, raw, errors)
        end
      end

      private def self.coerce_text(attribute : CategoryAttribute, raw : JSON::Any, errors) : JSON::Any?
        text = raw.as_s?
        return invalid(attribute, "text", errors) if text.nil?
        max = attribute.max_length || DEFAULT_TEXT
        if text.strip.size > max
          errors << error(attribute.key!, "too_long", params(attribute).merge({"max" => max.to_s}))
          return
        end
        JSON::Any.new(text.strip)
      end

      # Décimal exact : chaîne ou entier JSON ; jamais un flottant.
      private def self.coerce_number(attribute : CategoryAttribute, raw : JSON::Any, errors) : JSON::Any?
        text = raw.as_s?.try(&.strip) || raw.as_i64?.try(&.to_s)
        return invalid(attribute, "number", errors) if text.nil? || !text.matches?(NUMBER_FORMAT)
        number = BigDecimal.new(text)
        decimals = attribute.decimals || DEFAULT_DECIMAL
        if number.round(decimals) != number
          errors << error(attribute.key!, "too_precise", params(attribute).merge({"decimals" => decimals.to_s}))
          return
        end
        JSON::Any.new(number.to_s)
      end

      private def self.coerce_date(attribute : CategoryAttribute, raw : JSON::Any, errors) : JSON::Any?
        text = raw.as_s?.try(&.strip)
        return invalid(attribute, "date", errors) if text.nil? || !valid_date?(text)
        JSON::Any.new(text)
      end

      private def self.coerce_boolean(attribute : CategoryAttribute, raw : JSON::Any, errors) : JSON::Any?
        flag = raw.as_bool?
        return invalid(attribute, "boolean", errors) if flag.nil?
        JSON::Any.new(flag)
      end

      private def self.coerce_card(attribute : CategoryAttribute, raw : JSON::Any, card_id : Int64 | Int32?,
                                   errors) : JSON::Any?
        id = raw.as_i64? || raw.as_s?.try(&.strip.to_i64?)
        return invalid(attribute, "card", errors) if id.nil?
        if id == card_id || !Card.filter(id: id).exists?
          errors << error(attribute.key!, "card_not_found", params(attribute).merge({"id" => id.to_s}))
          return
        end
        JSON::Any.new(id)
      end

      private def self.params(attribute : CategoryAttribute) : Hash(String, String)
        {"label" => attribute.label!}
      end

      private def self.invalid(attribute : CategoryAttribute, type : String, errors : Array(FieldError)) : Nil
        errors << error(attribute.key!, "invalid_#{type}", params(attribute))
        nil
      end

      def self.blank?(raw : JSON::Any?) : Bool
        return true if raw.nil? || raw.raw.nil?
        text = raw.as_s?
        !text.nil? && text.strip.empty?
      end

      def self.valid_date?(text : String) : Bool
        return false unless text.matches?(DATE_FORMAT)
        Time.parse_utc(text, "%Y-%m-%d")
        true
      rescue Time::Format::Error | ArgumentError
        false
      end

      def self.error(key : String, code : String, params = {} of String => String) : FieldError
        FieldError.new("extra.#{key}", "cards.errors.card.extra.#{code}", params)
      end
    end
  end
end
