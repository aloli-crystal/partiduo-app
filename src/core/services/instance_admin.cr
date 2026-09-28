# SPDX-License-Identifier: AGPL-3.0-or-later

require "digest/sha256"

module Partiduo
  module Core
    # Gestes de cycle de vie d'une instance, pour l'interface en ligne de
    # commande d'instance (`manage instance`, ADR-008 D4,
    # `doc/api/instance-cli.adoc`) : lecture seule, migrations, préparation
    # de sauvegarde. Rien ici ne lit ni n'écrit de donnée comptable (ADR-008
    # D3) : seuls le catalogue PostgreSQL, la table des migrations, le journal
    # d'audit et la table des pièces jointes (noms de stockage, tailles,
    # empreintes) sont touchés.
    module InstanceAdmin
      # Réglage PostgreSQL qui met la base en lecture seule pour toute
      # nouvelle session (D-CLI-003).
      READ_ONLY_SETTING = "default_transaction_read_only"

      # Actions inscrites au journal d'audit de l'instance.
      AUDIT_READ_ONLY_ON  = "instance.read_only.on"
      AUDIT_READ_ONLY_OFF = "instance.read_only.off"

      # Refus ou erreur d'un geste, rendu par l'interface en ligne de
      # commande : `code` (catégorie du contrat, qui fixe le code de
      # sortie), `reason` (clé stable et précise), message traduit, détails.
      class Failure < Exception
        getter code : String
        getter reason : String
        getter details : Array(Partiduo::Api::FieldError)

        def initialize(@code : String, @reason : String, message : String,
                       @details = [] of Partiduo::Api::FieldError)
          super(message)
        end
      end

      # Nom de la base de l'instance.
      def self.database_name : String
        scalar_string("SELECT current_database()")
      end

      # Joignabilité de la base (lève `DB::ConnectionRefused` ou une erreur
      # de socket sinon).
      def self.ping! : Nil
        scalar_string("SELECT 1::text")
      end

      # La table existe-t-elle ? (`to_regclass` ne lève pas d'erreur.)
      def self.table_exists?(name : String) : Bool
        Marten::DB::Connection.default.open do |db|
          !db.scalar("SELECT to_regclass($1)::text", name).nil?
        end
      end

      # --- Lecture seule ---------------------------------------------------------

      # La base est-elle en lecture seule pour les nouvelles sessions ?
      def self.read_only? : Bool
        Marten::DB::Connection.default.open do |db|
          db.scalar(<<-SQL, "#{READ_ONLY_SETTING}=on").as(Bool)
            SELECT EXISTS (
              SELECT 1 FROM pg_db_role_setting s, unnest(s.setconfig) AS cfg
              WHERE s.setdatabase = (SELECT oid FROM pg_database WHERE datname = current_database())
                AND s.setrole = 0 AND lower(cfg) = $1
            )
            SQL
        end
      end

      # Pose (`true`) ou lève (`false`) la lecture seule de la base. Effet sur
      # les *nouvelles* sessions ; `terminate_sessions` coupe aussi les
      # sessions ouvertes des autres processus (le serveur de l'instance se
      # reconnecte). Renvoie le nombre de sessions coupées.
      def self.set_read_only(on : Bool, terminate_sessions : Bool = false) : Int32
        statement = on ? "SET #{READ_ONLY_SETTING} = on" : "RESET #{READ_ONLY_SETTING}"
        Marten::DB::Connection.default.open do |db|
          db.exec(<<-SQL)
            DO $$ BEGIN
              EXECUTE format('ALTER DATABASE %I #{statement}', current_database());
            END $$
            SQL
        end
        terminate_sessions ? terminate_other_sessions : 0
      end

      # Coupe les sessions des autres processus sur cette base (celles que
      # le rôle courant a le droit de signaler).
      def self.terminate_other_sessions : Int32
        Marten::DB::Connection.default.open do |db|
          db.scalar(<<-SQL).as(Int64).to_i32
            SELECT count(*) FILTER (WHERE pg_terminate_backend(pid))
            FROM pg_stat_activity
            WHERE datname = current_database() AND pid <> pg_backend_pid()
              AND backend_type = 'client backend'
            SQL
        end
      end

      # Les sessions *de ce processus* écrivent même si la base est en
      # lecture seule : l'interface en ligne de commande est l'outil qui lève
      # cet état et qui migre (D-CLI-003). Réglé sur chaque connexion du
      # pool, présente et future.
      def self.allow_writes_in_this_process! : Nil
        Marten::DB::Connection.default.open do |conn|
          # `setup_connection` ne règle que les connexions libres du pool :
          # celle qu'on tient est réglée à part.
          conn.exec("SET SESSION #{READ_ONLY_SETTING} = off")
          database = conn.context.as(::DB::Database)
          database.setup_connection do |connection|
            connection.exec("SET SESSION #{READ_ONLY_SETTING} = off")
          end
        end
      end

      # Dernière mise en lecture seule inscrite au journal d'audit : moment
      # et détail (JSON : motif, tâche, demandeur).
      def self.last_read_only_event : Partiduo::Auth::AuditEvent?
        Partiduo::Auth::AuditEvent.filter(action: AUDIT_READ_ONLY_ON).order("-id").first
      end

      # --- Migrations ------------------------------------------------------------

      record MigrationRef, app : String, name : String

      def self.runner : Marten::DB::Management::Migrations::Runner
        Marten::DB::Management::Migrations::Runner.new(Marten::DB::Connection.default)
      end

      # Migrations à appliquer, dans l'ordre d'application.
      def self.pending_migrations : Array(MigrationRef)
        runner.plan.reject(&.[1]).map { |(migration, _)| reference(migration) }
      end

      # Nombre de migrations enregistrées comme appliquées.
      def self.applied_migrations_count : Int32
        return 0 unless table_exists?("marten_migrations")
        Marten::DB::Connection.default.open do |db|
          db.scalar("SELECT count(*) FROM marten_migrations").as(Int64).to_i32
        end
      end

      # Applique les migrations en attente ; renvoie celles appliquées. Une
      # migration en échec lève l'exception de Marten ou de PostgreSQL ;
      # celles déjà appliquées le restent (chacune dans sa transaction).
      def self.migrate(applied : Array(MigrationRef) = [] of MigrationRef) : Array(MigrationRef)
        runner.execute do |progress|
          migration = progress.migration
          if progress.type.migration_apply_forward_success? && migration
            applied << reference(migration)
          end
        end
        applied
      end

      private def self.reference(migration : Marten::DB::Migration) : MigrationRef
        MigrationRef.new(migration.class.app_config.label, migration.class.migration_name)
      end

      # --- Préparation de sauvegarde ---------------------------------------------

      # Une pièce jointe à inclure dans la sauvegarde. `path` : chemin
      # relatif à la racine du stockage. `state` : `present`, `missing`, ou
      # `corrupted` (empreinte différente, seulement si vérifiée).
      record BackupFile, path : String, bytes : Int64, sha256 : String, state : String

      # Taille des lots de lecture de la table des pièces jointes.
      BATCH_SIZE = 500

      # Pièces jointes enregistrées, par ordre d'identifiant, et leur état
      # sur disque. Le nom déposé par l'utilisateur n'est pas rendu (il peut
      # révéler le contenu d'une pièce, ADR-008 D3). Lecture par lots
      # d'identifiants, empreinte calculée en flux : la mémoire ne dépend
      # ni du nombre ni de la taille des pièces.
      def self.backup_files(verify : Bool = false) : Array(BackupFile)
        files = [] of BackupFile
        each_backup_file(verify) { |file| files << file }
        files
      end

      def self.each_backup_file(verify : Bool = false, & : BackupFile ->) : Nil
        root = media_root
        last_id = 0_i64
        loop do
          batch = Partiduo::Core::Attachment.filter(id__gt: last_id).order(:id).limit(BATCH_SIZE).to_a
          break if batch.empty?
          batch.each do |attachment|
            yield backup_file(root, attachment, verify)
          end
          last_id = batch.last.pk!.as(Int64)
          break if batch.size < BATCH_SIZE
        end
      end

      private def self.backup_file(root : String, attachment : Partiduo::Core::Attachment, verify : Bool) : BackupFile
        path = attachment.storage_name!
        full = File.join(root, path)
        state = if !safe_relative?(path) || !File.file?(full)
                  "missing"
                elsif verify && sha256_of(full) != attachment.sha256
                  "corrupted"
                else
                  "present"
                end
        BackupFile.new(path, (attachment.byte_size || 0).to_i64, attachment.sha256.to_s, state)
      end

      # Racine absolue du stockage des pièces jointes.
      def self.media_root : String
        File.expand_path(Marten.settings.media_files.root.to_s)
      end

      private def self.safe_relative?(path : String) : Bool
        !path.starts_with?('/') && !path.split('/').includes?("..")
      end

      # Empreinte calculée par blocs, sans charger le fichier en mémoire.
      private def self.sha256_of(path : String) : String
        Digest::SHA256.new.file(path).hexfinal
      end

      private def self.scalar_string(sql : String) : String
        Marten::DB::Connection.default.open { |db| db.scalar(sql).as(String) }
      end
    end
  end
end
