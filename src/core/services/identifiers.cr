# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Core
    # Identifiants d'entreprise du socle (ADR-004 D5 : les champs de
    # facturation française appartiennent au cœur).
    module Identifiers
      # SIREN : 9 chiffres, clé de Luhn.
      def self.valid_siren?(value : String) : Bool
        value.matches?(/\A[0-9]{9}\z/) && luhn?(value)
      end

      # SIRET : SIREN + NIC (5 chiffres), clé de Luhn sur les 14 chiffres. Seule
      # exception : les établissements de La Poste (SIREN 356000000), dont la
      # somme des chiffres est un multiple de 5.
      def self.valid_siret?(value : String) : Bool
        return false unless value.matches?(/\A[0-9]{14}\z/)
        return value.each_char.sum(&.to_i) % 5 == 0 if value.starts_with?("356000000")
        luhn?(value)
      end

      def self.luhn?(digits : String) : Bool
        sum = 0
        digits.reverse.each_char.with_index do |char, index|
          digit = char.to_i
          if index.odd?
            digit *= 2
            digit -= 9 if digit > 9
          end
          sum += digit
        end
        sum % 10 == 0
      end

      # Supprime espaces, points et tirets, et passe en majuscules :
      # `"fr 40 303 265 045"` → `"FR40303265045"`.
      def self.compact(value : String) : String
        value.gsub(/[\s.\-]/, "").upcase
      end
    end
  end
end
