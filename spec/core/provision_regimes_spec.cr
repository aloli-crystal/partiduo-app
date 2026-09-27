# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Compléments de couverture du provisionnement selon le régime (D-SET-005,
# D-SET-006, D-ACC-003) : une instance française et une instance belge
# complètes, refus propres au régime, annulation totale d'un refus.

private def system : Partiduo::Api::Actor
  Partiduo::Api::Actor.system
end

private def be_settings(**overrides) : Partiduo::Api::Core::SettingsInput
  settings_input(company_name: "Exemple SRL", legal_form: "SRL", tax_regime: "be", siren: nil,
    rcs: "RPM Bruxelles", vat_number: "BE 0417.497.106", postcode: "1000", city: "Bruxelles").copy_with(**overrides)
end

private def run_provision(*options : String) : {Int32, String, String}
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  command = Partiduo::Core::Commands::Provision.new(options.to_a, stdout: stdout, stderr: stderr, exit_raises: true)
  {command.handle, stdout.to_s, stderr.to_s}
end

describe "Provisionnement : instance française" do
  it "crée société, devise, taux, catégories, profils et administrateur invité" do
    view = provision_instance(admin_email: "patron@exemple.fr")
    view.settings.tax_regime.should eq("fr")
    view.settings.country_code.should eq("FR")
    Partiduo::Api::Core.base_currency(system).code.should eq("EUR")

    rates = Partiduo::Api::Vat.rates(system, include_disabled: true)
    rates.size.should eq(15)
    rates.map(&.code).should contain("NOR")
    rates.none? { |rate| rate.code == "21G" }.should be_true

    Partiduo::Api::Cards.categories(system).map(&.code).should contain("CUSTOMER")
    Partiduo::Api::Cards.categories(system).map(&.code).should contain("SUPPLIER")
    Partiduo::Api::Auth.profiles(system).map(&.code).sort!.should eq(["ACCOUNTANT", "ADMIN"])
    Partiduo::Api::Auth.user_by_email(system, "patron@exemple.fr").should_not be_nil
    view.invitations.map(&.email).should eq(["patron@exemple.fr"])
  end

  it "refuse un numéro de TVA étranger ou qui ne correspond pas au SIREN" do
    result = Partiduo::Api::Core.provision(system, Partiduo::Api::Core::ProvisionInput.new(
      settings: settings_input(vat_number: "BE 0417.497.106")))
    result.errors_for("vat_number").map(&.key).should eq(["core.errors.settings.vat_number.country_mismatch"])

    result = Partiduo::Api::Core.provision(system, Partiduo::Api::Core::ProvisionInput.new(
      settings: settings_input(siren: "552 100 554", vat_number: "FR 44 732829320")))
    result.errors_for("vat_number").map(&.key).should eq(["core.errors.settings.vat_number.siren_mismatch"])
  end

  it "n'écrit rien quand le provisionnement est refusé" do
    result = Partiduo::Api::Core.provision(system, Partiduo::Api::Core::ProvisionInput.new(
      settings: settings_input(siren: "123"), admin_email: "patron@exemple.fr"))
    result.failure?.should be_true
    Partiduo::Core::Settings.all.count.should eq(0)
    Partiduo::Api::Vat.rates(system, include_disabled: true).should be_empty
    Partiduo::Api::Auth.profiles(system).should be_empty
    Partiduo::Api::Auth.users(system).should be_empty
  end
end

describe "Provisionnement : instance belge" do
  it "crée société, devise, taux belges et profils ; normalise le numéro d'entreprise" do
    view = provision_instance(be_settings, admin_email: "patron@exemple.be")
    view.settings.tax_regime.should eq("be")
    view.settings.country_code.should eq("BE")
    view.settings.vat_number.should eq("BE0417497106")
    view.settings.siren.should eq("")
    Partiduo::Api::Core.base_currency(system).code.should eq("EUR")

    rates = Partiduo::Api::Vat.rates(system, include_disabled: true)
    rates.size.should eq(8)
    rates.map(&.code).should contain("21G")
    rates.none? { |rate| rate.code == "NOR" }.should be_true
    Partiduo::Api::Auth.profiles(system).size.should eq(2)
    view.invitations.map(&.email).should eq(["patron@exemple.be"])
  end

  it "refuse un numéro d'entreprise belge dont la clé est fausse" do
    result = Partiduo::Api::Core.provision(system, Partiduo::Api::Core::ProvisionInput.new(
      settings: be_settings(vat_number: "BE 0417.497.107")))
    result.errors_for("vat_number").map(&.key).should eq(["core.errors.settings.vat_number.invalid"])
    Partiduo::Core::Settings.all.count.should eq(0)
  end

  it "garde le régime belge : il ne se change pas après coup" do
    provision_instance(be_settings)
    result = Partiduo::Api::Core.update_settings(system, be_settings(tax_regime: "fr"))
    result.errors_for("tax_regime").map(&.key).should eq(["core.errors.settings.tax_regime.immutable"])
    Partiduo::Api::Core.settings(system).tax_regime.should eq("be")
  end

  it "provisionne par la commande avec --vat et rend compte en français" do
    code, output, errors = run_provision("--name=Exemple SRL", "--regime=be", "--vat=BE0417497106",
      "--domain=exemple-be.partiduo.localhost", "--admin-email=patron@exemple.be")
    errors.should eq("")
    code.should eq(0)
    output.should contain("Régime fiscal : Belgique.")
    output.should contain("https://exemple-be.partiduo.localhost/invitation/")
    Partiduo::Api::Core.settings(system).vat_number.should eq("BE0417497106")
  end
end

describe_module "ACCOUNTING", "Provisionnement : plan comptable selon le régime" do
  it "charge le PCG français (mod2) avec l'instance française" do
    provision_instance
    Partiduo::Api::Accounting.chart(system).size.should eq(167)
    Partiduo::Api::Accounting.ledgers(system).map(&.code).should eq(%w[A01 F01 O01 V01])
    Partiduo::Api::Accounting.default_account(system, "customer").try(&.number).should eq("410")
  end

  it "charge le PCMN belge (mod1) avec l'instance belge, journaux dans la langue du dossier" do
    provision_instance(be_settings(default_locale: "nl"))
    Partiduo::Api::Accounting.chart(system).size.should eq(504)
    Partiduo::Api::Accounting.ledgers(system).map(&.name).should contain("Verkopen")
    Partiduo::Api::Accounting.default_account(system, "customer").try(&.number).should eq("400")
  end
end
