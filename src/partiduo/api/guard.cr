# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    # Vérifications d'accès appelées en tête de *chaque* commande et requête du
    # contrat. Une interface défaillante ne peut pas contourner un droit
    # (ADR-005 D2) ; un module inactif refuse l'appel (ADR-006 D2).
    #
    # ```
    # def self.post_entry(actor : Actor, input : PostEntryInput) : Result(EntryView)
    #   Guard.authorize!(actor, "accounting.entry.post", module_code: "ACCOUNTING")
    #   # ...
    # end
    # ```
    module Guard
      # Vérifie, dans cet ordre : module actif, acteur authentifié, permission.
      #
      # `permission: nil` signifie « tout utilisateur authentifié » : c'est un
      # choix explicite, pas un oubli. Une permission citée doit être déclarée
      # dans un manifeste (`Partiduo::Modules`), sinon `ArgumentError` : une
      # faute de frappe dans un nom de permission ne doit pas ouvrir ni fermer
      # un accès en silence.
      def self.authorize!(actor : Actor, permission : String?, module_code : String = "CORE") : Nil
        require_module!(module_code)
        raise Forbidden.new unless actor.authenticated?
        return if permission.nil?

        unless Partiduo::Modules.permission_declared?(permission)
          raise ArgumentError.new("permission non déclarée dans un manifeste : #{permission}")
        end
        raise Forbidden.new(permission) unless actor.can?(permission)
      end

      def self.require_module!(module_code : String) : Nil
        raise ModuleDisabled.new(module_code) unless Partiduo::Modules.active?(module_code)
      end
    end
  end
end
