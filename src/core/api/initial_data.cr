# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    # Point d'accroche du jeu de données initial (ADR-001 D2 § Provisionnement,
    # convention C6) : chaque pièce du registre — socle, module ou extension —
    # déclare ce qu'elle charge dans une instance neuve, selon le régime fiscal
    # (plan comptable BE ou FR, journaux par défaut, catégories de fiches, taux
    # de TVA, profil administrateur…).
    #
    # `Partiduo::Api::Core.provision` exécute, dans sa transaction, les
    # chargeurs des pièces *actives*, par ordre croissant puis par nom. Un
    # chargeur qui lève annule tout le provisionnement. Il écrit par le contrat
    # (`Partiduo::Api::<App>`) avec `context.actor` (acteur système).
    #
    # ```
    # # src/accounting/initial_data.cr (lot 1)
    # Partiduo::Api::InitialData.register("ACCOUNTING", "chart_of_accounts", order: 10) do |context|
    #   Partiduo::Api::Accounting.load_chart(context.actor, regime: context.tax_regime)
    # end
    # ```
    module InitialData
      # Ce que reçoit un chargeur.
      record Context,
        actor : Actor,
        tax_regime : String,
        country_code : String,
        locale : String,
        admin_email : String?,
        module_codes : Array(String)

      record Loader, owner : String, name : String, order : Int32, block : Proc(Context, Nil) do
        def id : String
          "#{owner}.#{name}"
        end
      end

      @@loaders = [] of Loader

      # Déclare un chargeur. `owner` : code du registre de la pièce qui le
      # déclare (`CORE`, `ACCOUNTING`, `SKEL`) ; il ne s'exécute que si cette
      # pièce est active. `name` : unique pour une pièce.
      def self.register(owner : String, name : String, order : Int32 = 100, &block : Context -> Nil) : Nil
        loader = Loader.new(owner, name, order, block)
        if @@loaders.any?(&.id.==(loader.id))
          raise ArgumentError.new("chargeur de données initiales déjà déclaré : #{loader.id}")
        end
        @@loaders << loader
      end

      # Chargeurs des pièces actives, dans l'ordre d'exécution.
      def self.loaders : Array(Loader)
        @@loaders
          .select { |loader| Partiduo::Modules.active?(loader.owner) }
          .sort_by! { |loader| {loader.order, loader.owner, loader.name} }
      end

      # Tous les chargeurs déclarés, actifs ou non.
      def self.all_loaders : Array(Loader)
        @@loaders.dup
      end

      # Exécute les chargeurs actifs ; renvoie leurs identifiants. Appelé par
      # `Partiduo::Api::Core.provision`, dans sa transaction.
      def self.run(context : Context) : Array(String)
        loaders.map do |loader|
          loader.block.call(context)
          loader.id
        end
      end

      # Specs : retire un chargeur déclaré par un exemple.
      def self.unregister(owner : String, name : String) : Nil
        @@loaders.reject! { |loader| loader.owner == owner && loader.name == name }
      end
    end
  end
end
