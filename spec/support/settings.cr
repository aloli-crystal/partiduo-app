# SPDX-License-Identifier: AGPL-3.0-or-later

# Saisie de configuration société valide (régime français par défaut).
def settings_input(**overrides) : Partiduo::Api::Core::SettingsInput
  Partiduo::Api::Core::SettingsInput.new(
    company_name: "Exemple SARL",
    legal_form: "SARL",
    share_capital: BigDecimal.new("10000.00"),
    rcs: "RCS Nantes 732 829 320",
    siren: "732 829 320",
    vat_number: "FR 44 732829320",
    street: "rue des Lilas",
    street_number: "12",
    postcode: "44000",
    city: "Nantes",
    tax_regime: "fr",
    domain: "exemple.partiduo.localhost",
  ).copy_with(**overrides)
end

# Provisionne l'instance de test avec l'acteur système.
def provision_instance(settings = settings_input, modules = [] of String, admin_email : String? = nil) : Partiduo::Api::Core::ProvisionView
  input = Partiduo::Api::Core::ProvisionInput.new(settings: settings, modules: modules, admin_email: admin_email)
  Partiduo::Api::Core.provision(Partiduo::Api::Actor.system, input).value!
end
