# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Lot 6 — prévisions budgétaires (`Anticipation`, D-FCT-001, D-FCT-002) :
# cas limites, droits, Comptabilité inactive, journaux visibles et
# contraintes d'intégrité en base.
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

private def category(budget : Api::ForecastView, label : String = "Charges", position : Int32 = 0) : Api::ForecastCategoryView
  Api.create_forecast_category(system, budget.id, Api::ForecastCategoryInput.new(label, position)).value!
end

private def item(category : Api::ForecastCategoryView, label : String, formula : String, amount : String = "0",
                 **options) : Api::ForecastItemView
  Api.create_forecast_item(system, category.id, Api::ForecastItemInput.new(label, formula, d(amount)).copy_with(**options)).value!
end

private def refused?(& : -> _) : Symbol
  yield
  :allowed
rescue Partiduo::Api::ModuleDisabled
  :disabled
rescue Partiduo::Api::Forbidden
  :forbidden
rescue Partiduo::Api::NotFound
  :not_found
end

private def each_call(actor : Partiduo::Api::Actor, & : String, String, Proc(Nil) ->) : Nil
  input = Api::ForecastInput.new("B", 1_i64, 1_i64)
  item = Api::ForecastItemInput.new("E", "[6%]")
  {
    {"forecasts", Api::REPORT_READ, -> { Api.forecasts(actor); nil }},
    {"forecast", Api::REPORT_READ, -> { Api.forecast(actor, 1_i64); nil }},
    {"forecast_report", Api::REPORT_READ, -> { Api.forecast_report(actor, 1_i64); nil }},
    {"check_forecast", Api::REPORT_WRITE, -> { Api.check_forecast(actor, input); nil }},
    {"create_forecast", Api::REPORT_WRITE, -> { Api.create_forecast(actor, input); nil }},
    {"update_forecast", Api::REPORT_WRITE, -> { Api.update_forecast(actor, 1_i64, input); nil }},
    {"delete_forecast", Api::REPORT_WRITE, -> { Api.delete_forecast(actor, 1_i64); nil }},
    {"clone_forecast", Api::REPORT_WRITE, -> { Api.clone_forecast(actor, 1_i64, "C"); nil }},
    {"create_forecast_category", Api::REPORT_WRITE, -> { Api.create_forecast_category(actor, 1_i64, Api::ForecastCategoryInput.new("C")); nil }},
    {"update_forecast_category", Api::REPORT_WRITE, -> { Api.update_forecast_category(actor, 1_i64, Api::ForecastCategoryInput.new("C")); nil }},
    {"delete_forecast_category", Api::REPORT_WRITE, -> { Api.delete_forecast_category(actor, 1_i64); nil }},
    {"check_forecast_item", Api::REPORT_WRITE, -> { Api.check_forecast_item(actor, 1_i64, item); nil }},
    {"create_forecast_item", Api::REPORT_WRITE, -> { Api.create_forecast_item(actor, 1_i64, item); nil }},
    {"update_forecast_item", Api::REPORT_WRITE, -> { Api.update_forecast_item(actor, 1_i64, item); nil }},
    {"delete_forecast_item", Api::REPORT_WRITE, -> { Api.delete_forecast_item(actor, 1_i64); nil }},
  }.each { |(name, permission, call)| yield name, permission, call }
end

describe "Prévisions : Comptabilité inactive et droits" do
  it "lève ModuleDisabled sur chaque appel quand la Comptabilité est inactive" do
    with_active_modules("invoicing,stock,followup") do
      each_call(system) do |name, _, call|
        {name, refused? { call.call }}.should eq({name, :disabled})
      end
    end
  end

  it "exige accounting.report.read pour lire, accounting.report.write pour écrire, avant toute recherche" do
    with_active_modules("accounting") do
      each_call(actor_with) do |name, _, call|
        {name, refused? { call.call }}.should eq({name, :forbidden})
      end
      [Api::REPORT_READ, Api::REPORT_WRITE].each do |held|
        each_call(actor_with(held)) do |name, permission, call|
          next if permission == held
          {name, held, refused? { call.call }}.should eq({name, held, :forbidden})
        end
      end
    end
  end
end

