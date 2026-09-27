# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias Api = Partiduo::Api::Micro
private alias M = MicroSpec

# ADR-007 D1 : aide à la déclaration URSSAF, 2042-C-PRO, seuils, taux et
# seuils datés et paramétrables.
describe_module "MICRO", Api do
  it "ventile le chiffre d'affaires trimestriel par catégorie et estime les cotisations aux taux datés" do
    M.setup
    M.receipt("2026-07-03", "1000", "SALE")
    M.receipt("2026-08-10", "2000", "SERVICE")
    M.receipt("2026-09-01", "1200", "FEE", vat_amount: M.d("200"))
    reversed = M.receipt("2026-09-02", "300", "SALE")
    Api.reverse_receipt(M.actor, Api::ReverseInput.new(reversed.id, M.date("2026-09-05"))).value!

    periods = Api.declarations(M.system, 2026, M.date("2026-09-27"))
    periods.size.should eq(4)
    third = periods[2]
    third.starts_on.should eq(M.date("2026-07-01"))
    third.ends_on.should eq(M.date("2026-09-30"))
    third.due_on.should eq(M.date("2026-10-31"))
    third.status.should eq("open")
    third.turnover_of("sale_bic").should eq(M.d("1000"))
    third.turnover_of("service_bic").should eq(M.d("2000"))
    third.turnover_of("bnc").should eq(M.d("1000"))
    bnc = third.contributions.find! { |row| row.category == "bnc" }
    bnc.social_rate.should eq(M.d("26.1"))
    bnc.social.should eq(M.d("261"))
    bnc.cfp.should eq(M.d("2"))
    bnc.flat_tax.should eq(M.d("0"))
    sale = third.contributions.find! { |row| row.category == "sale_bic" }
    sale.social.should eq(M.d("123"))
    third.missing_rates.should be_empty
    periods[1].status.should eq("late")
  end

  it "applique le taux en vigueur au début de la période et le versement libératoire choisi" do
    M.setup(flat_tax: true, periodicity: "monthly")
    Partiduo::Api::Core.create_fiscal_year(M.system, Partiduo::Api::Core::FiscalYearInput.new(year: 2025, start_year: 2025)).value!
    Partiduo::Config.travel_to(Time.utc(2025, 12, 20)) { M.receipt("2025-12-10", "1000", "FEE") }
    december = Api.declarations(M.system, 2025, M.date("2026-01-05")).last
    december.status.should eq("due")
    fee = december.contributions.find! { |row| row.category == "bnc" }
    fee.social_rate.should eq(M.d("24.6"))
    fee.flat_tax_rate.should eq(M.d("2.2"))
    fee.flat_tax.should eq(M.d("22"))
    fee.total.should eq(M.d("270"))

    # Taux paramétré pour 2026 : la période suivante le prend.
    Api.set_parameter(M.actor, Api::ParameterInput.new("rate.social.bnc", M.date("2026-01-01"), M.d("25"))).value!
    Api.declarations(M.system, 2026, M.date("2026-09-27")).first.contributions.find! { |row| row.category == "bnc" }
      .social_rate.should eq(M.d("25"))
  end

  it "signale un taux manquant sans l'inventer" do
    M.setup
    Api.parameters(M.system, "rate.cfp.sale_bic").each { |row| Api.delete_parameter(M.actor, row.id).value! }
    M.receipt("2026-09-01", "100", "SALE")
    third = Api.declarations(M.system, 2026, M.date("2026-09-27"))[2]
    third.missing_rates.should eq(["rate.cfp.sale_bic"])
    third.contributions.find! { |row| row.category == "sale_bic" }.cfp.should eq(M.d("0"))
  end

  it "contrôle les paramètres datés" do
    M.setup
    Api.set_parameter(M.actor, Api::ParameterInput.new("rate.unknown", M.date("2026-01-01"), M.d("1")))
      .error_keys.should eq(["micro.errors.parameter.code.unknown"])
    Api.set_parameter(M.actor, Api::ParameterInput.new("alert.ratio", M.date("2026-01-01"), M.d("-1")))
      .error_keys.should eq(["micro.errors.parameter.value.invalid"])
    Api.set_parameter(M.actor, Api::ParameterInput.new("box.bnc", M.date("2026-01-01")))
      .error_keys.should eq(["micro.errors.parameter.text.required"])
    Api.set_parameter(M.actor, Api::ParameterInput.new("box.bnc", M.date("2026-01-01"), text: "5HQ")).value!.text.should eq("5HQ")
  end

  it "note une déclaration faite et place les échéances dans « À traiter »" do
    M.setup(activity_started_on: M.date("2026-01-15"))
    M.receipt("2026-02-10", "500")
    todo = Api.todo(M.system, M.date("2026-09-27"))
    declarations = todo.select(&.kind.==("declaration"))
    declarations.map { |item| {item.params["from"], item.tone} }.should eq([{"2026-01-01", "gap"}, {"2026-04-01", "gap"}])
    declarations.first.key.should eq("micro.todo.declaration_late")
    declarations.first.params["turnover"].should eq("500.0")

    Api.mark_declared(M.actor, Api::DeclarationInput.new(M.date("2026-02-01"), M.date("2026-04-20")))
      .error_keys.should eq(["micro.errors.declaration.period.invalid"])
    Api.mark_declared(M.actor, Api::DeclarationInput.new(M.date("2026-01-01"), M.date("2026-03-20")))
      .error_keys.should eq(["micro.errors.declaration.before_end"])
    declared = Api.mark_declared(M.actor, Api::DeclarationInput.new(M.date("2026-01-01"), M.date("2026-04-20"), "URSSAF-1")).value!
    declared.status.should eq("declared")
    declared.reference.should eq("URSSAF-1")
    Api.mark_declared(M.actor, Api::DeclarationInput.new(M.date("2026-01-01"), M.date("2026-04-21")))
      .error_keys.should eq(["micro.errors.declaration.already"])
    Api.todo(M.system, M.date("2026-09-27")).count(&.kind.==("declaration")).should eq(1)
    Api.todo(M.system, M.date("2026-10-05")).find!(&.kind.==("declaration")).params["from"].should eq("2026-04-01")
    errors = todo.map { |item| Partiduo::Api::FieldError.base(item.key, item.params) }
    ReferentialSpec.expect_translated(Partiduo::Api::Result(Nil).failure(errors))
  end

  it "donne les montants de la 2042-C-PRO par catégorie, en euros entiers" do
    M.setup
    M.receipt("2026-03-10", "1000.50", "SALE")
    M.receipt("2026-04-10", "2500.49", "SERVICE")
    M.receipt("2026-05-10", "700", "FEE")
    declaration = Api.tax_return(M.system, 2026)
    declaration.flat_tax.should be_false
    declaration.boxes.map { |box| {box.box, box.amount} }.should eq([{"5KO", M.d("1001")}, {"5KP", M.d("2500")}, {"5HQ", M.d("700")}])
    Api.update_settings(M.actor, Api::SettingsInput.new(flat_tax: true)).value!
    Api.tax_return(M.system, 2026).boxes.map(&.box).should eq(%w[5TA 5TB 5TE])
  end

  it "suit les seuils de franchise de TVA et du régime micro, avec alertes" do
    M.setup
    Partiduo::Config.travel_to(Time.utc(2026, 9, 27)) do
      M.receipt("2026-03-10", "31000", "SERVICE")
    end
    view = Api.thresholds(M.system, 2026)
    view.services_turnover.should eq(M.d("31000"))
    vat = view.thresholds.find! { |row| row.kind == "vat" && row.scope == "services" }
    vat.limit.should eq(M.d("37500"))
    vat.ratio.should eq(M.d("82.7"))
    vat.status.should eq("approaching")
    micro = view.thresholds.find! { |row| row.kind == "micro" && row.scope == "services" }
    micro.limit.should eq(M.d("83600"))
    micro.status.should eq("ok")
    view.alerts.map(&.key).should eq(["micro.alerts.vat.approaching"])

    M.receipt("2026-04-10", "11000", "FEE")
    Api.thresholds(M.system, 2026).thresholds.find! { |row| row.kind == "vat" && row.scope == "services" }
      .status.should eq("tolerance_exceeded")
    Api.todo(M.system, M.date("2026-09-27")).map(&.key).should contain("micro.alerts.vat.tolerance_exceeded")

    M.receipt("2026-05-10", "10000", "SALE")
    goods = Api.thresholds(M.system, 2026).thresholds.find! { |row| row.kind == "vat" && row.scope == "goods" }
    goods.turnover.should eq(M.d("52000"))
    goods.status.should eq("ok")
  end

  it "proratise le seuil du régime micro l'année du début d'activité" do
    M.setup(activity_started_on: M.date("2026-07-01"))
    micro = Api.thresholds(M.system, 2026).thresholds.find! { |row| row.kind == "micro" && row.scope == "services" }
    micro.limit.should eq(M.d("42144")) # 83 600 × 184 / 365
    Api.thresholds(M.system, 2027).thresholds.find! { |row| row.kind == "micro" && row.scope == "services" }
      .limit.should eq(M.d("83600"))
  end

  it "change la périodicité par les paramètres" do
    M.setup
    Api.update_settings(M.actor, Api::SettingsInput.new(periodicity: "weekly")).error_keys
      .should eq(["micro.errors.settings.periodicity.invalid"])
    Api.update_settings(M.actor, Api::SettingsInput.new(periodicity: "monthly")).value!
    Api.declarations(M.system, 2026).size.should eq(12)
  end
end
