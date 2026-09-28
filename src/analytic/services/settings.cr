# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Analytic
    # Paramètres de l'Analytique (`MY_ANALYTIC`, `MY_ANC_FILTER` de
    # paramètres du dossier d'origine). Service interne.
    module Settings
      alias FieldError = Partiduo::Api::FieldError

      DEFAULT_FILTER = "6,7"

      # Ligne unique (`singleton`), créée par la migration 0002 ; recréée
      # sans doublon possible (`ON CONFLICT`) si elle a disparu, par exemple
      # d'une base de test vidée (D-ANA-017).
      def self.current : Setting
        Setting.all.first || begin
          Marten::DB::Connection.default.open do |db|
            db.exec("INSERT INTO analytic_setting (mandatory, account_filter, singleton, created_at, updated_at) " \
                    "VALUES (false, $1, true, now(), now()) ON CONFLICT (singleton) DO NOTHING", DEFAULT_FILTER)
          end
          Setting.all.first || raise "analytic_setting : ligne de paramètres introuvable"
        end
      end

      def self.view(setting : Setting = current) : Partiduo::Api::Analytic::SettingsView
        filter = setting.account_filter.to_s
        Partiduo::Api::Analytic::SettingsView.new(setting.mandatory || false, filter, prefixes(filter))
      end

      # Préfixes non vides, sans espaces (`explode(",", …)`).
      def self.prefixes(filter : String) : Array(String)
        filter.split(',').map(&.strip).reject(&.empty?).uniq!
      end

      # `check_anc_filter` : chiffres et virgules seulement ; des espaces
      # autour d'un préfixe sont tolérés, pas au milieu (« 6 0 » ne
      # désignerait aucun compte).
      def self.errors(input : Partiduo::Api::Analytic::SettingsInput) : Array(FieldError)
        errors = [] of FieldError
        unless prefixes(input.account_filter).all?(&.matches?(/\A[0-9]+\z/))
          errors << FieldError.new("account_filter", "analytic.errors.settings.filter_invalid")
        end
        errors
      end

      def self.normalized_filter(filter : String) : String
        prefixes(filter).join(',')
      end
    end
  end
end
