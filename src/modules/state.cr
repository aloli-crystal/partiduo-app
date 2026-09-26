# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Modules
    # Ensemble des modules et extensions actifs sur l'instance (ADR-006 D2).
    #
    # Source, par ordre de priorité (D-018) :
    #
    # . la table `modules_activation`, dès qu'elle contient une ligne —
    #   l'administrateur a enregistré un choix (`Partiduo::Api::Modules.activate`) ;
    # . sinon `PARTIDUO_MODULES` (`Partiduo::Config.active_module_codes`) : valeur
    #   initiale de l'instance, configuration des specs et de la CI.
    #
    # La table est relue à chaque appel (une requête courte) : plusieurs
    # processus d'une même instance voient le même état sans cache à invalider.
    module State
      TABLE = "modules_activation"

      @@table_ready = false

      # Codes (en majuscules) des pièces *non socle* actives.
      def self.active_codes : Set(String)
        stored_codes || Partiduo::Config.active_module_codes.map(&.upcase).to_set
      end

      # Codes actifs enregistrés en base, ou `nil` si rien n'est enregistré
      # (table vide, absente avant `migrate`, ou base injoignable au démarrage
      # d'une commande comme `migrate` elle-même).
      def self.stored_codes : Set(String)?
        return unless table_ready?

        rows = Activation.all.to_a
        return if rows.empty?

        rows.select(&.active).compact_map(&.code).to_set
      end

      # Enregistre l'ensemble actif complet : une ligne par pièce non socle
      # enregistrée ou déjà présente en base.
      def self.save(active : Set(String), changed_by : Int64? = nil) : Nil
        codes = Partiduo::Modules.manifests.values.reject(&.socle?).map(&.code).to_set
        Activation.all.each { |row| row.code.try { |code| codes << code } }

        codes.each do |code|
          row = Activation.get(code: code) || Activation.new(code: code)
          next if row.persisted? && row.active == active.includes?(code)

          row.active = active.includes?(code)
          row.changed_by_id = changed_by
          row.save!
        end
      end

      # La table existe-t-elle ? Mémorisé une fois vrai ; `to_regclass` ne lève
      # pas d'erreur (une erreur SQL annulerait la transaction en cours).
      def self.table_ready? : Bool
        return true if @@table_ready

        exists = Marten::DB::Connection.default.open do |db|
          !db.scalar("SELECT to_regclass($1)::text", TABLE).nil?
        end
        @@table_ready = exists
      rescue DB::ConnectionRefused | Marten::DB::Errors::UnknownConnection
        # Base injoignable, ou connexions pas encore configurées (avant
        # `Marten.setup`, au chargement des specs) : rien d'enregistré.
        false
      end

      # Pour les specs qui recréent le schéma.
      def self.reset_table_cache : Nil
        @@table_ready = false
      end
    end
  end
end