describe_module "ACCOUNTING", "Prévisions : cas limites" do
  it "retient un montant propre nul, ajoute le montant initial à la première période et totalise par catégorie" do
    EntrySpec.setup
    budget = forecast
    charges = category(budget)
    april = EntrySpec.period("2026-04-01")
    item(charges, "Achats", "[60%-s]", "100", initial_amount: d("25"),
      period_amounts: [Api::ForecastPeriodAmountInput.new(april.id, d("0"))])
    item(charges, "Services", "[61%-s]", "10")
    report = Api.forecast_report(system, budget.id)
    rows = report.categories.first.items
    rows[0].estimated.should eq([d("125"), d("0"), d("100")])
    rows[0].estimated_total.should eq(d("225"))
    report.categories.first.estimated.should eq([d("135"), d("10"), d("110")])
    report.categories.first.real.should eq([d("0"), d("0"), d("0")])
    rows[1].real_cumulative.should eq([d("0"), d("0"), d("0")])
  end

  it "calcule le réel depuis le mois FROM de la formule jusqu'à la fin de chaque période" do
    EntrySpec.setup
    EntrySpec.post_misc([EntrySpec.debit("603", "100"), EntrySpec.credit("400", "100")], "2026-02-10")
    EntrySpec.post_misc([EntrySpec.debit("603", "400"), EntrySpec.credit("400", "400")], "2026-03-10")
    EntrySpec.post_misc([EntrySpec.debit("603", "50"), EntrySpec.credit("400", "50")], "2026-04-10")
    budget = forecast
    charges = category(budget)
    item(charges, "Cumul", "[60%-s] FROM=01.2026")
    item(charges, "Mensuel", "[60%-s]")
    rows = Api.forecast_report(system, budget.id).categories.first.items
    rows[0].real.should eq([d("500"), d("550"), d("550")])
    rows[1].real.should eq([d("400"), d("50"), d("0")])
  end

  it "ne lit le réel que dans les journaux visibles de l'acteur" do
    EntrySpec.setup
    EntrySpec.post_misc([EntrySpec.debit("603", "400"), EntrySpec.credit("400", "400")], "2026-03-10")
    budget = forecast
    item(category(budget), "Achats", "[60%-s]")
    user_id, reader = AccountingSpec.user_actor("budget@example.test", Api::REPORT_READ)
    Partiduo::Api::Auth.set_ledger_security(system, user_id, true).value!
    Partiduo::Api::Auth.set_ledger_access(system, user_id, EntrySpec.ledger("V01").id, "R").value!
    Api.forecast_report(reader, budget.id).categories.first.items.first.real.should eq([d("0"), d("0"), d("0")])
    Api.forecast_report(system, budget.id).categories.first.items.first.real.should eq([d("400"), d("0"), d("0")])
  end

  it "signale une formule devenue invalide et compte son réel à zéro" do
    EntrySpec.setup
    EntrySpec.post_misc([EntrySpec.debit("603", "400"), EntrySpec.credit("400", "400")], "2026-03-10")
    budget = forecast
    broken = item(category(budget), "Cassé", "[60%-s]", "5")
    EntrySpec.sql("UPDATE accounting_forecast_item SET formula = '[60%' WHERE id = $1", broken.id)
    report = Api.forecast_report(system, budget.id)
    report.invalid_items.should eq(["Cassé"])
    report.categories.first.items.first.real.should eq([d("0"), d("0"), d("0")])
    report.categories.first.items.first.estimated.should eq([d("5"), d("5"), d("5")])
  end

  it "accepte une prévision d'une seule période et range catégories et éléments par rang" do
    EntrySpec.setup
    single = forecast("Mars", "2026-03-01", "2026-03-01")
    Api.forecast_report(system, single.id).periods.size.should eq(1)
    second = category(single, "B", 2)
    first = category(single, "A", 1)
    item(second, "Y", "[7%]", position: 2)
    item(second, "X", "[6%]", position: 1)
    view = Api.forecast(system, single.id)
    view.categories.map(&.label).should eq(["A", "B"])
    view.categories[1].items.map(&.label).should eq(["X", "Y"])
    Api.update_forecast_category(system, first.id, Api::ForecastCategoryInput.new("Z", 3)).value!.label.should eq("Z")
    Api.forecast(system, single.id).categories.map(&.label).should eq(["B", "Z"])
    Api.update_forecast_category(system, first.id, Api::ForecastCategoryInput.new(" ")).error_keys
      .should eq(["accounting.errors.forecast.label.blank"])
  end

  it "remplace l'élément entier, montants par période compris" do
    EntrySpec.setup
    budget = forecast
    march = EntrySpec.period("2026-03-01")
    april = EntrySpec.period("2026-04-01")
    row = item(category(budget), "Achats", "[60%-s]", "10",
      period_amounts: [Api::ForecastPeriodAmountInput.new(march.id, d("1"))])
    updated = Api.update_forecast_item(system, row.id, Api::ForecastItemInput.new(" Achats HT ", " [601%-s] ", d("20"),
      period_amounts: [Api::ForecastPeriodAmountInput.new(april.id, d("2.5"))])).value!
    {updated.label, updated.formula, updated.amount}.should eq({"Achats HT", "[601%-s]", d("20")})
    updated.period_amounts.map { |amount| {amount.period_id, amount.amount} }.should eq([{april.id, d("2.5")}])
    expect_raises(Partiduo::Api::NotFound) { Api.update_forecast_item(system, 999_999_i64, Api::ForecastItemInput.new("X", "[6%]")) }
    expect_raises(Partiduo::Api::NotFound) { Api.delete_forecast_item(system, 999_999_i64) }
    expect_raises(Partiduo::Api::NotFound) { Api.create_forecast_item(system, 999_999_i64, Api::ForecastItemInput.new("X", "[6%]")) }
    expect_raises(Partiduo::Api::NotFound) { Api.delete_forecast_category(system, 999_999_i64) }
    expect_raises(Partiduo::Api::NotFound) { Api.clone_forecast(system, 999_999_i64, "Copie") }
  end

  it "refuse une copie sans nom et un montant trop précis ; admet une formule vide (réel nul, D-FCT-003)" do
    EntrySpec.setup
    budget = forecast
    Api.clone_forecast(system, budget.id, "  ").error_keys.should eq(["accounting.errors.forecast.name.blank"])
    Api.forecasts(system).size.should eq(1)
    charges = category(budget)
    result = Api.check_forecast_item(system, charges.id, Api::ForecastItemInput.new("E", " ", d("1"), d("0.00001")))
    result.errors.map { |error| {error.field, error.key} }.should eq([
      {"initial_amount", "accounting.errors.forecast.amount.scale"},
    ])
    item(charges, "Sans formule", " ", "5")
    row = Api.forecast_report(system, budget.id).categories.first.items.first
    {row.formula, row.estimated, row.real}.should eq({"", [d("5"), d("5"), d("5")], [d("0"), d("0"), d("0")]})
    Api.forecast_report(system, budget.id).invalid_items.should be_empty
    Api.create_forecast(system, Api::ForecastInput.new("n" * 256, budget.forecast.start_period_id,
      budget.forecast.end_period_id)).error_keys.should eq(["accounting.errors.forecast.name.too_long"])
  end

  it "efface la prévision avec ses catégories, éléments et montants" do
    EntrySpec.setup
    budget = forecast
    march = EntrySpec.period("2026-03-01")
    item(category(budget), "Achats", "[60%-s]", period_amounts: [Api::ForecastPeriodAmountInput.new(march.id, d("1"))])
    Api.clone_forecast(system, budget.id, "Copie").value!
    Api.delete_forecast(system, budget.id).success?.should be_true
    %w[accounting_forecast accounting_forecast_category accounting_forecast_item accounting_forecast_amount].each do |table|
      {table, EntrySpec.scalar("SELECT count(*) FROM #{table}")}.should eq({table, 1})
    end
    expect_raises(Partiduo::Api::NotFound) { Api.delete_forecast(system, budget.id) }
  end

  describe "intégrité en base" do
    it "refuse une période inexistante et deux montants d'un élément pour une même période" do
      EntrySpec.setup
      budget = forecast
      march = EntrySpec.period("2026-03-01")
      row = item(category(budget), "Achats", "[60%-s]", period_amounts: [Api::ForecastPeriodAmountInput.new(march.id, d("1"))])
      expect_raises(Exception, /accounting_forecast_start_fk/) do
        EntrySpec.sql_transaction(&.exec("UPDATE accounting_forecast SET start_period_id = 987654 WHERE id = $1", budget.id))
      end
      expect_raises(Exception, /accounting_forecast_end_fk/) do
        EntrySpec.sql_transaction(&.exec("UPDATE accounting_forecast SET end_period_id = 987654 WHERE id = $1", budget.id))
      end
      expect_raises(Exception, /accounting_forecast_amount_period_fk/) do
        EntrySpec.sql_transaction(&.exec("UPDATE accounting_forecast_amount SET period_id = 987654 WHERE item_id = $1", row.id))
      end
      expect_raises(Exception, /accounting_forecast_amount_unique/) do
        EntrySpec.sql_transaction(&.exec("INSERT INTO accounting_forecast_amount (item_id, period_id, amount) " \
                                         "VALUES ($1, $2, 5)", row.id, march.id))
      end
      expect_raises(Exception, /foreign key|violates/i) do
        EntrySpec.sql_transaction(&.exec("DELETE FROM core_period WHERE id = $1", march.id))
      end
    end
  end
end
