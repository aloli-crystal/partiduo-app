# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias Api = Partiduo::Api::Liberal
private alias L = LiberalSpec

private def plan(amount : String, duration : Int32, service : String, disposed : String? = nil) : Array({Int32, BigDecimal})
  Partiduo::Liberal::Assets.schedule(L.d(amount), duration, L.date(service), disposed.try { |text| L.date(text) })
end

# ADR-007 D6 : registre des immobilisations et des amortissements
# linéaires, tableau de la 2035-B, plus et moins-values de cession.
describe_module "LIBERAL", Api do
  it "calcule l'amortissement linéaire au prorata temporis (année de 360 jours)" do
    plan("3000", 3, "2026-04-01").should eq([{2026, L.d("750")}, {2027, L.d("1000")}, {2028, L.d("1000")},
                                             {2029, L.d("250")}])
    plan("1000", 3, "2026-01-01").should eq([{2026, L.d("333.33")}, {2027, L.d("333.33")}, {2028, L.d("333.34")}])
    plan("3000", 3, "2026-04-01", "2027-06-30").should eq([{2026, L.d("750")}, {2027, L.d("500")}])
    plan("3000", 3, "2026-04-01", "2026-06-30").should eq([{2026, L.d("250")}])
    plan("5000", 0, "2026-01-01").should be_empty
  end

  it "inscrit une immobilisation, publie liberal.asset.recorded et dresse la 2035-B" do
    L.setup(years: [2026, 2027])
    ReferentialSpec.capture_events("liberal.asset.recorded") do |events|
      asset = L.asset("2026-04-01", "3000", 3, service_on: L.date("2026-04-01"))
      asset.number.should eq("I2026-00001")
      asset.rate.should eq(L.d("33.33"))
      events.size.should eq(1)
      events.first.payload["operation"].should eq("acquisition")
      events.first.payload["category"].should eq("office")
      L.d(events.first.payload["amount"]).should eq(L.d("3000"))
    end
    rows = Api.depreciation(L.system, 2027)
    rows.size.should eq(1)
    rows.first.prior.should eq(L.d("750"))
    rows.first.year_amount.should eq(L.d("1000"))
    rows.first.net_value.should eq(L.d("1250"))
    Api.schedule(L.system, rows.first.asset_id).size.should eq(4)
  end

  it "refuse une immobilisation invalide" do
    L.setup
    input = Api::AssetInput.new(label: " ", category: "yacht", acquired_on: L.date("2026-12-01"), amount: L.d("0"),
      duration_years: 60, method: "barter", service_on: L.date("2026-11-01"))
    Api.record_asset(L.actor, input).error_keys.sort!.should eq(%w[
      liberal.errors.asset.category.invalid liberal.errors.asset.duration.invalid liberal.errors.asset.label.blank
      liberal.errors.asset.service_before_acquisition liberal.errors.line.amount.not_positive
      liberal.errors.line.date.future liberal.errors.line.method.invalid
    ].sort)
    land = input.copy_with(label: "Terrain", category: "land", acquired_on: L.date("2026-01-10"), amount: L.d("50000"),
      duration_years: 10, method: "transfer", service_on: nil)
    Api.check_asset(L.actor, land).error_keys.should eq(["liberal.errors.asset.duration.not_depreciable"])
  end

  it "contre-passe une immobilisation la même année seulement, jamais après sa cession" do
    L.setup(years: [2026, 2027])
    wrong = L.asset("2026-02-01", "900", 3)
    Api.reverse_asset(L.actor, Api::ReverseInput.new(wrong.id, L.date("2027-01-05"))).error_keys
      .should contain("liberal.errors.asset.reversal.other_year")
    reversal = Api.reverse_asset(L.actor, Api::ReverseInput.new(wrong.id, L.date("2026-02-03"))).value!
    reversal.amount.should eq(L.d("-900"))
    Api.asset(L.system, wrong.id).live?.should be_false
    Api.depreciation(L.system, 2026).should be_empty
    Api.dispose_asset(L.actor, Api::DisposalInput.new(wrong.id, L.date("2026-03-01"), L.d("10"), "cash")).error_keys
      .should eq(["liberal.errors.disposal.asset.unknown"])

    sold = L.asset("2026-02-01", "900", 3)
    Api.dispose_asset(L.actor, Api::DisposalInput.new(sold.id, L.date("2026-08-01"), L.d("500"), "cheque")).value!
    Api.reverse_asset(L.actor, Api::ReverseInput.new(sold.id, L.date("2026-08-02"))).error_keys
      .should eq(["liberal.errors.asset.reversal.disposed"])
    Api.dispose_asset(L.actor, Api::DisposalInput.new(sold.id, L.date("2026-08-02"), L.d("1"), "cheque")).error_keys
      .should eq(["liberal.errors.disposal.asset.already"])
  end

  it "détermine les plus et moins-values à court et à long terme" do
    L.setup(years: [2024, 2025, 2026, 2027])
    Partiduo::Config.travel_to(Time.utc(2028, 2, 1, 9)) { disposals_2027 }
  end
end

private def disposals_2027 : Nil
  # Détention de moins de deux ans : tout à court terme.
  recent = L.asset("2026-04-01", "3000", 3)
  Api.dispose_asset(L.actor, Api::DisposalInput.new(recent.id, L.date("2027-06-30"), L.d("2200"), "transfer")).value!
  # Bien amortissable détenu plus de deux ans : court terme à hauteur des
  # amortissements, long terme au-delà.
  old = L.asset("2024-01-01", "1200", 4, category: "equipment")
  Api.dispose_asset(L.actor, Api::DisposalInput.new(old.id, L.date("2027-07-01"), L.d("1300"), "transfer")).value!
  # Terrain détenu plus de deux ans : tout à long terme.
  land = L.asset("2024-01-10", "50000", 0, category: "land")
  Api.dispose_asset(L.actor, Api::DisposalInput.new(land.id, L.date("2027-03-01"), L.d("48000"), "transfer")).value!

  results = Api.tax_return(L.system, 2027).disposals.index_by(&.number)
  first = results[recent.number]
  first.depreciation.should eq(L.d("1250"))
  first.net_value.should eq(L.d("1750"))
  first.short_term.should eq(L.d("450"))
  first.long_term.should eq(L.d("0"))
  second = results[old.number]
  second.depreciation.should eq(L.d("1050.83"))
  second.short_term.should eq(L.d("1050.83"))
  second.long_term.should eq(L.d("100"))
  third = results[land.number]
  third.short_term.should eq(L.d("0"))
  third.long_term.should eq(L.d("-2000"))

  view = Api.tax_return(L.system, 2027)
  view.amount("short_term_gains").should eq(L.d("1501"))
  view.amount("long_term_gains").should eq(L.d("100"))
  view.amount("long_term_losses").should eq(L.d("2000"))
  view.amount("disposals_price").should eq(L.d("51500"))
  # L'année suivante, les biens cédés ne figurent plus au tableau.
  Api.depreciation(L.system, 2028).should be_empty
end
