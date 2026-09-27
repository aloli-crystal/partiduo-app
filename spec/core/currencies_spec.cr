# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias Api = Partiduo::Api::Core
private alias R = ReferentialSpec

private def manager : Partiduo::Api::Actor
  actor_with("core.currency.write")
end

private def usd(rate : String = "0.92", day : String = "2026-01-01") : Partiduo::Api::Result(Api::CurrencyView)
  Api.create_currency(manager, Api::CurrencyInput.new(code: "usd", name: "Dollar américain",
    rate: BigDecimal.new(rate), valid_from: R.date(day)))
end

describe "Partiduo::Api::Core — devises (currency, currency_history)" do
  it "crée la devise de tenue une seule fois, réservée à l'acteur système" do
    base = Api.ensure_base_currency(R.system)
    base.code.should eq("EUR")
    base.base.should be_true
    Api.ensure_base_currency(R.system).id.should eq(base.id)
    Api.base_currency(actor_with).code.should eq("EUR")
    expect_raises(Partiduo::Api::Forbidden) { Api.ensure_base_currency(manager) }
  end

  it "crée une devise avec son premier cours et la liste après la devise de tenue" do
    Api.ensure_base_currency(R.system)
    view = usd.value!
    view.code.should eq("USD")
    R.present(view.latest_rate).rate.should eq(BigDecimal.new("0.92"))
    Api.currencies(actor_with).map(&.code).should eq(%w[EUR USD])
  end

  it "applique les règles de Currency_MTable::check" do
    Api.ensure_base_currency(R.system)
    usd
    result = Api.create_currency(manager, Api::CurrencyInput.new(code: "usd", name: "", decimals: 9))
    result.error_keys.should eq([
      "core.errors.currency.code.taken",
      "core.errors.currency.name.blank",
      "core.errors.currency.decimals.out_of_range",
      "core.errors.currency.valid_from.blank",
      "core.errors.currency.rate.blank",
    ])
    R.expect_translated(result)

    invalid = Api.create_currency(manager, Api::CurrencyInput.new(code: "US", name: "X",
      rate: BigDecimal.new("0"), valid_from: R.date("2026-01-01")))
    invalid.error_keys.should eq(["core.errors.currency.code.invalid", "core.errors.currency.rate.not_positive"])
    precise = Api.create_currency(manager, Api::CurrencyInput.new(code: "GBP", name: "Livre",
      rate: BigDecimal.new("1.123456789"), valid_from: R.date("2026-01-01")))
    precise.error_keys.should eq(["core.errors.currency.rate.too_precise"])
  end

  it "ajoute des cours postérieurs au dernier et donne le cours d'une date" do
    usd("0.90", "2026-01-01")
    Api.add_currency_rate(manager, Api::CurrencyRateInput.new("USD", BigDecimal.new("0.95"), R.date("2026-03-01"))).success?.should be_true
    late = Api.add_currency_rate(manager, Api::CurrencyRateInput.new("USD", BigDecimal.new("0.99"), R.date("2026-02-01")))
    late.error_keys.should eq(["core.errors.currency.valid_from.not_after_last"])
    late.errors.first.params.should eq({"date" => "2026-03-01"})

    Api.rate_on(actor_with, "usd", R.date("2025-12-31")).should be_nil
    Api.rate_on(actor_with, "USD", R.date("2026-02-15")).should eq(BigDecimal.new("0.90"))
    Api.rate_on(actor_with, "USD", R.date("2026-03-01")).should eq(BigDecimal.new("0.95"))
  end

  it "ne modifie ni ne supprime la devise de tenue" do
    Api.ensure_base_currency(R.system)
    Api.update_currency(manager, "EUR", "Euro", 2).error_keys.should eq(["core.errors.currency.code.base_immutable"])
    Api.delete_currency(manager, "EUR").error_keys.should eq(["core.errors.currency.code.base_immutable"])
    Api.add_currency_rate(manager, Api::CurrencyRateInput.new("EUR", BigDecimal.new("1"), R.date("2026-01-01")))
      .error_keys.should eq(["core.errors.currency.code.base_immutable"])
    Api.rate_on(actor_with, "EUR", R.date("2026-01-01")).should eq(BigDecimal.new(1))
  end

  it "renomme et supprime une devise étrangère" do
    usd
    Api.update_currency(manager, "USD", "US dollar", 2).value!.name.should eq("US dollar")
    Api.delete_currency(manager, "USD").success?.should be_true
    expect_raises(Partiduo::Api::NotFound) { Api.currency(actor_with, "USD") }
  end

  it "exige la permission core.currency.write" do
    expect_raises(Partiduo::Api::Forbidden) do
      Api.create_currency(actor_with, Api::CurrencyInput.new(code: "USD", name: "Dollar"))
    end
  end

  it "contraint le code, le cours et l'unicité de la devise de tenue en base" do
    Api.ensure_base_currency(R.system)
    expect_raises(Exception, /core_currency_single_base/) do
      Marten::DB::Connection.default.open do |db|
        db.exec("INSERT INTO core_currency (code, name, decimals, base, created_at, updated_at) " \
                "VALUES ('CHF', 'Franc', 2, true, now(), now())")
      end
    end
  end
end
