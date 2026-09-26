# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    # Refus d'accès : levé par toute commande ou requête appelée sans le droit
    # ou sur un module inactif. Ce n'est pas une erreur de saisie : l'interface
    # le traduit en réponse 403 (ou 404), elle ne l'affiche pas champ par champ.
    abstract class AccessDenied < Exception
      # Clé i18n du message destiné à l'utilisateur.
      abstract def key : String
    end

    # Le module (ou l'extension) visé n'est pas actif sur l'instance (ADR-006 D2).
    class ModuleDisabled < AccessDenied
      getter module_code : String

      def initialize(@module_code : String)
        super("module #{@module_code} inactif")
      end

      def key : String
        "partiduo.api.errors.module_disabled"
      end
    end

    # L'acteur n'a pas la permission requise (ADR-003 D4).
    class Forbidden < AccessDenied
      getter permission : String?

      def initialize(@permission : String? = nil)
        super(@permission ? "permission #{@permission} requise" : "acteur non authentifié")
      end

      def key : String
        "partiduo.api.errors.forbidden"
      end
    end

    # L'objet demandé n'existe pas (ou n'est pas visible par l'acteur).
    class NotFound < Exception
      getter resource : String

      def initialize(@resource : String, id = nil)
        super(id.nil? ? "#{@resource} introuvable" : "#{@resource} #{id} introuvable")
      end

      def key : String
        "partiduo.api.errors.not_found"
      end
    end
  end
end
