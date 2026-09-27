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

      # IBAN (ISO 13616) : pays, clé, BBAN de 11 à 30 caractères ; clé
      # contrôlée modulo 97 (ISO 7064). Valeur déjà compactée.
      def self.valid_iban?(value : String) : Bool
        return false unless value.matches?(/\A[A-Z]{2}[0-9]{2}[A-Z0-9]{11,30}\z/)
        rearranged = value[4..] + value[0, 4]
        digits = String.build do |io|
          rearranged.each_char { |char| char.ascii_number? ? io << char : io << (char.ord - 'A'.ord + 10) }
        end
        digits.each_char.reduce(0) { |rest, char| (rest * 10 + char.to_i) % 97 } == 1
      end

      # BIC (ISO 9362) : banque (4 lettres), pays (2 lettres), localité
      # (2 caractères), agence facultative (3 caractères).
      def self.valid_bic?(value : String) : Bool
        value.matches?(/\A[A-Z]{4}[A-Z]{2}[A-Z0-9]{2}([A-Z0-9]{3})?\z/)
      end

      # Supprime espaces, points et tirets, et passe en majuscules :
      # `"fr 40 303 265 045"` → `"FR40303265045"`.
      def self.compact(value : String) : String
        value.gsub(/[\s.\-]/, "").upcase
      end
    end
  end
end
