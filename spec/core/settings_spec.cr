# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private def admin : Partiduo::Api::Actor
  actor_with("core.settings.manage")
end

describe "Partiduo::Api::Core — configuration société" do
  describe ".provision" do
    it "crée la ligne unique avec les valeurs normalisées et les défauts" do
      view = provision_instance

      settings = view.settings
      settings.company_name.should eq("Exemple SARL")
      settings.siren.should eq("732829320")
      settings.vat_number.should eq("FR44732829320")
      settings.share_capital.should eq(BigDecimal.new("10000"))
      settings.country_code.should eq("FR")
      settings.default_locale.should eq("fr")
      settings.auth_methods.should eq(%w[password passkey])
      settings.auth_minimum_level.should eq(1)
      settings.session_duration_minutes.should eq(480)
      settings.tax_regime_key.should eq("core.settings.tax_regimes.fr")

      Partiduo::Api::Core.settings(actor_with).should eq(settings)
      Partiduo::Api::Core.provisioned?(actor_with).should be_true
    end

    it "déduit le pays du régime belge" do
      input = settings_input(tax_regime: "be", siren: nil, rcs: "RPM Bruxelles", vat_number: "BE 0403.170.701")
      view = provision_instance(input)
      view.settings.country_code.should eq("BE")
      view.settings.vat_number.should eq("BE0403170701")
    end

    it "refuse une instance déjà provisionnée" do
      provision_instance
      result = Partiduo::Api::Core.provision(Partiduo::Api::Actor.system,
        Partiduo::Api::Core::ProvisionInput.new(settings: settings_input))
      result.error_keys.should eq(["core.errors.provision.already_provisioned"])
      Partiduo::Core::Settings.all.count.should eq(1)
    end

    it "est réservé à l'acteur système" do
      expect_raises(Partiduo::Api::Forbidden) do
        Partiduo::Api::Core.provision(admin, Partiduo::Api::Core::ProvisionInput.new(settings: settings_input))
      end
    end

    it "vérifie les modules et extensions demandés" do
      with_active_modules("invoicing") do
        input = Partiduo::Api::Core::ProvisionInput.new(
          settings: settings_input,
          modules: %w[invoicing accounting nope vat],
          extensions: %w[invoicing],
        )
        result = Partiduo::Api::Core.provision(Partiduo::Api::Actor.system, input)
        result.error_keys.should eq([
          "core.errors.provision.modules.inactive",
          "core.errors.provision.modules.unknown",
          "core.errors.provision.modules.wrong_kind",
          "core.errors.provision.extensions.wrong_kind",
        ])
        result.errors.first.params.should eq({"code" => "ACCOUNTING"})
      end
    end

    it "refuse une adresse d'administrateur invalide" do
      result = Partiduo::Api::Core.provision(Partiduo::Api::Actor.system,
        Partiduo::Api::Core::ProvisionInput.new(settings: settings_input, admin_email: "pas une adresse"))
      result.errors_for("admin_email").map(&.key).should eq(["core.errors.provision.admin_email.invalid"])
    end

    it "liste les modules actifs du dossier" do
      with_active_modules("invoicing") do
        provision_instance.active_modules.should eq(["INVOICING"])
      end
    end
  end

  describe ".settings" do
    it "lève NotFound tant que l'instance n'est pas provisionnée" do
      Partiduo::Api::Core.provisioned?(actor_with).should be_false
      expect_raises(Partiduo::Api::NotFound) { Partiduo::Api::Core.settings(actor_with) }
    end

    it "refuse un acteur anonyme" do
      expect_raises(Partiduo::Api::Forbidden) { Partiduo::Api::Core.settings(Partiduo::Api::Actor.anonymous) }
    end
  end

  describe ".update_settings" do
    it "modifie la configuration" do
      current = provision_instance.settings
      input = current.to_input.copy_with(company_name: "Exemple SAS", legal_form: "SAS", auth_minimum_level: 3,
        session_duration_minutes: 60)

      view = Partiduo::Api::Core.update_settings(admin, input).value!

      view.company_name.should eq("Exemple SAS")
      view.auth_minimum_level.should eq(3)
      Partiduo::Api::Core.settings(actor_with).session_duration_minutes.should eq(60)
    end

    it "garde les valeurs par défaut enregistrées quand la saisie les omet" do
      provision_instance(settings_input(default_locale: "nl", auth_methods: ["passkey"]))
      view = Partiduo::Api::Core.update_settings(admin, settings_input).value!
      view.default_locale.should eq("nl")
      view.auth_methods.should eq(["passkey"])
    end

    it "exige la permission core.settings.manage" do
      provision_instance
      expect_raises(Partiduo::Api::Forbidden) { Partiduo::Api::Core.update_settings(actor_with, settings_input) }
    end

    it "lève NotFound sur une instance non provisionnée" do
      expect_raises(Partiduo::Api::NotFound) { Partiduo::Api::Core.update_settings(admin, settings_input) }
    end

    it "refuse de changer le régime fiscal" do
      provision_instance
      input = settings_input(tax_regime: "be", country_code: "BE", siren: nil, vat_number: nil)
      result = Partiduo::Api::Core.update_settings(admin, input)
      result.error_keys.should eq(["core.errors.settings.tax_regime.immutable"])
      Partiduo::Api::Core.settings(actor_with).tax_regime.should eq("fr")
    end

    it "n'enregistre rien en cas d'erreur" do
      provision_instance
      result = Partiduo::Api::Core.update_settings(admin, settings_input(company_name: " "))
      result.error_keys.should eq(["core.errors.settings.company_name.blank"])
      Partiduo::Api::Core.settings(actor_with).company_name.should eq("Exemple SARL")
    end
  end

  describe ".check_settings" do
    it "applique la même règle sans rien enregistrer" do
      Partiduo::Api::Core.check_settings(admin, settings_input).success?.should be_true
      Partiduo::Api::Core.check_settings(admin, settings_input(tax_regime: "de", country_code: "FR")).error_keys
        .should contain("core.errors.settings.tax_regime.invalid")
      Partiduo::Core::Settings.all.count.should eq(0)
    end

    it "exige la permission core.settings.manage" do
      expect_raises(Partiduo::Api::Forbidden) { Partiduo::Api::Core.check_settings(actor_with, settings_input) }
    end
  end

  describe "règles de validation" do
    it "signale chaque champ fautif avec sa clé et ses paramètres" do
      cases = {
        settings_input(company_name: nil)                                 => {"company_name", "blank"},
        settings_input(company_name: "x" * 256)                           => {"company_name", "too_long"},
        settings_input(tax_regime: nil, country_code: "FR")               => {"tax_regime", "blank"},
        settings_input(tax_regime: "de", country_code: "FR")              => {"tax_regime", "invalid"},
        settings_input(country_code: "France")                            => {"country_code", "invalid"},
        settings_input(country_code: "BE", vat_number: nil)               => {"country_code", "regime_mismatch"},
        settings_input(siren: "732829321", vat_number: nil)               => {"siren", "invalid"},
        settings_input(vat_number: "FR45732829320")                       => {"vat_number", "invalid"},
        settings_input(vat_number: "FR82542065479")                       => {"vat_number", "siren_mismatch"},
        settings_input(vat_number: "BE0403170701")                        => {"vat_number", "country_mismatch"},
        settings_input(share_capital: BigDecimal.new("-1"))               => {"share_capital", "negative"},
        settings_input(share_capital: BigDecimal.new("1.005"))            => {"share_capital", "too_precise"},
        settings_input(email: "compta@")                                  => {"email", "invalid"},
        settings_input(default_locale: "de")                              => {"default_locale", "invalid"},
        settings_input(domain: "")                                        => {"domain", "blank"},
        settings_input(domain: "sans_point")                              => {"domain", "invalid"},
        settings_input(auth_methods: [] of String)                        => {"auth_methods", "blank"},
        settings_input(auth_methods: ["sms"])                             => {"auth_methods", "unknown"},
        settings_input(auth_minimum_level: 4)                             => {"auth_minimum_level", "out_of_range"},
        settings_input(auth_methods: ["password"], auth_minimum_level: 3) => {"auth_minimum_level", "unreachable"},
        settings_input(session_duration_minutes: 2)                       => {"session_duration_minutes", "out_of_range"},
      }

      cases.each do |input, (field, code)|
        result = Partiduo::Api::Core.check_settings(admin, input)
        result.errors.map { |error| {error.field, error.key} }
          .should eq([{field, "core.errors.settings.#{field}.#{code}"}])
      end
    end

    it "refuse le SIREN hors du régime français" do
      input = settings_input(tax_regime: "be", vat_number: nil)
      Partiduo::Api::Core.check_settings(admin, input).error_keys.should eq(["core.errors.settings.siren.not_applicable"])
    end

    it "admet Monaco sous le régime français et une clé TVA alphanumérique" do
      input = settings_input(country_code: "mc", vat_number: "FRAB732829320")
      Partiduo::Api::Core.check_settings(admin, input).success?.should be_true
    end

    it "normalise les méthodes d'authentification dans l'ordre canonique" do
      view = provision_instance(settings_input(auth_methods: ["Passkey, password", "passkey"]))
      view.settings.auth_methods.should eq(%w[password passkey])
    end

    it "traduit chaque message d'erreur en fr, en et nl avec ses paramètres" do
      result = Partiduo::Api::Core.check_settings(admin, settings_input(company_name: "x" * 300))
      error = result.errors.first
      I18n.with_locale("fr") { error.message.should eq("La raison sociale ne peut dépasser 255 caractères.") }
      I18n.with_locale("en") { error.message.should eq("The company name cannot exceed 255 characters.") }
      I18n.with_locale("nl") { error.message.should eq("De firmanaam mag niet langer zijn dan 255 tekens.") }
    end
  end

  describe "contraintes en base" do
    it "interdit une seconde ligne" do
      provision_instance
      second = Partiduo::Core::SettingsRules.assign(Partiduo::Core::Settings.new,
        Partiduo::Core::SettingsRules.normalize(settings_input))
      expect_raises(Exception, /core_settings_single_row/) { second.save! }
    end

    it "contraint le régime fiscal et le niveau d'authentification" do
      provision_instance
      Marten::DB::Connection.default.open do |db|
        expect_raises(Exception, /core_settings_tax_regime_check/) do
          db.exec("UPDATE core_settings SET tax_regime = 'de'")
        end
        expect_raises(Exception, /core_settings_auth_level_check/) do
          db.exec("UPDATE core_settings SET auth_minimum_level = 0")
        end
      end
    end
  end
end
