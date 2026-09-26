# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Auth
    # Politique d'authentification de l'instance (ADR-002 D1) : méthodes
    # autorisées, niveau minimum exigé, durée de session. Elle est portée par
    # `Core::Settings` (héritière de `parameter`), écrite par l'application
    # `core` ; ce module ne fait que la lire, avec des valeurs par défaut tant
    # que la société n'est pas configurée (voir DECISIONS, interface auth/core).
    record Policy,
      methods : Array(String),
      minimum_level : Int32,
      session_minutes : Int32 do
      METHODS = %w[password passkey federated]

      def self.default : Policy
        new(METHODS.dup, 1, Config::DEFAULT_SESSION_MINUTES)
      end

      # Méthode autorisée sur l'instance ? Liste vide : toutes.
      def allows?(method : String) : Bool
        methods.empty? || methods.includes?(method)
      end

      def self.current : Policy
        {% if Partiduo.has_constant?("Core") && Partiduo::Core.has_constant?("Settings") %}
          return default unless settings_table?
          if settings = Partiduo::Core::Settings.all.order(:id).first
            methods = settings.auth_methods.to_s.split(',').map(&.strip.downcase).reject(&.empty?)
            return new(
              methods: methods.empty? ? METHODS.dup : methods,
              minimum_level: (settings.auth_minimum_level || 1).to_i32.clamp(1, 3),
              session_minutes: (settings.session_duration_minutes || Config::DEFAULT_SESSION_MINUTES).to_i32.clamp(5, 7 * 24 * 60),
            )
          end
        {% end %}
        default
      end

      @@settings_table = false

      private def self.settings_table? : Bool
        return true if @@settings_table
        @@settings_table = Marten::DB::Connection.default.open do |db|
          !db.scalar("SELECT to_regclass('core_settings')::text").nil?
        end
      end
    end
  end
end
