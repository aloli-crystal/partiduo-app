# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    # Qui appelle le contrat. Toute commande et toute requête reçoivent un
    # acteur en premier argument et vérifient ses droits (ADR-005 D2).
    #
    # L'interface construit l'acteur de l'utilisateur connecté (lot 0 :
    # `Actor.for(user)` à partir de son profil) ; les outils en ligne de
    # commande (`partiduo-provision`, `partiduo-migrate`) utilisent `Actor.system`.
    record Actor, user_id : Int64?, permissions : Set(String), system : Bool = false do
      # Acteur technique : toutes les permissions. Réservé aux outils en ligne
      # de commande et aux abonnés d'événements, jamais à une requête HTTP.
      def self.system : Actor
        new(nil, Set(String).new, true)
      end

      # Acteur non authentifié : aucune permission.
      def self.anonymous : Actor
        new(nil, Set(String).new)
      end

      def self.user(user_id : Int64, permissions : Enumerable(String)) : Actor
        new(user_id, permissions.to_set)
      end

      def authenticated? : Bool
        system || !user_id.nil?
      end

      def can?(permission : String) : Bool
        system || (authenticated? && permissions.includes?(permission))
      end
    end
  end
end
