# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    # Erreur de validation rattachée à un champ de l'entrée d'une commande.
    #
    # * `field` : chemin du champ dans l'entrée (`"date"`, `"lines[2].amount"`),
    #   ou `BASE` pour une erreur qui porte sur l'ensemble ;
    # * `key` : clé i18n complète du message (`"accounting.errors.entry.unbalanced"`) ;
    # * `params` : valeurs interpolées dans le message (`%{difference}`), déjà
    #   converties en chaînes par le cœur.
    #
    # Le cœur ne produit jamais de texte : l'interface affiche `message`, traduit
    # dans la langue de l'utilisateur (ADR-005 D2, D7).
    record FieldError, field : String, key : String, params : Hash(String, String) = {} of String => String do
      BASE = "base"

      def self.base(key : String, params : Hash(String, String) = {} of String => String) : FieldError
        new(BASE, key, params)
      end

      def base? : Bool
        field == BASE
      end

      # Message traduit dans la langue courante (`I18n.locale`). Un paramètre
      # `count` entier choisit la forme du pluriel (`one` / `other`, ADR-005 D7).
      def message : String
        if count = params["count"]?.try(&.to_i64?)
          I18n.t(key, params, count: count)
        else
          I18n.t(key, params)
        end
      end
    end
  end
end
