# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Déclare des chargeurs le temps d'un exemple.
private def with_loaders(loaders : Array({String, String, Int32, Proc(Partiduo::Api::InitialData::Context, Nil)}), &)
  loaders.each do |owner, name, order, block|
    Partiduo::Api::InitialData.register(owner, name, order, &block)
  end
  yield
ensure
  loaders.try &.each { |owner, name, _, _| Partiduo::Api::InitialData.unregister(owner, name) }
end

private alias Loader = {String, String, Int32, Proc(Partiduo::Api::InitialData::Context, Nil)}

describe Partiduo::Api::InitialData do
  it "exécute les chargeurs des pièces actives, dans l'ordre, avec le régime" do
    seen = [] of String
    loaders = [
      {"CORE", "spec_second", 20, ->(context : Partiduo::Api::InitialData::Context) { seen << "second:#{context.tax_regime}"; nil }},
      {"CORE", "spec_first", 10, ->(context : Partiduo::Api::InitialData::Context) { seen << "first:#{context.country_code}"; nil }},
      {"ACCOUNTING", "spec_chart", 15, ->(_context : Partiduo::Api::InitialData::Context) { seen << "chart"; nil }},
    ] of Loader

    with_active_modules("invoicing") do
      with_loaders(loaders) do
        view = provision_instance(settings_input(tax_regime: "be", siren: nil, vat_number: nil), admin_email: "Admin@Example.org")
        seen.should eq(["first:BE", "second:be"])
        view.loaders.should contain("CORE.spec_first")
        view.loaders.should_not contain("ACCOUNTING.spec_chart")
      end
    end
  end

  it "transmet l'acteur système, la langue, l'administrateur et les modules" do
    received = nil
    loaders = [
      {"CORE", "spec_context", 1, ->(context : Partiduo::Api::InitialData::Context) { received = context; nil }},
    ] of Loader

    with_active_modules("accounting,invoicing") do
      with_loaders(loaders) do
        provision_instance(settings_input(default_locale: "nl"), admin_email: " Admin@Example.org ")
      end
    end

    context = received.should be_a(Partiduo::Api::InitialData::Context)
    context.actor.system.should be_true
    context.locale.should eq("nl")
    context.admin_email.should eq("admin@example.org")
    context.module_codes.should eq(%w[ACCOUNTING INVOICING])
  end

  it "annule tout le provisionnement si un chargeur lève" do
    loaders = [
      {"CORE", "spec_failing", 1, ->(_context : Partiduo::Api::InitialData::Context) { raise "chargeur en échec" }},
    ] of Loader

    with_loaders(loaders) do
      expect_raises(Exception, "chargeur en échec") { provision_instance }
    end
    Partiduo::Core::Settings.all.count.should eq(0)
  end

  it "refuse deux chargeurs de même nom pour une pièce" do
    loaders = [
      {"CORE", "spec_twice", 1, ->(_context : Partiduo::Api::InitialData::Context) { nil }},
    ] of Loader

    with_loaders(loaders) do
      expect_raises(ArgumentError, /CORE.spec_twice/) do
        Partiduo::Api::InitialData.register("CORE", "spec_twice") { |_context| nil }
      end
    end
  end
end
