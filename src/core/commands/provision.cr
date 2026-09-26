# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Core
    module Commands
      # `manage provision` : dernière étape de `bin/partiduo-provision`, une
      # fois la base créée et migrée. Crée la configuration société et charge
      # le jeu de données initial par `Partiduo::Api::Core.provision`, avec
      # l'acteur système.
      #
      # ```
      # PARTIDUO_MODULES=accounting,invoicing crystal run manage.cr -- provision \
      #   --name="Exemple SARL" --regime=fr --domain=exemple.partiduo.localhost \
      #   --modules=accounting,invoicing
      # ```
      class Provision < Marten::CLI::Manage::Command::Base
        command_name :provision
        help "Provisionne une instance vierge : société, modules, jeu de données initial."

        getter settings = {} of String => String
        getter modules = [] of String
        getter extensions = [] of String
        getter admin_email : String? = nil

        TEXT_OPTIONS = {
          "name"          => "raison sociale",
          "regime"        => "régime fiscal : fr ou be",
          "country"       => "pays (ISO 3166-1 alpha-2), défaut selon le régime",
          "locale"        => "langue par défaut : fr, en ou nl",
          "domain"        => "nom d'hôte de l'instance (<dossier>.<domaine>)",
          "vat"           => "numéro de TVA intracommunautaire",
          "siren"         => "SIREN (régime fr)",
          "legal-form"    => "forme juridique",
          "capital"       => "capital social (décimal, point comme séparateur)",
          "rcs"           => "immatriculation (RCS, RPM)",
          "street"        => "rue",
          "street-number" => "numéro",
          "postcode"      => "code postal",
          "city"          => "localité",
          "phone"         => "téléphone",
          "email"         => "adresse électronique de la société",
          "auth-methods"  => "méthodes d'authentification autorisées (password,passkey,federated)",
          "auth-level"    => "niveau d'authentification minimum (1 à 3)",
          "session"       => "durée de session, en minutes",
        }

        def setup
          TEXT_OPTIONS.each do |flag, description|
            on_option_with_arg(flag, "value", description) { |value| @settings[flag] = value }
          end
          on_option_with_arg("modules", "codes", "modules activés (accounting,invoicing,analytic)") do |value|
            @modules = split(value)
          end
          on_option_with_arg("with", "codes", "extensions activées") { |value| @extensions = split(value) }
          on_option_with_arg("admin-email", "email", "adresse de l'administrateur à inviter") do |value|
            @admin_email = value
          end
        end

        def run
          input = build_input
          if input.nil?
            return print_error_and_exit(I18n.t("core.provision.invalid_number"))
          end

          result = Partiduo::Api::Core.provision(Partiduo::Api::Actor.system, input)
          locale = result.value?.try(&.settings.default_locale) || @settings["locale"]? || "fr"
          locale = "fr" unless Partiduo::LOCALES.includes?(locale)

          I18n.with_locale(locale) do
            if result.success?
              report(result.value!)
            else
              result.errors.each { |error| @stderr.puts("#{error.field} : #{error.message}") }
              print_error_and_exit(I18n.t("core.provision.failed", count: result.errors.size))
            end
          end
        end

        # Saisie construite à partir des options ; `nil` si une valeur
        # numérique est illisible.
        def build_input : Partiduo::Api::Core::ProvisionInput?
          capital = @settings["capital"]?.try { |value| BigDecimal.new(value.strip) }
          level = @settings["auth-level"]?.try(&.strip.to_i)
          session = @settings["session"]?.try(&.strip.to_i)

          settings = Partiduo::Api::Core::SettingsInput.new(
            company_name: @settings["name"]?,
            legal_form: @settings["legal-form"]?,
            share_capital: capital,
            rcs: @settings["rcs"]?,
            siren: @settings["siren"]?,
            vat_number: @settings["vat"]?,
            street: @settings["street"]?,
            street_number: @settings["street-number"]?,
            postcode: @settings["postcode"]?,
            city: @settings["city"]?,
            country_code: @settings["country"]?,
            phone: @settings["phone"]?,
            email: @settings["email"]?,
            tax_regime: @settings["regime"]?,
            default_locale: @settings["locale"]?,
            domain: @settings["domain"]?,
            auth_methods: @settings["auth-methods"]?.try { |value| split(value) },
            auth_minimum_level: level,
            session_duration_minutes: session,
          )
          Partiduo::Api::Core::ProvisionInput.new(
            settings: settings, modules: @modules, extensions: @extensions, admin_email: @admin_email,
          )
        rescue InvalidBigDecimalException | ArgumentError
          nil
        end

        private def report(view : Partiduo::Api::Core::ProvisionView) : Nil
          settings = view.settings
          print(I18n.t("core.provision.done", name: settings.company_name, domain: settings.domain))
          print(I18n.t("core.provision.regime", regime: I18n.t(settings.tax_regime_key)))
          print(I18n.t("core.provision.modules", count: view.active_modules.size,
            codes: view.active_modules.join(", ")))
          print(I18n.t("core.provision.loaders", count: view.loaders.size, names: view.loaders.join(", ")))
        end

        private def split(value : String) : Array(String)
          value.split(',').map(&.strip).reject(&.empty?)
        end
      end
    end
  end
end
