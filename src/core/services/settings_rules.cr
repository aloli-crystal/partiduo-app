# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Core
    # Règles de la configuration société (`Settings`) : normalisation de la
    # saisie, validation, enregistrement. Appelées par `Partiduo::Api::Core`
    # (`check_settings`, `update_settings`, `provision`) : la même règle sert au
    # contrôle instantané et à l'enregistrement.
    #
    # Reprend et durcit `Noalyss_Parameter_Folder` (`include/class/
    # noalyss_parameter_folder.class.php`), qui n'imposait aucun contrôle sur
    # l'identité de la société.
    module SettingsRules
      TAX_REGIMES  = %w[fr be]
      AUTH_METHODS = %w[password passkey federated]

      # Niveau maximal que chaque méthode permet d'atteindre (ADR-002 D2) :
      # mot de passe + TOTP = 2 ; passkey = 3 ; identité fédérée = 3 (le
      # fournisseur d'identité est tenu d'exiger le MFA, ADR-002 D3–D4).
      METHOD_LEVEL = {"password" => 2, "passkey" => 3, "federated" => 3}

      AUTH_LEVELS             = 1..3
      SESSION_MINUTES         = 5..1440
      DEFAULT_SESSION_MINUTES = 480
      DEFAULT_AUTH_METHODS    = %w[password passkey]
      DEFAULT_AUTH_LEVEL      = 1
      DEFAULT_LOCALE          = "fr"

      # Pays admis par régime fiscal. Monaco relève de la TVA française.
      REGIME_COUNTRIES = {"fr" => %w[FR MC], "be" => %w[BE]}

      # Nombre maximal de décimales du capital social (montant en devise).
      CAPITAL_DECIMALS = 2

      # Tailles maximales, alignées sur les colonnes du modèle.
      MAX_SIZES = {
        "company_name"  => 255,
        "legal_form"    => 64,
        "rcs"           => 128,
        "street"        => 255,
        "street_number" => 32,
        "postcode"      => 16,
        "city"          => 128,
        "phone"         => 32,
        "email"         => 254,
        "domain"        => 253,
      }

      EMAIL_FORMAT   = /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/
      DOMAIN_LABEL   = /\A[a-z0-9](?:[a-z0-9\-]{0,61}[a-z0-9])?\z/
      COUNTRY_FORMAT = /\A[A-Z]{2}\z/
      GENERIC_VAT    = /\A[A-Z]{2}[0-9A-Z]{2,13}\z/

      # Valeurs normalisées, prêtes à valider puis à enregistrer.
      record Values,
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
        session_duration_minutes : Int32

      # Normalise la saisie. Un champ texte `nil` vaut chaîne vide ; un champ
      # qui a une valeur par défaut (pays, langue, politique d'authentification)
      # prend, s'il vaut `nil`, la valeur enregistrée (`current`) ou, à la
      # création, la valeur par défaut. Le régime fiscal `nil` garde la valeur
      # enregistrée.
      def self.normalize(input : Partiduo::Api::Core::SettingsInput, current : Settings? = nil) : Values
        regime = input.tax_regime.try(&.strip.downcase) || current.try(&.tax_regime) || ""

        Values.new(
          company_name: text(input.company_name),
          legal_form: text(input.legal_form),
          share_capital: input.share_capital,
          rcs: text(input.rcs),
          siren: text(input.siren).gsub(/[\s.]/, ""),
          vat_number: Identifiers.compact(text(input.vat_number)),
          street: text(input.street),
          street_number: text(input.street_number),
          postcode: text(input.postcode).upcase,
          city: text(input.city),
          country_code: input.country_code.try(&.strip.upcase) || current.try(&.country_code) || default_country(regime),
          phone: text(input.phone),
          email: text(input.email).downcase,
          tax_regime: regime,
          default_locale: input.default_locale.try(&.strip.downcase) || current.try(&.default_locale) || DEFAULT_LOCALE,
          domain: input.domain.try(&.strip.downcase.rchop('.')) || current.try(&.domain) || "",
          auth_methods: normalize_auth_methods(input, current),
          auth_minimum_level: integer(input.auth_minimum_level, current.try(&.auth_minimum_level), DEFAULT_AUTH_LEVEL),
          session_duration_minutes: integer(input.session_duration_minutes, current.try(&.session_duration_minutes),
            DEFAULT_SESSION_MINUTES),
        )
      end

      # Erreurs de validation, par champ. `current` : la ligne enregistrée
      # (mise à jour), `nil` à la création.
      def self.validate(values : Values, current : Settings? = nil) : Array(Partiduo::Api::FieldError)
        errors = [] of Partiduo::Api::FieldError

        errors << error("company_name", "blank") if values.company_name.empty?
        MAX_SIZES.each do |field, max|
          value = field_value(values, field)
          errors << error(field, "too_long", {"max" => max.to_s}) if value.size > max
        end

        validate_regime(values, current, errors)
        validate_identifiers(values, errors)
        validate_capital(values, errors)

        unless values.email.empty? || values.email.matches?(EMAIL_FORMAT)
          errors << error("email", "invalid")
        end
        unless Partiduo::LOCALES.includes?(values.default_locale)
          errors << error("default_locale", "invalid", {"value" => values.default_locale})
        end
        if values.domain.empty?
          errors << error("domain", "blank")
        elsif !valid_domain?(values.domain)
          errors << error("domain", "invalid", {"value" => values.domain})
        end

        validate_auth_policy(values, errors)
        errors
      end

      # Copie les valeurs dans la ligne (sans l'enregistrer).
      def self.assign(settings : Settings, values : Values) : Settings
        settings.company_name = values.company_name
        settings.legal_form = values.legal_form
        settings.share_capital = values.share_capital
        settings.rcs = values.rcs
        settings.siren = values.siren
        settings.vat_number = values.vat_number
        settings.street = values.street
        settings.street_number = values.street_number
        settings.postcode = values.postcode
        settings.city = values.city
        settings.country_code = values.country_code
        settings.phone = values.phone
        settings.email = values.email
        settings.tax_regime = values.tax_regime
        settings.default_locale = values.default_locale
        settings.domain = values.domain
        settings.auth_methods = values.auth_methods.join(',')
        settings.auth_minimum_level = values.auth_minimum_level
        settings.session_duration_minutes = values.session_duration_minutes
        settings
      end

      # La ligne unique, ou `nil` si l'instance n'est pas encore provisionnée.
      def self.current : Settings?
        Settings.all.order(:id).first
      end

      def self.default_country(regime : String) : String
        REGIME_COUNTRIES[regime]?.try(&.first) || ""
      end

      def self.valid_domain?(domain : String) : Bool
        labels = domain.split('.')
        domain.size <= 253 && labels.size >= 2 && labels.all?(&.matches?(DOMAIN_LABEL))
      end

      # Préfixe TVA attendu pour un pays (la Grèce utilise `EL`, Monaco la TVA
      # française).
      def self.vat_prefix(country : String) : String
        case country
        when "GR" then "EL"
        when "MC" then "FR"
        else           country
        end
      end

      private def self.validate_regime(values : Values, current : Settings?, errors) : Nil
        if values.tax_regime.empty?
          errors << error("tax_regime", "blank")
        elsif !TAX_REGIMES.includes?(values.tax_regime)
          errors << error("tax_regime", "invalid", {"value" => values.tax_regime})
        elsif current && current.tax_regime != values.tax_regime
          # Le régime a déterminé le jeu de données initial (plan comptable,
          # taux) : il ne change pas après le provisionnement.
          errors << error("tax_regime", "immutable")
        end

        if !values.country_code.matches?(COUNTRY_FORMAT)
          errors << error("country_code", "invalid", {"value" => values.country_code})
        elsif (countries = REGIME_COUNTRIES[values.tax_regime]?) && !countries.includes?(values.country_code)
          errors << error("country_code", "regime_mismatch",
            {"country" => values.country_code, "regime" => values.tax_regime.upcase})
        end
      end

      private def self.validate_identifiers(values : Values, errors) : Nil
        unless values.siren.empty?
          if values.tax_regime == "be"
            errors << error("siren", "not_applicable")
          elsif !Identifiers.valid_siren?(values.siren)
            errors << error("siren", "invalid", {"value" => values.siren})
          end
        end
        validate_vat_number(values, errors) unless values.vat_number.empty?
      end

      private def self.validate_vat_number(values : Values, errors) : Nil
        vat = values.vat_number
        prefix = vat_prefix(values.country_code)

        if !valid_vat_number?(vat)
          errors << error("vat_number", "invalid", {"value" => vat})
        elsif values.country_code.matches?(COUNTRY_FORMAT) && !vat.starts_with?(prefix)
          errors << error("vat_number", "country_mismatch", {"prefix" => prefix})
        elsif vat.starts_with?("FR") && Identifiers.valid_siren?(values.siren) &&
              Partiduo::Vat::Fr::VatNumber.siren(vat) != values.siren
          errors << error("vat_number", "siren_mismatch", {"siren" => values.siren})
        end
      end

      # Contrôle national (FR, BE), sinon forme générique d'un numéro de l'UE.
      def self.valid_vat_number?(vat : String) : Bool
        case vat[0, 2]?
        when "FR" then Partiduo::Vat::Fr::VatNumber.valid?(vat)
        when "BE" then Partiduo::Vat::Be::VatNumber.valid?(vat)
        else           vat.matches?(GENERIC_VAT)
        end
      end

      private def self.validate_capital(values : Values, errors) : Nil
        capital = values.share_capital
        return if capital.nil?

        if capital < 0
          errors << error("share_capital", "negative")
        elsif capital.round(CAPITAL_DECIMALS) != capital
          errors << error("share_capital", "too_precise", {"decimals" => CAPITAL_DECIMALS.to_s})
        elsif capital >= BigDecimal.new(10) ** 16
          errors << error("share_capital", "too_large")
        end
      end

      private def self.validate_auth_policy(values : Values, errors) : Nil
        methods = values.auth_methods
        unknown = methods.reject { |method| AUTH_METHODS.includes?(method) }
        if methods.empty?
          errors << error("auth_methods", "blank")
        elsif !unknown.empty?
          errors << error("auth_methods", "unknown", {"methods" => unknown.join(", ")})
        end

        level = values.auth_minimum_level
        if !AUTH_LEVELS.includes?(level)
          errors << error("auth_minimum_level", "out_of_range",
            {"min" => AUTH_LEVELS.begin.to_s, "max" => AUTH_LEVELS.end.to_s})
        elsif unknown.empty? && !methods.empty? && methods.max_of { |method| METHOD_LEVEL[method] } < level
          errors << error("auth_minimum_level", "unreachable", {"level" => level.to_s})
        end

        unless SESSION_MINUTES.includes?(values.session_duration_minutes)
          errors << error("session_duration_minutes", "out_of_range",
            {"min" => SESSION_MINUTES.begin.to_s, "max" => SESSION_MINUTES.end.to_s})
        end
      end

      private def self.normalize_methods(list : Array(String)) : Array(String)
        wanted = list.flat_map(&.split(',')).map(&.strip.downcase).reject(&.empty?).uniq!
        # Ordre canonique pour les méthodes connues, puis les inconnues (refusées).
        AUTH_METHODS.select { |method| wanted.includes?(method) } + (wanted - AUTH_METHODS)
      end

      private def self.normalize_auth_methods(input, current : Settings?) : Array(String)
        if list = input.auth_methods
          normalize_methods(list)
        else
          current.try(&.auth_method_list) || DEFAULT_AUTH_METHODS.dup
        end
      end

      private def self.integer(value : Int?, stored : Int?, default : Int32) : Int32
        (value || stored || default).to_i32
      end

      private def self.text(value : String?) : String
        value.try(&.strip) || ""
      end

      private def self.field_value(values : Values, field : String) : String
        case field
        when "company_name"  then values.company_name
        when "legal_form"    then values.legal_form
        when "rcs"           then values.rcs
        when "street"        then values.street
        when "street_number" then values.street_number
        when "postcode"      then values.postcode
        when "city"          then values.city
        when "phone"         then values.phone
        when "email"         then values.email
        when "domain"        then values.domain
        else                      raise ArgumentError.new("champ inconnu : #{field}")
        end
      end

      private def self.error(field : String, code : String, params = {} of String => String) : Partiduo::Api::FieldError
        Partiduo::Api::FieldError.new(field, "core.errors.settings.#{field}.#{code}", params)
      end
    end
  end
end
