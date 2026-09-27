# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Lot 6 — prévisions budgétaires (`forecast`, `Anticipation`, D-FCT-001,
# D-FCT-002).
private alias Api = Partiduo::Api::Accounting

private def system : Partiduo::Api::Actor
  Partiduo::Api::Actor.system
end

private def d(text : String) : BigDecimal
  BigDecimal.new(text)
end

private def forecast(name : String = "Budget 2026", from : String = "2026-03-01", to : String = "2026-05-01") : Api::ForecastView
  Api.create_forecast(system, Api::ForecastInput.new(name, EntrySpec.period(from).id, EntrySpec.period(to).id)).value!
end

describe_module "ACCOUNTING", "Prévisions budgétaires" do
  it "compare l'estimé et le réel période par période" do
    EntrySpec.setup
    EntrySpec.post_misc([EntrySpec.debit("603", "400"), EntrySpec.credit("400", "400")], "2026-03-10")
    EntrySpec.post_misc([EntrySpec.debit("603", "250"), EntrySpec.credit("400", "250")], "2026-04-12")
    EntrySpec.post_misc([EntrySpec.debit("510001", "900"), EntrySpec.credit("706", "900")], "2026-04-20")
    budget = forecast
    april = EntrySpec.period("2026-04-01")
    charges = Api.create_forecast_category(system, budget.id, Api::ForecastCategoryInput.new("Charges", 1)).value!
    sales = Api.create_forecast_category(system, budget.id, Api::ForecastCategoryInput.new("Produits", 2)).value!
    Api.create_forecast_item(system, charges.id, Api::ForecastItemInput.new("Achats", "[60%-s]", d("300"),
      initial_amount: d("50"), period_amounts: [Api::ForecastPeriodAmountInput.new(april.id, d("200"))])).value!
    Api.create_forecast_item(system, sales.id, Api::ForecastItemInput.new("Prestations", "[706-S]", d("1000"))).value!

    report = Api.forecast_report(system, budget.id)
    report.periods.map(&.starts_on).should eq([EntrySpec.date("2026-03-01"), EntrySpec.date("2026-04-01"),
                                               EntrySpec.date("2026-05-01")])
    purchases = report.categories[0].items[0]
    purchases.estimated.should eq([d("350"), d("200"), d("300")])
    purchases.real.should eq([d("400"), d("250"), d("0")])
    purchases.estimated_cumulative.should eq([d("350"), d("550"), d("850")])
    purchases.real_total.should eq(d("650"))
    purchases.differences.should eq([d("50"), d("50"), d("-300")])
    report.categories[1].real.should eq([d("0"), d("900"), d("0")])
    report.invalid_items.should be_empty
  end

  it "contrôle la prévision et ses éléments" do
    EntrySpec.setup
    result = Api.create_forecast(system, Api::ForecastInput.new(" ", EntrySpec.period("2026-05-01").id,
      EntrySpec.period("2026-03-01").id))
    result.error_keys.should eq(["accounting.errors.forecast.name.blank", "accounting.errors.forecast.period.order"])
    ReferentialSpec.expect_translated(result)
    Api.check_forecast(system, Api::ForecastInput.new("B", 999_999_i64, 999_999_i64)).error_keys
      .should eq(["accounting.errors.forecast.period.unknown", "accounting.errors.forecast.period.unknown"])

    budget = forecast
    category = Api.create_forecast_category(system, budget.id, Api::ForecastCategoryInput.new("Charges")).value!
    outside = EntrySpec.period("2026-09-01")
    march = EntrySpec.period("2026-03-01")
    item = Api.create_forecast_item(system, category.id, Api::ForecastItemInput.new("", "[60%", d("1.00001"),
      period_amounts: [Api::ForecastPeriodAmountInput.new(outside.id, d("1")),
                       Api::ForecastPeriodAmountInput.new(march.id, d("1")),
                       Api::ForecastPeriodAmountInput.new(march.id, d("2"))]))
    item.errors.map(&.field).should eq(["label", "formula", "amount", "period_amounts[0].period_id",
                                        "period_amounts[2].period_id"])
    ReferentialSpec.expect_translated(item)
    Api.check_forecast_item(system, category.id, Api::ForecastItemInput.new("Achats", "$TOTAL")).error_keys
      .should eq(["accounting.errors.formula.variable"])
  end

  it "copie une prévision et retire les montants des périodes sorties" do
    EntrySpec.setup
    budget = forecast
    category = Api.create_forecast_category(system, budget.id, Api::ForecastCategoryInput.new("Charges")).value!
    march = EntrySpec.period("2026-03-01")
    may = EntrySpec.period("2026-05-01")
    item = Api.create_forecast_item(system, category.id, Api::ForecastItemInput.new("Achats", "[60%-s]", d("300"),
      d("10"), period_amounts: [Api::ForecastPeriodAmountInput.new(march.id, d("1")),
                                Api::ForecastPeriodAmountInput.new(may.id, d("5"))])).value!
    item.period_amounts.map(&.amount).should eq([d("1"), d("5")])

    copy = Api.clone_forecast(system, budget.id, "Budget révisé").value!
    copy.categories.first.items.first.initial_amount.should eq(d("10"))
    copy.categories.first.items.first.period_amounts.size.should eq(2)
    Api.forecasts(system).map(&.name).should eq(["Budget 2026", "Budget révisé"])

    Api.update_forecast(system, budget.id, Api::ForecastInput.new("Budget 2026", march.id,
      EntrySpec.period("2026-04-01").id)).value!
    Api.forecast(system, budget.id).categories.first.items.first.period_amounts.map(&.period_id).should eq([march.id])
    Api.forecast(system, copy.id).categories.first.items.first.period_amounts.size.should eq(2)

    Api.delete_forecast_item(system, item.id).success?.should be_true
    Api.delete_forecast_category(system, category.id).success?.should be_true
    Api.delete_forecast(system, budget.id).success?.should be_true
    expect_raises(Partiduo::Api::NotFound) { Api.forecast(system, budget.id) }
  end

  it "exige les droits des rapports" do
    EntrySpec.setup
    budget = forecast
    expect_raises(Partiduo::Api::Forbidden) { Api.forecasts(actor_with) }
    expect_raises(Partiduo::Api::Forbidden) do
      Api.create_forecast(actor_with(Api::REPORT_READ), Api::ForecastInput.new("X", budget.forecast.start_period_id,
        budget.forecast.end_period_id))
    end
    Api.forecast_report(system, budget.id).categories.should be_empty
  end
end
