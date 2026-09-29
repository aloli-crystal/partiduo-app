# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias Api = Partiduo::Api::Liberal
private alias L = LiberalSpec

private def plan(amount : String, duration : Int32, service : String, disposed : String? = nil) : Array({Int32, BigDecimal})
  Partiduo::Liberal::Assets.schedule(L.d(amount), duration, L.date(service), disposed.try { |text| L.date(text) })
end

private def dispose(asset : Api::AssetView, on : String, price : String) : Api::AssetView
  Api.dispose_asset(L.actor, Api::DisposalInput.new(asset.id, L.date(on), L.d(price), "transfer")).value!
end

# Cas limites du module liberal (ADR-007 D6) : saisie, numérotation,
# requêtes du livre-journal, paramètres, amortissements (règle du greffon
# Extension d'origine `amortis` : annuités égales arrondies au centime, la dernière solde
# la base), plus et moins-values, 2035 en déficit, ajustements, empreinte.
describe_module "LIBERAL", Api do
  describe "livre-journal" do
    it "refuse une part non déductible sur une rubrique hors 2035 (prélèvement, emprunt)" do
      L.setup
      %w[WITHDRAWAL LOAN_REPAYMENT].each do |code|
        Api.check_expense(L.actor, L.input("2026-09-01", "100", code, nondeductible_amount: L.d("10"))).error_keys
          .should eq(["liberal.errors.line.nondeductible.excluded"])
      end
      Api.check_expense(L.actor, L.input("2026-09-01", "100", "WITHDRAWAL")).success?.should be_true
      Api.check_expense(L.actor, L.input("2026-09-01", "100", "VEHICLE", nondeductible_amount: L.d("-1")))
        .error_keys.should eq(["liberal.errors.line.nondeductible.invalid"])
      Api.check_expense(L.actor, L.input("2026-09-01", "100", "VEHICLE", nondeductible_amount: L.d("100")))
        .success?.should be_true
      ReferentialSpec.expect_translated(
        Api.check_expense(L.actor, L.input("2026-09-01", "100", "WITHDRAWAL", nondeductible_amount: L.d("1"))))
    end

    it "refuse une nature de l'autre sens et accepte la saisie du jour même" do
      L.setup
      Api.check_expense(L.actor, L.input("2026-09-01", "10", "RECEIPTS")).error_keys
        .should eq(["liberal.errors.line.nature.unknown"])
      Api.check_receipt(L.actor, L.input("2026-09-01", "10", "OFFICE")).error_keys
        .should eq(["liberal.errors.line.nature.unknown"])
      Api.check_receipt(L.actor, L.input("2026-09-27", "10", "RECEIPTS")).success?.should be_true
      Api.check_receipt(L.actor, L.input("2026-09-28", "10", "RECEIPTS")).error_keys
        .should eq(["liberal.errors.line.date.future"])
      Api.check_receipt(L.actor, L.input("2026-09-01", "0", "RECEIPTS")).error_keys
        .should eq(["liberal.errors.line.amount.not_positive"])
      Api.check_receipt(L.actor, L.input("2026-09-01", "10", "RECEIPTS", label: "x" * 256, party_name: "y" * 256))
        .error_keys.should eq(%w[liberal.errors.line.too_long liberal.errors.line.too_long])
    end

    it "numérote chaque registre par année, contre-passation d'une autre année comprise" do
      L.setup(years: [2025, 2026])
      old = L.receipt("2025-12-30", "100")
      old.number.should eq("J2025-00001")
      L.asset("2025-11-02", "900", 3).number.should eq("I2025-00001")
      reversal = Api.reverse_line(L.actor, Api::ReverseInput.new(old.id, L.date("2026-01-04"), "Erreur de patient")).value!
      reversal.number.should eq("J2026-00001")
      reversal.label.should eq("Erreur de patient")
      reversal.reversal?.should be_true
      L.receipt("2025-12-31", "50").number.should eq("J2025-00002")
      L.asset("2026-01-05", "600", 2).number.should eq("I2026-00001")
      Api.reverse_line(L.actor, Api::ReverseInput.new(L.receipt("2026-03-10").id, L.date("2026-03-09"))).error_keys
        .should eq(["liberal.errors.line.reversal.before_line"])
    end

    it "reprend le nom de la fiche et le libellé de la nature quand ils manquent" do
      L.setup
      category = ReferentialSpec.category("PATIENT", "customer")
      card = ReferentialSpec.card(category.id, "Mme Martin")
      ReferentialSpec.capture_events("liberal.receipt.recorded") do |events|
        line = L.receipt("2026-09-01", "45", card_id: card.id, party_name: "  ", label: "")
        line.party_name.should eq("Mme Martin")
        line.card_id.should eq(card.id)
        events.first.payload["label"].should eq(L.nature("RECEIPTS").label)
        events.first.payload["card_id"].should eq(card.id.to_s)
      end
    end

    it "filtre, pagine et totalise le livre-journal sur la requête entière" do
      L.setup(years: [2025, 2026])
      L.receipt("2025-12-15", "10")
      L.receipt("2026-01-10", "100")
      L.receipt("2026-02-10", "200")
      L.expense("2026-02-11", "30", "RENT")
      L.expense("2026-03-12", "40", "OFFICE")
      year = Api::JournalQuery.new(from: L.date("2026-01-01"), to: L.date("2026-12-31"))
      Api.lines(L.system, year).size.should eq(4)
      Api.lines(L.system, year.copy_with(limit: 2, offset: 1)).map(&.amount).should eq([L.d("200"), L.d("30")])
      Api.journal_totals(L.system, year.copy_with(limit: 1)).count.should eq(4)
      Api.lines(L.system, year.copy_with(heading: "rent")).map(&.nature_code).should eq(["RENT"])
      Api.lines(L.system, year.copy_with(nature_id: L.nature("OFFICE").id)).size.should eq(1)
      totals = Api.journal_totals(L.system, year.copy_with(kind: "expense"))
      {totals.count, totals.receipts, totals.expenses}.should eq({2, L.d("0"), L.d("70")})
      Api.journal_totals(L.system).receipts.should eq(L.d("310"))
      Api.lines(L.system, Api::JournalQuery.new(limit: 20_000)).size.should eq(5)
      expect_raises(ArgumentError) { Api.lines(L.system, Api::JournalQuery.new(limit: -1)) }
      expect_raises(ArgumentError) { Api.lines(L.system, Api::JournalQuery.new(offset: -1)) }
      csv = Api.export_journal(L.system, year.copy_with(kind: "receipt"), Api::ExportFormat::Csv)
      String.new(csv.content).lines.size.should eq(3)
    end

    it "lève NotFound pour une ligne, une immobilisation, une ligne de table ou un ajustement inconnus" do
      L.setup
      expect_raises(Partiduo::Api::NotFound) { Api.line(L.system, 999_999_i64) }
      expect_raises(Partiduo::Api::NotFound) { Api.asset(L.system, 999_999_i64) }
      expect_raises(Partiduo::Api::NotFound) { Api.schedule(L.system, 999_999_i64) }
      expect_raises(Partiduo::Api::NotFound) { Api.reverse_line(L.actor, Api::ReverseInput.new(999_999_i64, L.date("2026-09-01"))) }
      expect_raises(Partiduo::Api::NotFound) { Api.reverse_asset(L.actor, Api::ReverseInput.new(999_999_i64, L.date("2026-09-01"))) }
      expect_raises(Partiduo::Api::NotFound) { Api.delete_form_line(L.system, 999_999_i64) }
      expect_raises(Partiduo::Api::NotFound) { Api.delete_adjustment(L.actor, 999_999_i64) }
      expect_raises(Partiduo::Api::NotFound) do
        Api.update_nature(L.system, 999_999_i64, Api::NatureInput.new("X", "X", "receipt", "receipts"))
      end
    end
  end

  describe "paramètres" do
    it "contrôle profession et nature par défaut, et normalise la date de début d'activité" do
      L.setup
      Api.update_settings(L.system, Api::SettingsInput.new(profession: "x" * 101,
        default_nature_id: L.nature("RENT").id)).error_keys.sort!
        .should eq(%w[liberal.errors.line.nature.unknown liberal.errors.line.too_long])
      view = Api.update_settings(L.system, Api::SettingsInput.new(profession: "  Infirmière ",
        activity_started_on: Time.utc(2020, 3, 2, 15, 30))).value!
      view.profession.should eq("Infirmière")
      view.activity_started_on.should eq(Time.utc(2020, 3, 2))
      view.default_nature_id.should be_nil
      Api.tax_return(L.system, 2026).identity.activity_started_on.should eq(Time.utc(2020, 3, 2))
    end

    it "contrôle le code, le sens et la rubrique d'une nature ; modifiable tant qu'elle n'est pas employée" do
      L.setup
      Api.create_nature(L.system, Api::NatureInput.new("1abc", "X", "loan", "rent")).error_keys.sort!
        .should eq(%w[liberal.errors.nature.code.invalid liberal.errors.nature.kind.invalid])
      Api.create_nature(L.system, Api::NatureInput.new("SCM", "X", "receipt", "rent")).error_keys
        .should eq(["liberal.errors.nature.heading.invalid"])
      free = Api.create_nature(L.system, Api::NatureInput.new("PHONE", "Téléphone", "expense", "office")).value!
      changed = Api.update_nature(L.system, free.id, Api::NatureInput.new("TEL", "Téléphone", "expense", "utilities")).value!
      {changed.code, changed.heading}.should eq({"TEL", "utilities"})
      Api.update_nature(L.system, free.id, Api::NatureInput.new("RENT", "Téléphone", "expense", "utilities"))
        .error_keys.should eq(["liberal.errors.nature.code.taken"])
      Api.natures(L.system, "expense", enabled_only: true).map(&.code).should contain("TEL")
    end

    it "contrôle les lignes de la table et garde la ligne du millésime antérieur le plus proche" do
      L.setup
      Api.set_form_line(L.system, Api::FormLineInput.new(2026, "rent", "2035-A", "12345678901", "B" * 11)).error_keys
        .should eq(%w[liberal.errors.line.too_long liberal.errors.line.too_long])
      Api.set_form_line(L.system, Api::FormLineInput.new(2028, "rent", "2035-A", "17", "Z1")).value!
      Api.set_form_line(L.system, Api::FormLineInput.new(2028, "rent", "2035-A", " 18 ", "z2")).value!
      Api.form_lines(L.system).count { |line| line.item == "rent" && line.millesime == 2028 }.should eq(1)
      Api.form_lines(L.system, 2027).find!(&.item.==("rent")).line.should eq("15")
      rent = Api.form_lines(L.system, 2031).find!(&.item.==("rent"))
      {rent.line, rent.box}.should eq({"18", "Z2"})
      Api.form_lines(L.system, 2023).should be_empty
    end
  end

  describe "amortissements" do
    it "amortit en annuités égales, la dernière soldant la base (greffon amortis)" do
      plan("1000", 3, "2026-01-01").sum(L.d("0"), &.[1]).should eq(L.d("1000"))
      plan("100", 7, "2026-01-01").map(&.[1]).should eq(%w[14.29 14.29 14.29 14.29 14.29 14.29 14.26].map { |v| L.d(v) })
      plan("0.01", 3, "2026-01-01").should eq([{2026, L.d("0")}, {2027, L.d("0")}, {2028, L.d("0.01")}])
    end

    it "compte le 31 comme le 30 et le dernier jour de l'année comme un jour" do
      plan("3600", 1, "2026-12-31").should eq([{2026, L.d("10")}, {2027, L.d("3590")}])
      plan("3600", 1, "2026-01-31").should eq([{2026, L.d("3310")}, {2027, L.d("290")}])
      plan("3600", 1, "2026-01-30").should eq(plan("3600", 1, "2026-01-31"))
    end

    it "arrête le plan à la cession, même avant la mise en service ou après la fin du plan" do
      plan("3000", 3, "2026-04-01", "2026-03-15").should be_empty
      plan("3000", 3, "2026-04-01", "2030-06-30").should eq(plan("3000", 3, "2026-04-01"))
      plan("3000", 3, "2026-04-01", "2029-03-31").should eq([{2026, L.d("750")}, {2027, L.d("1000")},
                                                             {2028, L.d("1000")}, {2029, L.d("250")}])
      plan("3000", 3, "2026-04-01", "2026-04-01").should eq([{2026, L.d("2.78")}])
    end

    it "amortit depuis la mise en service, non depuis l'acquisition, et arrondit le taux" do
      L.setup
      asset = L.asset("2026-02-10", "7000", 7, service_on: L.date("2026-07-01"))
      asset.rate.should eq(L.d("14.29"))
      asset.service_on.should eq(L.date("2026-07-01"))
      Api.schedule(L.system, asset.id).first.should eq({2026, L.d("500")})
      land = L.asset("2026-02-11", "20000", 0, category: "land")
      land.rate.should be_nil
      Api.schedule(L.system, land.id).should be_empty
      Api.check_asset(L.actor, Api::AssetInput.new(label: "Clientèle", category: "goodwill",
        acquired_on: L.date("2026-02-11"), amount: L.d("1"), duration_years: 5, method: "cash")).error_keys
        .should eq(["liberal.errors.asset.duration.not_depreciable"])
      rows = Api.depreciation(L.system, 2026).index_by(&.number)
      rows[land.number].year_amount.should eq(L.d("0"))
      rows[land.number].net_value.should eq(L.d("20000"))
      Api.assets(L.system, 2025).should be_empty
      Api.assets(L.system, 2026).size.should eq(2)
    end

    it "refuse une cession avant l'acquisition, à venir, à prix invalide ou en période close" do
      L.setup
      asset = L.asset("2026-03-01", "1000", 5)
      Api.dispose_asset(L.actor, Api::DisposalInput.new(asset.id, L.date("2026-02-28"), L.d("1.001"), "gold",
        "r" * 101)).error_keys.sort!.should eq(%w[
        liberal.errors.disposal.before_acquisition liberal.errors.disposal.price.invalid
        liberal.errors.line.method.invalid liberal.errors.line.too_long
      ])
      Api.dispose_asset(L.actor, Api::DisposalInput.new(asset.id, L.date("2026-10-01"), L.d("-1"), "cash")).error_keys
        .sort!.should eq(%w[liberal.errors.disposal.price.invalid liberal.errors.line.date.future])
      Api.dispose_asset(L.actor, Api::DisposalInput.new(999_999_i64, L.date("2026-04-01"), L.d("1"), "cash")).error_keys
        .should eq(["liberal.errors.disposal.asset.unknown"])
      Api.reverse_asset(L.actor, Api::ReverseInput.new(asset.id, L.date("2026-02-01"))).error_keys
        .should eq(["liberal.errors.line.reversal.before_line"])
      %w[2026-01-15 2026-02-15 2026-03-15 2026-04-15].each { |day| L.close_period(day) }
      Api.asset(L.system, asset.id).locked.should be_true
      Api.dispose_asset(L.actor, Api::DisposalInput.new(asset.id, L.date("2026-04-15"), L.d("1"), "cash")).error_keys
        .should eq(["liberal.errors.line.date.closed_period"])
      Api.reverse_asset(L.actor, Api::ReverseInput.new(asset.id, L.date("2026-05-01"))).success?.should be_true
      asset = L.asset("2026-05-01", "1000", 5)
      # Une cession à prix nul (mise au rebut) est admise.
      dispose(asset, "2026-05-02", "0").disposal.try(&.price).should eq(L.d("0"))
    end

    it "classe une moins-value à court terme et le seuil des deux ans jour pour jour" do
      L.setup(years: [2024, 2025, 2026])
      loss = L.asset("2026-04-01", "3000", 3)
      dispose(loss, "2026-06-30", "1000")
      before = L.asset("2024-03-01", "1000", 5, category: "equipment")
      dispose(before, "2026-02-28", "1100")
      exact = L.asset("2024-03-01", "1000", 5, category: "equipment")
      dispose(exact, "2026-03-01", "1100")
      young_land = L.asset("2025-06-01", "50000", 0, category: "land")
      dispose(young_land, "2026-05-01", "52000")
      old_loss = L.asset("2024-01-02", "2000", 4, category: "furniture")
      dispose(old_loss, "2026-07-01", "100")

      results = Api.tax_return(L.system, 2026).disposals.index_by(&.number)
      results[loss.number].depreciation.should eq(L.d("250"))
      {results[loss.number].short_term, results[loss.number].long_term}.should eq({L.d("-1750"), L.d("0")})
      {results[before.number].short_term, results[before.number].long_term}.should eq({L.d("498.89"), L.d("0")})
      {results[exact.number].short_term, results[exact.number].long_term}.should eq({L.d("400.56"), L.d("100")})
      {results[young_land.number].short_term, results[young_land.number].long_term}.should eq({L.d("2000"), L.d("0")})
      # Bien amortissable détenu plus de deux ans : moins-value à court terme.
      old = results[old_loss.number]
      old.depreciation.should eq(L.d("1250"))
      {old.short_term, old.long_term}.should eq({L.d("-650"), L.d("0")})
      old.gain.should eq(L.d("-650"))

      view = Api.tax_return(L.system, 2026)
      view.amount("short_term_gains").should eq(L.d("2899"))
      view.amount("short_term_losses").should eq(L.d("2400"))
      view.amount("long_term_gains").should eq(L.d("100"))
      view.amount("long_term_losses").should eq(L.d("0"))
      view.amount("disposals_price").should eq(L.d("55300"))
    end
  end

  describe "2035" do
    it "dégage un déficit et reporte les ajustements de toutes sortes" do
      L.setup
      L.receipt("2026-02-01", "1000.50")
      L.receipt("2026-02-02", "400", "OTHER_GAINS")
      L.expense("2026-02-03", "3000", "OFFICE")
      L.expense("2026-02-04", "500", "LOAN_REPAYMENT")
      L.receipt("2026-02-05", "8000", "LOAN_RECEIVED")
      {
        "reintegration" => "10", "deduction" => "100", "scm_profit" => "300", "scm_loss" => "40",
        "establishment_costs" => "50", "provision" => "20",
      }.each do |kind, amount|
        Api.add_adjustment(L.actor, Api::AdjustmentInput.new(2026, kind, kind, L.d(amount))).value!
      end
      view = Api.tax_return(L.system, 2026)
      {
        "receipts" => "1001", "other_gains" => "400", "total_receipts" => "1401", "total_expenses" => "3000",
        "excess" => "0", "shortfall" => "1599", "reintegrations" => "10", "scm_profit" => "300",
        "total_additions" => "310", "deductions" => "120", "scm_loss" => "40", "establishment_costs" => "50",
        "provision" => "20", "total_subtractions" => "1809", "profit" => "0", "loss" => "1499",
      }.each { |item, amount| {item, view.amount(item)}.should eq({item, L.d(amount)}) }
      view.lines.map(&.item).should_not contain("loan_received")
      view.lines.map(&.item).should_not contain("loan_repayment")
      view.controls.select(&.error?).should be_empty
    end

    it "réintègre la part non déductible, contre-passations comprises" do
      L.setup
      car = L.expense("2026-02-01", "1000", "VEHICLE", nondeductible_amount: L.d("300"))
      L.expense("2026-02-02", "200", "VEHICLE", nondeductible_amount: L.d("50.40"))
      Api.reverse_line(L.actor, Api::ReverseInput.new(car.id, L.date("2026-02-03"))).value!
      view = Api.tax_return(L.system, 2026)
      view.amount("vehicle").should eq(L.d("200"))
      view.amount("reintegrations").should eq(L.d("50"))
    end

    it "arrondit chaque rubrique à l'euro le plus proche, demi-euro au-dessus" do
      L.setup
      L.receipt("2026-02-01", "100.50")
      L.expense("2026-02-02", "10.49", "RENT")
      L.expense("2026-02-03", "10.50", "OFFICE")
      view = Api.tax_return(L.system, 2026)
      {view.amount("receipts"), view.amount("rent"), view.amount("office")}.should eq({L.d("101"), L.d("10"), L.d("11")})
      view.amount("total_expenses").should eq(L.d("21"))
      view.amount("excess").should eq(L.d("80"))
    end

    it "bloque une année sans ligne au millésime, un poste sans case, et ne publie que les cases situées et non nulles" do
      L.setup(years: [2023, 2026])
      L.receipt("2023-05-01", "100")
      old = Api.tax_return(L.system, 2023)
      old.lines.none?(&.mapped).should be_true
      old.ready?.should be_false
      old.boxes.should be_empty

      L.receipt("2026-05-01", "100")
      Api.set_form_line(L.system, Api::FormLineInput.new(2026, "receipts", "2035-A", "1", "")).value!
      view = Api.tax_return(L.system, 2026)
      view.boxes.values.flat_map(&.keys).should_not contain("")
      view.boxes.values.flat_map(&.values).none?(&.zero?).should be_true
      # Sans case, la recette ne serait pas transmise : dépôt bloqué.
      view.ready?.should be_false
      control = view.controls.find!(&.key.==("liberal.controls.box_missing"))
      control.params["year"].should eq("2026")
      I18n.with_locale("fr") { I18n.t(control.key, control.params).should contain("Recettes") }
      Api.set_form_line(L.system, Api::FormLineInput.new(2026, "receipts", "2035-A", "1", "AA")).value!
      Api.tax_return(L.system, 2026).ready?.should be_true
    end

    it "garde la même empreinte tant que rien ne change, en change sinon" do
      L.setup
      L.receipt("2026-02-01", "100")
      first = Api.tax_return(L.system, 2026).fingerprint
      Api.tax_return(L.system, 2026).fingerprint.should eq(first)
      # Un centime de plus ne change pas l'euro entier : même déclaration.
      L.receipt("2026-02-02", "0.01")
      Api.tax_return(L.system, 2026).fingerprint.should eq(first)
      Api.update_settings(L.system, Api::SettingsInput.new(profession: "Ostéopathe")).value!
      second = Api.tax_return(L.system, 2026).fingerprint
      second.should_not eq(first)
      L.receipt("2026-02-03", "1")
      Api.tax_return(L.system, 2026).fingerprint.should_not eq(second)
      Api.tax_return(L.system, 2025).fingerprint.should_not eq(Api.tax_return(L.system, 2026).fingerprint)
    end

    it "signale la profession absente (avertissement non bloquant)" do
      L.setup(profession: "")
      L.receipt("2026-02-01", "100")
      view = Api.tax_return(L.system, 2026)
      control = view.controls.find!(&.key.==("liberal.controls.profession_missing"))
      control.error?.should be_false
      view.ready?.should be_true
    end
  end
