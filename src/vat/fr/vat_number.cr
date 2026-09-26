# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Vat
    module Fr
      # Numéro de TVA intracommunautaire français : `FR` + clé (2 caractères)
      # + SIREN (9 chiffres). Une clé numérique est contrôlée :
      # `(12 + 3 × (SIREN mod 97)) mod 97` ; une clé alphanumérique (numéros
      # attribués aux non-établis) n'est contrôlée que dans sa forme.
      module VatNumber
        FORMAT = /\AFR([0-9A-Z]{2})([0-9]{9})\z/

        # Numéro déjà normalisé (majuscules, sans espace ni ponctuation).
        def self.valid?(number : String) : Bool
          match = FORMAT.match(number)
          return false if match.nil?

          key, siren = match[1], match[2]
          return true unless key.each_char.all?(&.ascii_number?)

          key.to_i == expected_key(siren)
        end

        # SIREN porté par le numéro, ou `nil` si le numéro est mal formé.
        def self.siren(number : String) : String?
          FORMAT.match(number).try(&.[2])
        end

        def self.expected_key(siren : String) : Int32
          ((12 + 3 * (siren.to_i64 % 97)) % 97).to_i
        end
      end
    end
  end
end
