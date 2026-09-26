# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

describe "Libellés et messages du socle (ADR-005 D7)" do
  it "accorde les pluriels selon la règle de chaque langue" do
    I18n.with_locale("fr") do
      I18n.t("core.settings.session_duration", count: 0).should eq("0 minute")
      I18n.t("core.settings.session_duration", count: 1).should eq("1 minute")
      I18n.t("core.settings.session_duration", count: 90).should eq("90 minutes")
    end
    I18n.with_locale("en") do
      I18n.t("core.settings.session_duration", count: 0).should eq("0 minutes")
      I18n.t("core.settings.session_duration", count: 1).should eq("1 minute")
    end
    I18n.with_locale("nl") do
      I18n.t("core.settings.session_duration", count: 1).should eq("1 minuut")
      I18n.t("core.settings.session_duration", count: 2).should eq("2 minuten")
    end
  end

  it "traduit régimes, méthodes et niveaux d'authentification, champs de la société" do
    keys = Partiduo::Api::Core::TAX_REGIMES.map { |regime| "core.settings.tax_regimes.#{regime}" } +
           Partiduo::Api::Core::AUTH_METHODS.map { |method| "core.settings.auth_methods.#{method}" } +
           Partiduo::Api::Core::AUTH_LEVELS.map { |level| "core.settings.auth_levels.level_#{level}" } +
           Partiduo::LOCALES.map { |locale| "core.settings.locales.#{locale}" } +
           %w[company_name legal_form share_capital rcs siren vat_number street street_number postcode city
             country_code phone email tax_regime default_locale domain auth_methods auth_minimum_level
             session_duration_minutes].map { |field| "core.settings.fields.#{field}" }

    Partiduo::LOCALES.each do |locale|
      I18n.with_locale(locale) do
        keys.each { |key| I18n.t(key).should_not contain("missing") }
      end
    end
  end

  it "fournit un message pour chaque clé d'erreur que produisent les règles" do
    source = File.read(File.expand_path("../../src/core/services/settings_rules.cr", __DIR__))
    pairs = source.scan(/error\("(\w+)", "(\w+)"/).map { |match| "core.errors.settings.#{match[1]}.#{match[2]}" }
    too_long = Partiduo::Core::SettingsRules::MAX_SIZES.keys.map { |field| "core.errors.settings.#{field}.too_long" }
    api = File.read(File.expand_path("../../src/core/api/settings.cr", __DIR__))
    provision = api.scan(/"(core\.errors\.provision\.[\w.]+)"/).map(&.[1])
    provision_modules = %w[modules extensions].flat_map do |field|
      %w[unknown wrong_kind inactive].map { |code| "core.errors.provision.#{field}.#{code}" }
    end

    (pairs + too_long + provision + provision_modules).uniq.each do |key|
      Partiduo::LOCALES.each do |locale|
        I18n.with_locale(locale) { I18n.t(key, max: "1").should_not contain("missing") }
      end
    end
  end
end