end

# Relecture de clôture du lot L : cases en double, millésimes figés, fiche
# lue avec l'acteur, paramètres, plafond des véhicules, cession seule.
describe_module "LIBERAL", "#{Api} — relecture de clôture" do
  it "refuse une case déjà prise par un autre poste du même formulaire, millésimes suivants compris" do
    L.setup
    receipts = Api.form_lines(L.system, 2026).find!(&.item.==("receipts"))
    taken = Api.set_form_line(L.system, Api::FormLineInput.new(2026, "rent", receipts.form, "15", receipts.box.downcase))
    taken.error_keys.should eq(["liberal.errors.form_line.box.taken"])
    ReferentialSpec.expect_translated(taken)
    # Autre formulaire : la case est libre.
    Api.set_form_line(L.system, Api::FormLineInput.new(2026, "assets_cost", "2035", "1", receipts.box)).success?
      .should be_true
    # Une ligne 2030 de `rent` en Z9 : une ligne 2027 de `office` en Z9 serait en double à partir de 2030.
    Api.set_form_line(L.system, Api::FormLineInput.new(2030, "rent", "2035-A", "15", "Z9")).value!
    Api.set_form_line(L.system, Api::FormLineInput.new(2027, "office", "2035-A", "23", "Z9")).error_keys
      .should eq(["liberal.errors.form_line.box.taken"])
    # Redéfinie avant 2030, la ligne de `office` ne croise plus celle de `rent`.
    Api.set_form_line(L.system, Api::FormLineInput.new(2029, "office", "2035-A", "23", "Z8")).value!
    Api.set_form_line(L.system, Api::FormLineInput.new(2027, "office", "2035-A", "23", "Z9")).success?.should be_true
  end

  it "bloque la 2035 dont deux postes tombent dans la même case (table modifiée hors du contrat)" do
    L.setup
    L.receipt("2026-02-01", "100")
    L.expense("2026-02-02", "40", "RENT")
    box = Api.form_lines(L.system, 2026).find!(&.item.==("receipts")).box
    Partiduo::Liberal::FormLine.create!(millesime: 2026, item: "rent", form: "2035-A", line: "15", box: box)
    view = Api.tax_return(L.system, 2026)
    control = view.controls.find!(&.key.==("liberal.controls.box_duplicate"))
    control.error?.should be_true
    control.params["box"].should eq(box)
    view.ready?.should be_false
    view.controls.map(&.key).should_not contain("liberal.controls.unbalanced")
  end

  it "fige les lignes d'un millésime couvert par une année close" do
    L.setup(years: [2025, 2026])
    Api.set_form_line(L.system, Api::FormLineInput.new(2025, "rent", "2035-A", "15", "Z7")).value!
    L.close_year(2025)
    line = Api.form_lines(L.system).find! { |row| row.item == "rent" && row.millesime == 2025 }
    Api.delete_form_line(L.system, line.id).error_keys.should eq(["liberal.errors.form_line.year.closed"])
    Api.set_form_line(L.system, Api::FormLineInput.new(2024, "rent", "2035-A", "15", "Z6")).error_keys
      .should eq(["liberal.errors.form_line.year.closed"])
    # La correction passe par une ligne au millésime suivant.
    added = Api.set_form_line(L.system, Api::FormLineInput.new(2026, "rent", "2035-A", "15", "Z6")).value!
    Api.delete_form_line(L.system, added.id).success?.should be_true
  end

  it "lit la fiche avec l'acteur : sans droit sur les fiches, elle est « inconnue »" do
    L.setup
    card = ReferentialSpec.card(ReferentialSpec.category("PATIENT", "customer").id, "Mme Martin")
    blind = Partiduo::Api::Actor.user(9_i64, %w[liberal.register.read liberal.register.write])
    Api.check_receipt(blind, L.input("2026-09-01", "45", "RECEIPTS", card_id: card.id)).error_keys
      .should eq(["liberal.errors.line.card.unknown"])
    Api.check_receipt(L.actor, L.input("2026-09-01", "45", "RECEIPTS", card_id: card.id)).success?.should be_true
  end

  it "ne crée pas les paramètres à la lecture et refuse une nature par défaut désactivée" do
    L.setup
    Partiduo::Liberal::Settings.all.delete
    Api.settings(L.system).should eq(Api::SettingsView.new("", nil, nil))
    Partiduo::Liberal::Settings.all.count.should eq(0)
    Api.tax_return(L.system, 2026).identity.profession.should eq("")
    Partiduo::Liberal::Settings.all.count.should eq(0)
    nature = L.nature("RECEIPTS")
    Api.update_nature(L.system, nature.id, Api::NatureInput.new(nature.code, nature.label, "receipt", "receipts",
      enabled: false)).value!
    Api.update_settings(L.system, Api::SettingsInput.new(default_nature_id: nature.id)).error_keys
      .should eq(["liberal.errors.line.nature.unknown"])
    Api.update_settings(L.system, Api::SettingsInput.new(profession: "Ostéopathe")).value!
    Partiduo::Liberal::Settings.all.count.should eq(1)
  end

  it "signale un véhicule au-delà du plafond d'amortissement (avertissement)" do
    L.setup
    L.asset("2026-01-01", "25000", 5, "vehicle")
    L.asset("2026-01-01", "25000", 5, "equipment")
    view = Api.tax_return(L.system, 2026)
    warnings = view.controls.select(&.key.==("liberal.controls.vehicle_depreciation_ceiling"))
    warnings.size.should eq(1)
    warnings.first.error?.should be_false
    warnings.first.params["ceiling"].should eq("9900")
    L.asset("2026-02-01", "8000", 5, "vehicle")
    Api.tax_return(L.system, 2026).controls.count(&.key.==("liberal.controls.vehicle_depreciation_ceiling"))
      .should eq(1)
  end

  it "rend la plus ou moins-value d'une seule cession, comme la 2035" do
    L.setup
    asset = L.asset("2026-01-01", "3000", 3)
    Api.disposal_result(L.system, asset.id).should be_nil
    dispose(asset, "2026-07-01", "2500")
    result = Api.disposal_result(L.system, asset.id) || raise "cession absente"
    result.should eq(Api.tax_return(L.system, 2026).disposals.first)
    result.gain.should eq(L.d("2500") - result.net_value)
  end
end
