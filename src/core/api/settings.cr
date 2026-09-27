# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    # Contrat du socle — configuration société (`Settings`, ligne unique) et
    # provisionnement d'une instance (ADR-001 D2, ADR-002 D1).
    module Core
      # Régimes fiscaux : le jeu de données initial (plan comptable, taux) suit
      # le régime (ADR-001 § Organisation du code).
      TAX_REGIMES = Partiduo::Core::SettingsRules::TAX_REGIMES
      # Méthodes d'authentification qu'une instance peut autoriser (ADR-002 D1).
      AUTH_METHODS = Partiduo::Core::SettingsRules::AUTH_METHODS
      # Niveaux d'authentification (ADR-002 D2).
      AUTH_LEVELS = Partiduo::Core::SettingsRules::AUTH_LEVELS
      # Durée de session admise, en minutes.
      SESSION_MINUTES = Partiduo::Core::SettingsRules::SESSION_MINUTES

      # Saisie de la configuration société.
      #
      # Sémantique : la saisie *décrit la ligne entière*. Un champ texte `nil`
      # vaut chaîne vide ; `share_capital` `nil` efface le capital. Les champs
      # qui ont une valeur par défaut (`country_code`, `default_locale`,
      # `domain`, `auth_*`, `session_duration_minutes`) gardent, s'ils valent
      # `nil`, la valeur enregistrée — ou prennent la valeur par défaut à la
      # création. `tax_regime` est obligatoire à la création et ne change plus
      # ensuite.
      record SettingsInput,
        company_name : String? = nil,
        legal_form : String? = nil,
        share_capital : BigDecimal? = nil,
        rcs : String? = nil,
        siren : String? = nil,
        vat_number : String? = nil,
        street : String? = nil,
        street_number : String? = nil,
        postcode : String? = nil,
        city : String? = nil,
        country_code : String? = nil,
        phone : String? = nil,
        email : String? = nil,
        tax_regime : String? = nil,
        default_locale : String? = nil,
        domain : String? = nil,
        auth_methods : Array(String)? = nil,
        auth_minimum_level : Int32? = nil,
        session_duration_minutes : Int32? = nil

      # Configuration société, vue de l'interface et des extensions.
      record SettingsView,
        company_name : String,
        legal_form : String,
        share_capital : BigDecimal?,
        rcs : String,
        siren : String,
        vat_number : String,
        street : String,
        street_number : String,
        postcode : String,
        city : String,
        country_code : String,
        phone : String,
        email : String,
        tax_regime : String,
        default_locale : String,
        domain : String,
        auth_methods : Array(String),
        auth_minimum_level : Int32,
        session_duration_minutes : Int32,
        updated_at : Time? do
        # Clé i18n du régime fiscal (`core.settings.tax_regimes.fr`).
        def tax_regime_key : String
          "core.settings.tax_regimes.#{tax_regime}"
        end

        def auth_method_allowed?(method : String) : Bool
          auth_methods.includes?(method)
        end

        # Saisie qui reproduit la ligne : point de départ d'une modification.
        def to_input : SettingsInput
          SettingsInput.new(
            company_name: company_name, legal_form: legal_form, share_capital: share_capital, rcs: rcs,
            siren: siren, vat_number: vat_number, street: street, street_number: street_number,
            postcode: postcode, city: city, country_code: country_code, phone: phone, email: email,
            tax_regime: tax_regime, default_locale: default_locale, domain: domain,
            auth_methods: auth_methods, auth_minimum_level: auth_minimum_level,
            session_duration_minutes: session_duration_minutes,
          )
        end

        def self.from(settings : Partiduo::Core::Settings) : SettingsView
          new(
            company_name: settings.company_name.to_s,
            legal_form: settings.legal_form.to_s,
            share_capital: settings.share_capital,
            rcs: settings.rcs.to_s,
            siren: settings.siren.to_s,
            vat_number: settings.vat_number.to_s,
            street: settings.street.to_s,
            street_number: settings.street_number.to_s,
            postcode: settings.postcode.to_s,
            city: settings.city.to_s,
            country_code: settings.country_code.to_s,
            phone: settings.phone.to_s,
            email: settings.email.to_s,
            tax_regime: settings.tax_regime.to_s,
            default_locale: settings.default_locale.to_s,
            domain: settings.domain.to_s,
            auth_methods: settings.auth_method_list,
            auth_minimum_level: (settings.auth_minimum_level || Partiduo::Core::SettingsRules::DEFAULT_AUTH_LEVEL).to_i32,
            session_duration_minutes: (settings.session_duration_minutes ||
                                       Partiduo::Core::SettingsRules::DEFAULT_SESSION_MINUTES).to_i32,
            updated_at: settings.updated_at,
          )
        end
      end

      # Création d'une instance : configuration société, modules et extensions
      # à activer (déjà actifs dans `PARTIDUO_MODULES`, que pose
      # `bin/partiduo-provision`), adresse de l'administrateur à inviter.
      record ProvisionInput,
        settings : SettingsInput,
        modules : Array(String) = [] of String,
        extensions : Array(String) = [] of String,
        admin_email : String? = nil

      # Résultat du provisionnement : la configuration créée, les pièces
      # actives, les chargeurs de données initiales exécutés et les
      # invitations émises (administrateur), que l'opérateur transmet.
      record ProvisionView,
        settings : SettingsView,
        active_modules : Array(String),
        loaders : Array(String),
        invitations : Array(InitialData::Invitation) = [] of InitialData::Invitation

      # L'instance a-t-elle sa configuration société ? Tout utilisateur
      # authentifié peut le demander.
      def self.provisioned?(actor : Actor) : Bool
        Guard.authorize!(actor, nil)
        !Partiduo::Core::SettingsRules.current.nil?
      end

      # Configuration société. Tout utilisateur authentifié la lit (en-tête,
      # mentions des documents). `NotFound` si l'instance n'est pas provisionnée.
      def self.settings(actor : Actor) : SettingsView
        Guard.authorize!(actor, nil)
        settings = Partiduo::Core::SettingsRules.current || raise NotFound.new("settings")
        SettingsView.from(settings)
      end

      # Requête de contrôle : la même règle que `update_settings`, sans rien
      # enregistrer (retour instantané de l'interface).
      def self.check_settings(actor : Actor, input : SettingsInput) : Result(Nil)
        Guard.authorize!(actor, "core.settings.manage")
        current = Partiduo::Core::SettingsRules.current
        values = Partiduo::Core::SettingsRules.normalize(input, current)
        errors = Partiduo::Core::SettingsRules.validate(values, current)
        errors.empty? ? Result(Nil).success(nil) : Result(Nil).failure(errors)
      end

      # Modifie la configuration société d'une instance provisionnée.
      def self.update_settings(actor : Actor, input : SettingsInput) : Result(SettingsView)
        Guard.authorize!(actor, "core.settings.manage")

        Transaction.run do
          current = Partiduo::Core::Settings.all.order(:id).lock.first || raise NotFound.new("settings")
          values = Partiduo::Core::SettingsRules.normalize(input, current)
          errors = Partiduo::Core::SettingsRules.validate(values, current)
          if errors.empty?
            Partiduo::Core::SettingsRules.assign(current, values).save!
            Result(SettingsView).success(SettingsView.from(current))
          else
            Result(SettingsView).failure(errors)
          end
        end
      end

      # Provisionne une instance vierge : crée la configuration société puis
      # exécute les chargeurs de données initiales des pièces actives
      # (`Partiduo::Api::InitialData`), dans une seule transaction.
      #
      # Réservé à l'acteur système (`bin/partiduo-provision`) : aucun
      # utilisateur n'existe encore. Une instance déjà provisionnée est refusée.
      def self.provision(actor : Actor, input : ProvisionInput) : Result(ProvisionView)
        raise Forbidden.new("core.settings.manage") unless actor.system
        Guard.authorize!(actor, "core.settings.manage")

        Transaction.run do
          errors = [] of FieldError
          unless Partiduo::Core::SettingsRules.current.nil?
            errors << FieldError.base("core.errors.provision.already_provisioned")
          end
          values = Partiduo::Core::SettingsRules.normalize(input.settings)
          errors.concat(Partiduo::Core::SettingsRules.validate(values))
          errors.concat(provision_module_errors(input))
          if (email = input.admin_email.try(&.strip)) && !email.empty? &&
             !email.matches?(Partiduo::Core::SettingsRules::EMAIL_FORMAT)
            errors << FieldError.new("admin_email", "core.errors.provision.admin_email.invalid")
          end
          next Result(ProvisionView).failure(errors) unless errors.empty?

          settings = Partiduo::Core::SettingsRules.assign(Partiduo::Core::Settings.new, values)
          settings.save!

          active = Partiduo::Modules.active_manifests.reject(&.socle?).map(&.code).sort!
          context = InitialData::Context.new(
            actor: actor,
            tax_regime: values.tax_regime,
            country_code: values.country_code,
            locale: values.default_locale,
            admin_email: input.admin_email.try(&.strip.downcase).presence,
            module_codes: active,
          )
          loaders = InitialData.run(context)
          Result(ProvisionView).success(
            ProvisionView.new(SettingsView.from(settings), active, loaders, context.invitations)
          )
        end
      end

      private def self.provision_module_errors(input : ProvisionInput) : Array(FieldError)
        errors = [] of FieldError
        {
          {"modules", input.modules, Partiduo::Modules::Kind::Module},
          {"extensions", input.extensions, Partiduo::Modules::Kind::Extension},
        }.each do |field, codes, kind|
          codes.map(&.strip.upcase).reject(&.empty?).each do |code|
            manifest = Partiduo::Modules[code]?
            params = {"code" => code}
            if manifest.nil?
              errors << FieldError.new(field, "core.errors.provision.#{field}.unknown", params)
            elsif manifest.kind != kind
              errors << FieldError.new(field, "core.errors.provision.#{field}.wrong_kind", params)
            elsif !Partiduo::Modules.active?(code)
              errors << FieldError.new(field, "core.errors.provision.#{field}.inactive", params)
            end
          end
        end
        errors
      end
    end
  end
end
