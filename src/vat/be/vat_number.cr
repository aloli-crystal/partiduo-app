# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Vat
    module Be
      # Numéro de TVA belge : `BE` + numéro d'entreprise à 10 chiffres,
      # commençant par 0 ou 1, dont les deux derniers chiffres valent
      # `97 − (8 premiers chiffres mod 97)`.
      module VatNumber
        FORMAT = /\ABE([01][0-9]{9})\z/

        # Numéro déjà normalisé (majuscules, sans espace ni ponctuation).
        def self.valid?(number : String) : Bool
          match = FORMAT.match(number)
          return false if match.nil?

          digits = match[1]
          97 - (digits[0, 8].to_i64 % 97) == digits[8, 2].to_i
        end
      end
    end
  end
end
