# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    # Qui appelle le contrat. Toute commande et toute requête reçoivent un
    # acteur en premier argument et vérifient ses droits (ADR-005 D2).
    #
    # L'interface obtient l'acteur de l'utilisateur connecté par
    # `Partiduo::Api::Auth.actor(jeton de session)` (droits de son profil,
    # niveau de sécurité de sa session — ADR-002 D2) ; les outils en ligne de
    # commande (`partiduo-provision`, `partiduo-migrate`) utilisent `Actor.system`.
    #
    # `level` : niveau de la session (0 enrôlement, 1 mot de passe,
    # 2 mot de passe + TOTP, 3 passkey), 3 pour l'acteur système.
    record Actor, user_id : Int64?, permissions : Set(String), system : Bool = false, level : Int32 = 0 do
      # Acteur technique : toutes les permissions. Réservé aux outils en ligne
      # de commande et aux abonnés d'événements, jamais à une requête HTTP.
      def self.system : Actor
        new(nil, Set(String).new, true, 3)
      end

      # Acteur non authentifié : aucune permission.
      def self.anonymous : Actor
        new(nil, Set(String).new)
      end

      def self.user(user_id : Int64, permissions : Enumerable(String), level : Int32 = 0) : Actor
        new(user_id, permissions.to_set, false, level)
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
