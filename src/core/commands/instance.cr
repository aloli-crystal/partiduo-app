# SPDX-License-Identifier: AGPL-3.0-or-later

require "json"

module Partiduo
  module Core
    module Commands
      # `manage instance <action>` : interface en ligne de commande d'instance,
      # contrat de l'exécutant de `partiduo-admin` (ADR-008 D4). Contrat
      # versionné (`Partiduo::INSTANCE_CLI_VERSION`), décrit dans
      # `doc/api/instance-cli.adoc` : une réponse JSON sur la sortie standard,
      # codes de sortie normalisés (`EXIT_CODES`). Aucune donnée comptable
      # n'est lue ni écrite (ADR-008 D3).
      #
      # ```
      # partiduo-manage instance status
      # partiduo-manage instance enable skel --task 42 --requested-by admin@cabinet.example
      # partiduo-manage instance read-only on --reason "archivage"
      # ```
      class Instance < Marten::CLI::Manage::Command::Base
        command_name :instance
        help "Interface d'instance pour l'exécutant de partiduo-admin (JSON, doc/api/instance-cli.adoc)."

        ACTIONS = %w[version status migrations migrate enable disable read-only admin-invite backup-plan]

        # Codes d'erreur du contrat et codes de sortie associés.
        EXIT_CODES = {
          "internal"             => 1,
          "usage"                => 2,
          "not_found"            => 3,
          "refused"              => 4,
          "read_only"            => 5,
          "database_unavailable" => 6,
          "migrations_pending"   => 7,
        }

        alias Failure = InstanceAdmin::Failure

        @arguments = [] of String
        @reason : String? = nil
        @approval_ref : String? = nil
        @approvers = [] of String
        @task : String? = nil
        @requested_by : String? = nil
        @list_file : String? = nil
        @locale = "fr"
        @check = false
        @verify = false
        @terminate_sessions = false
        @parse_error : String? = nil

        def setup
          on_unknown_argument(:action, "#{ACTIONS.join(", ")}, puis ses arguments") { |value| @arguments << value }
          on_option_with_arg("reason", "text", "motif (read-only on, admin-invite)") { |value| @reason = value }
          on_option_with_arg("approval-ref", "ref", "référence de la double validation (admin-invite)") do |value|
            @approval_ref = value
          end
          on_option_with_arg("approvers", "list", "les deux personnes qui ont validé, séparées par des virgules") do |value|
            @approvers = value.split(',').map(&.strip).reject(&.empty?)
          end
          on_option_with_arg("task", "id", "identifiant de la tâche de partiduo-admin (journal d'audit)") do |value|
            @task = value
          end
          on_option_with_arg("requested-by", "label", "demandeur de la tâche (journal d'audit)") do |value|
            @requested_by = value
          end
          on_option_with_arg("list-file", "path", "backup-plan : écrit la liste des fichiers à inclure") do |value|
            @list_file = value
          end
          on_option_with_arg("locale", "code", "langue des messages : fr, en ou nl") { |value| @locale = value }
          on_option("check", "migrations : code 7 s'il reste des migrations à appliquer") { @check = true }
          on_option("verify", "backup-plan : vérifie l'empreinte de chaque fichier") { @verify = true }
          on_option("terminate-sessions", "read-only : coupe les sessions ouvertes") { @terminate_sessions = true }
          on_invalid_option { |flag| @parse_error = flag }
        end

        # Une option à laquelle manque sa valeur fait lever l'analyseur
        # avant `run` : l'erreur est rendue au format du contrat, traduite
        # (langue de `--locale` si l'option a déjà été lue, sinon français).
        def handle! : Nil
          super
        rescue ex : OptionParser::Exception
          I18n.with_locale(locale) do
            emit_failure(@arguments.first? || "", Failure.new("usage", "usage.option",
              I18n.t("core.instance_cli.errors.option", option: option_of(ex))))
          end
        end

        private def locale : String
          Partiduo::LOCALES.includes?(@locale) ? @locale : "fr"
        end

        # Option en cause dans le message de l'analyseur (« Missing option:
        # --reason ») ; le message entier à défaut.
        private def option_of(ex : Exception) : String
          message = ex.message.to_s
          message[/-{1,2}[A-Za-z][\w-]*/]? || message
        end

        def run
          action = @arguments.first? || ""
          I18n.with_locale(locale) do
            if flag = @parse_error
              raise usage("usage.option", I18n.t("core.instance_cli.errors.option", option: flag))
            end
            emit_success(action, dispatch(action))
          rescue error : Failure
            emit_failure(action, error)
          rescue ex : ::DB::ConnectionRefused | Socket::Error
            emit_failure(action, Failure.new("database_unavailable", "database.unavailable",
              I18n.t("core.instance_cli.errors.database_unavailable",
                detail: (ex.message.presence || ex.cause.try(&.message).presence || ex.class.name).to_s)))
          rescue ex : PQ::PQError
            if ex.field_message(:code) == "25006"
              emit_failure(action, Failure.new("read_only", "instance.read_only",
                I18n.t("core.instance_cli.errors.read_only")))
            else
              emit_failure(action, Failure.new("internal", "internal.database",
                I18n.t("core.instance_cli.errors.internal", detail: ex.message.to_s)))
            end
          rescue ex : Marten::CLI::Manage::Errors::Exit
            raise ex
          rescue ex
            emit_failure(action, Failure.new("internal", "internal.#{ex.class.name.split("::").last.underscore}",
              I18n.t("core.instance_cli.errors.internal", detail: (ex.message.presence || ex.class.name).to_s)))
          end
        end

        private def dispatch(action : String) : Hash(String, JSON::Any)
          case action
          when "version"      then expect_arguments(1); version
          when "status"       then expect_arguments(1); status
          when "migrations"   then expect_arguments(1); migrations
          when "migrate"      then expect_arguments(1); migrate
          when "enable"       then expect_arguments(2); change_module(@arguments[1], true)
          when "disable"      then expect_arguments(2); change_module(@arguments[1], false)
          when "read-only"    then expect_arguments(2); read_only(@arguments[1])
          when "admin-invite" then expect_arguments(2); admin_invite(@arguments[1])
          when "backup-plan"  then expect_arguments(1); backup_plan
          when ""
            raise usage("usage.action_missing", I18n.t("core.instance_cli.errors.action_missing",
              actions: ACTIONS.join(", ")))
          else
            raise usage("usage.action_unknown", I18n.t("core.instance_cli.errors.action_unknown",
              action: action, actions: ACTIONS.join(", ")))
          end
        end

        # --- Actions ---------------------------------------------------------------

        private def version : Hash(String, JSON::Any)
          object({
            "version"     => Partiduo::VERSION,
            "api_version" => Partiduo::API_VERSION,
            "contract"    => Partiduo::INSTANCE_CLI_VERSION,
            "pieces"      => pieces_json,
          })
        end

        private def status : Hash(String, JSON::Any)
          prepare_database
          settings = settings_row
          pending = InstanceAdmin.pending_migrations
          read_only = InstanceAdmin.read_only?
          object({
            "version"        => Partiduo::VERSION,
            "api_version"    => Partiduo::API_VERSION,
            "contract"       => Partiduo::INSTANCE_CLI_VERSION,
            "database"       => InstanceAdmin.database_name,
            "provisioned"    => !settings.nil?,
            "domain"         => settings.try(&.domain.try(&.presence)) || Partiduo::Config.domain,
            "tax_regime"     => settings.try(&.tax_regime),
            "default_locale" => settings.try(&.default_locale),
            "read_only"      => read_only_json(read_only),
            "migrations"     => object({
              "applied" => InstanceAdmin.applied_migrations_count.to_i64,
              "pending" => pending.size.to_i64,
            }),
            "modules" => modules_json,
          })
        end

        private def migrations : Hash(String, JSON::Any)
          prepare_database
          pending = InstanceAdmin.pending_migrations
          if @check && !pending.empty?
            raise Failure.new("migrations_pending", "migrations.pending",
              I18n.t("core.instance_cli.errors.migrations_pending", count: pending.size))
          end
          object({
            "applied" => InstanceAdmin.applied_migrations_count.to_i64,
            "pending" => JSON::Any.new(pending.map { |ref| migration_json(ref) }),
          })
        end

        private def migrate : Hash(String, JSON::Any)
          prepare_database
          applied = [] of InstanceAdmin::MigrationRef
          begin
            InstanceAdmin.migrate(applied)
          rescue ex
            raise Failure.new("internal", "migrations.failed", I18n.t("core.instance_cli.errors.migration_failed",
              applied: applied.size, detail: ex.message.to_s))
          end
          unless applied.empty?
            audit("instance.migrate", applied.map { |ref| "#{ref.app}.#{ref.name}" }.join(","))
          end
          object({
            "applied" => JSON::Any.new(applied.map { |ref| migration_json(ref) }),
            "pending" => InstanceAdmin.pending_migrations.size.to_i64,
          })
        end

        private def change_module(code : String, enable : Bool) : Hash(String, JSON::Any)
          prepare_database
          require_writable!
          require_migrated!
          actor = Partiduo::Api::Actor.system
          result = begin
            enable ? Partiduo::Api::Modules.activate(actor, code) : Partiduo::Api::Modules.deactivate(actor, code)
          rescue Partiduo::Api::NotFound
            raise Failure.new("not_found", "module.unknown", I18n.t("core.instance_cli.errors.module_unknown", code: code))
          end
          if result.failure?
            first = result.errors.first
            raise Failure.new("refused", first.key, result.errors.map(&.message).join(" "), result.errors)
          end
          piece = result.value!
          audit(enable ? "instance.module.enable" : "instance.module.disable", piece.code)
          object({
            "code"   => piece.code,
            "kind"   => piece.kind,
            "active" => piece.active,
            # ADR-006 D2 : désactiver conserve les données ; rien n'est supprimé.
            "data" => "kept",
          })
        end

        private def read_only(mode : String) : Hash(String, JSON::Any)
          prepare_database
          case mode
          when "status"
            object({"read_only" => read_only_json(InstanceAdmin.read_only?)})
          when "on"
            reason = @reason.try(&.strip).presence ||
                     raise usage("usage.reason_missing", I18n.t("core.instance_cli.errors.reason_missing"))
            was = InstanceAdmin.read_only?
            # Trace inscrite dans la même transaction que le réglage : pas de
            # trace « on » sans effet si l'ALTER DATABASE échoue.
            Marten::DB::Connection.default.transaction do
              InstanceAdmin.set_read_only(true)
              audit(InstanceAdmin::AUDIT_READ_ONLY_ON, reason) unless was
            end
            terminated = @terminate_sessions ? InstanceAdmin.terminate_other_sessions : 0
            object({
              "read_only"           => read_only_json(true),
              "sessions_terminated" => terminated.to_i64,
              "restart_required"    => !@terminate_sessions,
            })
          when "off"
            was = InstanceAdmin.read_only?
            Marten::DB::Connection.default.transaction do
              InstanceAdmin.set_read_only(false)
              audit(InstanceAdmin::AUDIT_READ_ONLY_OFF, @reason.try(&.strip) || "") if was
            end
            terminated = @terminate_sessions ? InstanceAdmin.terminate_other_sessions : 0
            object({
              "read_only"           => read_only_json(false),
              "sessions_terminated" => terminated.to_i64,
              "restart_required"    => !@terminate_sessions,
            })
          else
            raise usage("usage.read_only_mode", I18n.t("core.instance_cli.errors.read_only_mode", mode: mode))
          end
        end

        # Recours d'accès (ADR-008 D3) : nouvelle invitation d'administrateur,
        # après double validation dans partiduo-admin, tracée ici.
        private def admin_invite(email : String) : Hash(String, JSON::Any)
          prepare_database
          require_writable!
          require_migrated!
          reason = @reason.try(&.strip).presence ||
                   raise usage("usage.reason_missing", I18n.t("core.instance_cli.errors.reason_missing"))
          reference = @approval_ref.try(&.strip).presence ||
                      raise usage("usage.approval_missing", I18n.t("core.instance_cli.errors.approval_missing"))
          approvers = @approvers.map(&.downcase).uniq!
          if approvers.size < 2
            raise usage("usage.approvers", I18n.t("core.instance_cli.errors.approvers"))
          end
          settings = settings_row ||
                     raise Failure.new("refused", "instance.not_provisioned", I18n.t("core.instance_cli.errors.not_provisioned"))

          host = instance_host(settings)

          outcome : AdminInvitation::Issued? = nil
          Marten::DB::Connection.default.transaction do
            issued = AdminInvitation.issue(email)
            audit("instance.admin_invitation", {
              "email"        => issued.email,
              "reason"       => reason,
              "approval_ref" => reference,
              "approvers"    => approvers.join(","),
              "created"      => issued.created.to_s,
            })
            outcome = issued
          end
          invitation = outcome || raise Failure.new("internal", "internal.transaction", "transaction interrompue")
          object({
            "email"         => invitation.email,
            "user_created"  => invitation.created,
            "token"         => invitation.token,
            "url"           => "https://#{host}/invitation/#{invitation.token}",
            "expires_at"    => invitation.expires_at.to_utc.to_rfc3339,
            "usable_admins" => invitation.usable_admins.to_i64,
          })
        end

        # Hôte de l'instance, pour le lien d'invitation : celui de la société
        # (`Settings#domain`, posé par `provision --domain <hôte>`), sinon
        # celui de l'environnement du service (`PARTIDUO_HOST`, premier de
        # `MARTEN_ALLOWED_HOSTS`). Jamais le domaine du parc : le lien
        # mènerait ailleurs. Refus (4) si aucun n'est connu.
        private def instance_host(settings : Partiduo::Core::Settings) : String
          candidates = [settings.domain, ENV["PARTIDUO_HOST"]?, ENV["MARTEN_ALLOWED_HOSTS"]?.try(&.split(',').first?)]
          candidates.compact.map(&.strip).find(&.presence) ||
            raise Failure.new("refused", "instance.host_unknown", I18n.t("core.instance_cli.errors.host_unknown"))
        end

        private def backup_plan : Hash(String, JSON::Any)
          prepare_database
          files = InstanceAdmin.backup_files(@verify)
          included = files.select(&.state.==("present"))
          if path = @list_file
            File.write(path, included.join { |file| "#{file.path}\n" })
          end
          object({
            "generated_at" => Partiduo::Config.now.to_utc.to_rfc3339,
            "database"     => InstanceAdmin.database_name,
            "read_only"    => InstanceAdmin.read_only?,
            "media_root"   => InstanceAdmin.media_root,
            "list_file"    => @list_file.try { |value| File.expand_path(value) },
            "verified"     => @verify,
            "file_count"   => included.size.to_i64,
            "total_bytes"  => included.sum(0_i64, &.bytes),
            "files"        => JSON::Any.new(files.map do |file|
              JSON::Any.new(object({"path" => file.path, "bytes" => file.bytes, "sha256" => file.sha256,
                                    "state" => file.state}))
            end),
            "missing" => JSON::Any.new(files.reject(&.state.==("present")).map { |file| JSON::Any.new(file.path) }),
          })
        end

        # --- Garde-fous ------------------------------------------------------------

        # Joint la base et autorise les écritures de ce processus, même sur
        # une base en lecture seule (D-CLI-003) : chaque action vérifie
        # elle-même si elle est permise dans cet état.
        private def prepare_database : Nil
          InstanceAdmin.ping!
          InstanceAdmin.allow_writes_in_this_process!
        end

        private def require_writable! : Nil
          return unless InstanceAdmin.read_only?
          raise Failure.new("read_only", "instance.read_only", I18n.t("core.instance_cli.errors.read_only"))
        end

        private def require_migrated! : Nil
          pending = InstanceAdmin.pending_migrations
          return if pending.empty?
          raise Failure.new("migrations_pending", "migrations.pending",
            I18n.t("core.instance_cli.errors.migrations_pending", count: pending.size))
        end

        private def expect_arguments(count : Int32) : Nil
          return if @arguments.size == count
          if @arguments.size < count
            raise usage("usage.argument_missing", I18n.t("core.instance_cli.errors.argument_missing",
              action: @arguments.first))
          end
          raise usage("usage.argument_extra", I18n.t("core.instance_cli.errors.argument_extra",
            argument: @arguments[count]))
        end

        private def usage(reason : String, message : String) : Failure
          Failure.new("usage", reason, message)
        end

        # --- Lecture ---------------------------------------------------------------

        private def settings_row : Partiduo::Core::Settings?
          return unless InstanceAdmin.table_exists?(Partiduo::Core::Settings.db_table)
          Partiduo::Core::Settings.all.order(:id).first
        end

        private def read_only_json(active : Bool) : JSON::Any
          event = active ? InstanceAdmin.last_read_only_event : nil
          detail = event.try { |value| parse_detail(value.detail.to_s) }
          JSON::Any.new(object({
            "active" => active,
            "since"  => event.try(&.created_at).try(&.to_utc.to_rfc3339),
            "reason" => detail.try(&.["reason"]?).try(&.as_s?),
          }))
        end

        private def parse_detail(text : String) : Hash(String, JSON::Any)?
          JSON.parse(text).as_h?
        rescue JSON::ParseException
          nil
        end

        private def modules_json : JSON::Any
          active = Partiduo::Modules::State.active_codes
          JSON::Any.new(Partiduo::Modules.manifests.values.map do |manifest|
            JSON::Any.new(object({
              "code"       => manifest.code,
              "kind"       => manifest.kind.to_s.downcase,
              "version"    => manifest.version,
              "active"     => Partiduo::Modules.active_in?(manifest.code, active),
              "depends_on" => JSON::Any.new((manifest.depends_on + manifest.depends_on_any.map(&.join("|")))
                .map { |code| JSON::Any.new(code) }),
            }))
          end)
        end

        private def pieces_json : JSON::Any
          JSON::Any.new(Partiduo::Modules.manifests.values.map do |manifest|
            JSON::Any.new(object({"code" => manifest.code, "kind" => manifest.kind.to_s.downcase,
                                  "version" => manifest.version}))
          end)
        end

        private def migration_json(ref : InstanceAdmin::MigrationRef) : JSON::Any
          JSON::Any.new(object({"app" => ref.app, "name" => ref.name}))
        end

        # --- Journal d'audit de l'instance -----------------------------------------

        # Inscrit l'action au journal d'audit de l'instance, au nom de
        # `partiduo-admin` (ADR-008 D3), avec la tâche et le demandeur.
        private def audit(action : String, detail : String | Hash(String, String)) : Nil
          fields = detail.is_a?(String) ? {"reason" => detail} : detail.dup
          @task.try { |value| fields["task"] = value }
          @requested_by.try { |value| fields["requested_by"] = value }
          Partiduo::Auth::Audit.record(action, "ADMIN", label: "partiduo-admin", module_code: "CORE",
            detail: fields.to_json)
        end

        # --- Sortie ----------------------------------------------------------------

        private def object(fields : Hash(String, _)) : Hash(String, JSON::Any)
          fields.transform_values { |value| to_any(value) }
        end

        private def to_any(value) : JSON::Any
          case value
          when JSON::Any                         then value
          when Hash(String, JSON::Any)           then JSON::Any.new(value)
          when Int32                             then JSON::Any.new(value.to_i64)
          when Int64, String, Bool, Float64, Nil then JSON::Any.new(value)
          else                                        raise ArgumentError.new("valeur JSON non prévue : #{value.class}")
          end
        end

        private def emit_success(action : String, data) : Nil
          print({"contract" => Partiduo::INSTANCE_CLI_VERSION, "action" => action, "ok" => true,
                 "data" => to_any(data)}.to_json)
        end

        private def emit_failure(action : String, failure : Failure) : Nil
          error = {
            "code"    => JSON::Any.new(failure.code),
            "reason"  => JSON::Any.new(failure.reason),
            "message" => JSON::Any.new(failure.message.to_s),
            "details" => JSON::Any.new(failure.details.map do |detail|
              JSON::Any.new({"field" => JSON::Any.new(detail.field), "key" => JSON::Any.new(detail.key),
                             "message" => JSON::Any.new(detail.message)})
            end),
          }
          print({"contract" => Partiduo::INSTANCE_CLI_VERSION, "action" => action, "ok" => false,
                 "error" => error}.to_json)
          do_exit(EXIT_CODES[failure.code])
        end
      end
    end
  end
end
