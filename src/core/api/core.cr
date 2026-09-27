# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    # Contrat du socle. Exemple minimal de *requête* : lecture seule, objet de
    # vue immuable en retour, droits vérifiés en tête.
    module Core
      # Une pièce du registre, vue de l'interface (menus, écran des modules).
      record ModuleView, code : String, name_key : String, kind : String, version : String, active : Bool

      record InstanceView, version : String, api_version : String, domain : String, modules : Array(ModuleView)

      # Date du jour dans le fuseau de l'instance (`PARTIDUO_TIME_ZONE`), à
      # minuit UTC : date par défaut des écrans (émission, règlement, relevé).
      def self.today : Time
        Partiduo::Config.today
      end

      # Description de l'instance : versions et pièces enregistrées.
      # Tout utilisateur authentifié peut la lire.
      def self.instance(actor : Actor) : InstanceView
        Guard.authorize_account!(actor)

        modules = Partiduo::Modules.manifests.values.map do |manifest|
          ModuleView.new(
            code: manifest.code,
            name_key: manifest.name,
            kind: manifest.kind.to_s.downcase,
            version: manifest.version,
            active: Partiduo::Modules.active?(manifest.code),
          )
        end

        InstanceView.new(
          version: Partiduo::VERSION,
          api_version: Partiduo::API_VERSION,
          domain: Partiduo::Config.domain,
          modules: modules,
        )
      end
    end
  end
end
