# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    # Résultat d'une commande (ou d'une requête de contrôle) : soit une valeur —
    # en général un objet de vue —, soit des erreurs par champ.
    #
    # ```
    # result = Partiduo::Api::Accounting.check_entry(actor, input)
    # if result.success?
    #   result.value!.balanced?
    # else
    #   result.errors_for("lines[0].amount").map(&.message)
    # end
    # ```
    #
    # Une commande sans valeur utile renvoie `Result(Nil)`.
    struct Result(T)
      getter errors : Array(FieldError)

      @value : T?

      def self.success(value : T) : self
        new(value, [] of FieldError)
      end

      def self.failure(errors : Array(FieldError)) : self
        raise ArgumentError.new("un échec doit porter au moins une erreur") if errors.empty?
        new(nil, errors)
      end

      def self.failure(error : FieldError) : self
        failure([error])
      end

      protected def initialize(@value : T?, @errors : Array(FieldError))
      end

      def success? : Bool
        @errors.empty?
      end

      def failure? : Bool
        !success?
      end

      # La valeur ; lève `NilAssertionError` si le résultat est un échec.
      def value! : T
        raise NilAssertionError.new("résultat en échec : #{@errors.map(&.key).join(", ")}") if failure?
        @value.as(T)
      end

      def value? : T?
        @value
      end

      def errors_for(field : String) : Array(FieldError)
        @errors.select { |error| error.field == field }
      end

      # Clés i18n des erreurs, pratique dans les specs : `result.error_keys.should contain(...)`.
      def error_keys : Array(String)
        @errors.map(&.key)
      end
    end
  end
end
