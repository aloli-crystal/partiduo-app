# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Vat
    # Règles d'un taux de TVA, reprises de `Tva_Rate_MTable::check` et de ses
    # tests (`Acc_TVATest::testCheck`) : code de lettres et de chiffres, au
    # moins une lettre, cinq caractères au plus ; libellé obligatoire et
    # unique ; taux entre 0 et 100 %. S'y ajoutent les règles de catégorie de
    # l'EN 16931 (BR-S-05, BR-Z-05, BR-E-05, BR-E-10…).
    module RateRules
      CATEGORIES = %w[S Z E AE K G O L M]
      # Catégories à taux nul et motif d'exonération obligatoire.
      EXEMPT_CATEGORIES = %w[E AE K G O]
      CODE_FORMAT       = /\A[A-Z0-9]{1,5}\z/
      VATEX_FORMAT      = /\AVATEX-[A-Z]{2}-[A-Z0-9\-]{1,20}\z/
      MAX_LABEL         =  64
      MAX_REASON        = 255
      RATE_DECIMALS     =   4
      MAX_RATE          = BigDecimal.new(100)

      record Values,
        code : String,
        label : String,
        rate : BigDecimal,
        description : String,
        category : String,
        exemption_code : String,
        exemption_reason : String,
        reverse_charge : Bool,
        sale_on_payment : Bool,
        purchase_on_payment : Bool,
        enabled : Bool

      def self.normalize(input : Partiduo::Api::Vat::RateInput) : Values
        rate = input.rate
        category = input.category.try(&.strip.upcase).presence || (rate.zero? ? "Z" : "S")
        Values.new(
          code: input.code.strip.upcase,
          label: input.label.strip,
          rate: rate,
          description: input.description.try(&.strip) || "",
          category: category,
          exemption_code: input.exemption_code.try(&.strip.upcase) || "",
          exemption_reason: input.exemption_reason.try(&.strip) || "",
          reverse_charge: input.reverse_charge,
          sale_on_payment: input.sale_on_payment,
          purchase_on_payment: input.purchase_on_payment,
          enabled: input.enabled,
        )
      end

      def self.validate(values : Values, current_id : Int64? = nil) : Array(Partiduo::Api::FieldError)
        errors = [] of Partiduo::Api::FieldError
        validate_code(values.code, current_id, errors)

        if values.label.empty?
          errors << error("label", "blank")
        elsif values.label.size > MAX_LABEL
          errors << error("label", "too_long", {"max" => MAX_LABEL.to_s})
        elsif taken?(Rate.filter(label__iexact: values.label), current_id)
          errors << error("label", "taken", {"value" => values.label})
        end

        rate = values.rate
        rate_valid = false
        if rate < 0 || rate > MAX_RATE
          errors << error("rate", "out_of_range")
        elsif rate.round(RATE_DECIMALS) != rate
          errors << error("rate", "too_precise", {"decimals" => RATE_DECIMALS.to_s})
        else
          rate_valid = true
        end

        validate_category(values, rate_valid, errors)
        errors
      end

      private def self.validate_code(code : String, current_id : Int64?, errors) : Nil
        if code.empty?
          errors << error("code", "blank")
        elsif code.size > 5
          errors << error("code", "too_long")
        elsif !code.matches?(CODE_FORMAT)
          errors << error("code", "invalid_characters")
        elsif code.each_char.all?(&.ascii_number?)
          errors << error("code", "digits_only")
        elsif taken?(Rate.filter(code: code), current_id)
          errors << error("code", "taken", {"value" => code})
        end
      end

      # Les règles de taux par catégorie ne s'appliquent qu'à un taux valide.
      private def self.validate_category(values : Values, rate_valid : Bool, errors) : Nil
        category = values.category
        unless CATEGORIES.includes?(category)
          errors << error("category", "invalid", {"value" => category})
          return
        end

        case rate_valid && category
        when "S"
          errors << error("rate", "must_be_positive") unless values.rate > 0
        when "Z"
          errors << error("rate", "must_be_zero") unless values.rate.zero?
        when .in?(EXEMPT_CATEGORIES)
          # La facture ne porte pas de TVA : l'autoliquidation (AE) se calcule
          # à part, par `reverse_charge` et le taux de l'acquéreur.
          errors << error("rate", "must_be_zero") unless values.rate.zero? || values.reverse_charge
          if values.exemption_code.empty? && values.exemption_reason.empty?
            errors << error("exemption_code", "required", {"category" => category})
          end
        end
        validate_exemption(values, errors)
      end

      # Motif d'exonération : réservé aux catégories exonérées, code VATEX.
      private def self.validate_exemption(values : Values, errors) : Nil
        category = values.category
        exempt = EXEMPT_CATEGORIES.includes?(category)
        if !exempt && !(values.exemption_code.empty? && values.exemption_reason.empty?)
          errors << error("exemption_code", "not_applicable", {"category" => category})
        end
        if !values.exemption_code.empty? && !values.exemption_code.matches?(VATEX_FORMAT)
          errors << error("exemption_code", "invalid", {"value" => values.exemption_code})
        end
        if values.exemption_reason.size > MAX_REASON
          errors << error("exemption_reason", "too_long", {"max" => MAX_REASON.to_s})
        end
      end

      private def self.taken?(query, current_id : Int64?) : Bool
        query = query.exclude(id: current_id) if current_id
        query.exists?
      end

      def self.assign(rate : Rate, values : Values) : Rate
        rate.code = values.code
        rate.label = values.label
        rate.rate = values.rate
        rate.description = values.description
        rate.category = values.category
        rate.exemption_code = values.exemption_code
        rate.exemption_reason = values.exemption_reason
        rate.reverse_charge = values.reverse_charge
        rate.sale_on_payment = values.sale_on_payment
        rate.purchase_on_payment = values.purchase_on_payment
        rate.enabled = values.enabled
        rate
      end

      def self.error(field : String, code : String, params = {} of String => String) : Partiduo::Api::FieldError
        Partiduo::Api::FieldError.new(field, "vat.errors.rate.#{field}.#{code}", params)
      end
    end
  end
end
