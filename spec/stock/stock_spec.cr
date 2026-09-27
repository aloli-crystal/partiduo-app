# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias Api = Partiduo::Api::Stock

private def d(text : String) : BigDecimal
  BigDecimal.new(text)
end

private def date(text : String) : Time
  StockSpec.date(text)
end

private def system : Partiduo::Api::Actor
  Partiduo::Api::Actor.system
end

describe "Stock : accès (ADR-006 D2)" do
  it "refuse l'appel si le module est inactif, et l'acteur sans permission" do
    with_active_modules("accounting") do
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.repositories(system) }
    end
    with_active_modules("invoicing,stock") do
      expect_raises(Partiduo::Api::Forbidden) { Api.repositories(actor_with) }
      expect_raises(Partiduo::Api::Forbidden) do
        Api.create_repository(actor_with(Api::READ), Api::RepositoryInput.new("Dépôt"))
      end
      Api.repositories(actor_with(Api::READ)).should eq([] of Api::RepositoryView)
    end
  end

  it "exige la Facturation ou la Comptabilité (depends_on_any)" do
    Partiduo::Modules["STOCK"].depends_on_any.should eq([%w[INVOICING ACCOUNTING]])
  end
end

describe_module "STOCK", "Stock : dépôts, articles suivis, mouvements" do
  describe "dépôts" do
    it "crée, contrôle et modifie ; le premier devient le dépôt par défaut" do
      setup = StockSpec.setup
      setup.main.default.should be_true
      setup.main.country_code.should eq("FR")
      setup.annex.default.should be_false
      Api.settings(system).default_repository_id.should eq(setup.main.id)

      duplicate = Api.create_repository(system, Api::RepositoryInput.new("entrepôt PRINCIPAL"))
      duplicate.error_keys.should eq(["stock.errors.repository.name_taken"])
      ReferentialSpec.expect_translated(duplicate)
      Api.check_repository(system, Api::RepositoryInput.new(" ", country_code: "FRA")).error_keys
        .should eq(["stock.errors.repository.name_required", "stock.errors.repository.country_invalid"])

      updated = Api.update_repository(system, setup.annex.id, Api::RepositoryInput.new("Annexe Est", phone: "02 40 00 00 00"))
      updated.value!.name.should eq("Annexe Est")
      Api.update_settings(system, Api::SettingsInput.new(setup.annex.id)).value!.default_repository_name.should eq("Annexe Est")
      Api.update_settings(system, Api::SettingsInput.new(999_999_i64)).error_keys
        .should eq(["stock.errors.settings.repository_unknown"])
    end

    it "refuse de supprimer un dépôt qui porte des mouvements" do
      setup = StockSpec.setup
      StockSpec.change(setup.main, "2026-03-01", {setup.screws, "10", nil})
      Api.delete_repository(system, setup.main.id).error_keys.should eq(["stock.errors.repository.in_use"])
      Api.repository(system, setup.main.id).movements_count.should eq(1)
      Api.delete_repository(system, setup.annex.id).success?.should be_true
      expect_raises(Partiduo::Api::NotFound) { Api.repository(system, setup.annex.id) }
    end
  end

  describe "articles suivis" do
    it "suit une fiche article, sous son quick code ou un code stock commun" do
      setup = StockSpec.setup
      Api.items(system).map { |item| {item.card_code, item.stock_code} }.should eq([{"BOULON", "BOUL-01"}, {"VIS", "VIS"}])
      shared = Api.track_item(system, Api::ItemInput.new(setup.service.id, " boul-01 ")).value!
      shared.stock_code.should eq("BOUL-01")
      Api.item(system, setup.service.id).should_not be_nil
      Api.untrack_item(system, setup.service.id).success?.should be_true
      Api.item(system, setup.service.id).should be_nil
    end

    it "refuse une fiche qui n'est pas un article" do
      StockSpec.setup
      customers = ReferentialSpec.category("CLIENTS", "customer")
      customer = ReferentialSpec.card(customers.id, "Client")
      result = Api.track_item(system, Api::ItemInput.new(customer.id))
      result.error_keys.should eq(["stock.errors.item.not_an_item"])
      Api.track_item(system, Api::ItemInput.new(999_999_i64)).error_keys.should eq(["stock.errors.item.card_unknown"])
      ReferentialSpec.expect_translated(result)
    end
  end

  describe "opérations manuelles" do
    it "inscrit entrées et sorties et calcule l'état entre deux dates" do
      setup = StockSpec.setup
      change = StockSpec.change(setup.main, "2026-02-10", {setup.screws, "100", "0.25"}, {setup.bolts, "40", nil},
        comment: "Stock initial")
      change.kind.should eq("change")
      change.movements.map { |movement| {movement.stock_code, movement.direction, movement.quantity} }
        .should eq([{"VIS", "in", d("100")}, {"BOUL-01", "in", d("40")}])
      StockSpec.change(setup.main, "2026-03-05", {setup.screws, "-30", nil})
      StockSpec.change(setup.annex, "2026-03-06", {setup.screws, "5", nil})

      StockSpec.quantity(setup.screws).should eq(d("75"))
      StockSpec.quantity(setup.screws, repository: setup.main).should eq(d("70"))
      StockSpec.quantity(setup.screws, "2026-03-04").should eq(d("100"))

      state = Api.state(system, Api::StateQuery.new(date("2026-03-01"), date("2026-03-31")))
      screws = StockSpec.row(state, setup.main, "VIS")
      {screws.opening, screws.quantity_in, screws.quantity_out, screws.closing}.should eq({d("100"), d("0"), d("30"), d("70")})
      screws.card_names.should eq(["Vis inox"])
      StockSpec.row(state, setup.annex, "VIS").closing.should eq(d("5"))
      Api.state(system, Api::StateQuery.new(date("2026-03-01"), date("2026-03-31"), setup.annex.id)).rows.size.should eq(1)
    end

    it "contrôle les lignes" do
      setup = StockSpec.setup
      input = Api::ChangeInput.new(setup.main.id, date("2026-03-01"), [
        Api::ChangeLineInput.new(setup.service.id, d("1")),
        Api::ChangeLineInput.new(setup.screws.id, d("0")),
        Api::ChangeLineInput.new(setup.screws.id, d("1.00001")),
        Api::ChangeLineInput.new(setup.screws.id, d("-2"), d("3")),
      ])
      result = Api.record_change(system, input)
      result.errors.map { |error| {error.field, error.key} }.should eq([
        {"lines[0].card_id", "stock.errors.change.not_tracked"},
        {"lines[1].quantity", "stock.errors.change.quantity_zero"},
        {"lines[2].quantity", "stock.errors.change.quantity_scale"},
        {"lines[3].unit_cost", "stock.errors.change.cost_on_exit"},
      ])
      ReferentialSpec.expect_translated(result)
      Api.check_change(system, Api::ChangeInput.new(999_i64, date("2026-03-01"), [] of Api::ChangeLineInput)).error_keys
        .should eq(["stock.errors.change.repository_unknown", "stock.errors.change.lines_required"])
      Api.movements(system).should be_empty
    end

    it "supprime une opération et ses mouvements, sauf en période close" do
      setup = StockSpec.setup
      year = ReferentialSpec.fiscal_year(2026)
      january = StockSpec.change(setup.main, "2026-01-15", {setup.screws, "10", nil})
      march = StockSpec.change(setup.main, "2026-03-15", {setup.screws, "5", nil})
      period = Partiduo::Api::Core.periods(system, year.id).find!(&.includes?(date("2026-01-15")))
      Partiduo::Api::Core.close_period(system, period.id).success?.should be_true

      Api.delete_change(system, january.id).error_keys.should eq(["stock.errors.change.closed_period"])
      StockSpec.change(setup.main, "2026-03-20", {setup.screws, "1", nil})
      closed = Api.record_change(system, Api::ChangeInput.new(setup.main.id, date("2026-01-20"),
        [Api::ChangeLineInput.new(setup.screws.id, d("1"))]))
      closed.error_keys.should eq(["stock.errors.change.closed_period"])

      Api.delete_change(system, march.id).success?.should be_true
      expect_raises(Partiduo::Api::NotFound) { Api.change(system, march.id) }
      StockSpec.quantity(setup.screws).should eq(d("11"))
      Api.changes(system).map(&.date).should eq([date("2026-01-15"), date("2026-03-20")])
    end
  end

  describe "inventaire" do
    it "propose les quantités théoriques et inscrit les écarts comptés" do
      setup = StockSpec.setup
      StockSpec.change(setup.main, "2026-06-01", {setup.screws, "100", "0.20"}, {setup.bolts, "10", nil})
      StockSpec.change(setup.main, "2026-06-10", {setup.screws, "-20", nil})
      proposal = Api.inventory_proposal(system, setup.main.id, date("2026-06-30"))
      proposal.map { |line| {line.stock_code, line.quantity} }.should eq([{"BOUL-01", d("10")}, {"VIS", d("80")}])

      inventory = Api.record_inventory(system, Api::InventoryInput.new(setup.main.id, date("2026-06-30"), [
        Api::InventoryLineInput.new(setup.screws.id, d("78")),
        Api::InventoryLineInput.new(setup.bolts.id, d("12"), d("1.50")),
      ], "Inventaire 2026")).value!
      inventory.kind.should eq("inventory")
      inventory.movements.map { |movement| {movement.stock_code, movement.direction, movement.quantity, movement.unit_cost} }
        .should eq([{"VIS", "out", d("2"), nil}, {"BOUL-01", "in", d("2"), d("1.5")}])
      StockSpec.quantity(setup.screws).should eq(d("78"))
      StockSpec.quantity(setup.bolts).should eq(d("12"))

      # Inventaire identique : aucun écart, aucun mouvement.
      Api.record_inventory(system, Api::InventoryInput.new(setup.main.id, date("2026-07-01"), [
        Api::InventoryLineInput.new(setup.screws.id, d("78")),
      ])).value!.movements.should be_empty
    end

    it "refuse un code compté deux fois et une quantité négative" do
      setup = StockSpec.setup
      Api.track_item(system, Api::ItemInput.new(setup.service.id, "VIS")).value!
      result = Api.record_inventory(system, Api::InventoryInput.new(setup.main.id, date("2026-06-30"), [
        Api::InventoryLineInput.new(setup.screws.id, d("1")),
        Api::InventoryLineInput.new(setup.service.id, d("1")),
        Api::InventoryLineInput.new(setup.bolts.id, d("-1")),
      ]))
      result.error_keys.should eq(["stock.errors.inventory.code_twice", "stock.errors.inventory.counted_negative"])
      ReferentialSpec.expect_translated(result)
    end
  end

  describe "historique, valorisation, exports" do
    it "filtre l'historique et valorise au coût moyen pondéré" do
      setup = StockSpec.setup
      StockSpec.change(setup.main, "2026-01-10", {setup.screws, "100", "0.20"})
      StockSpec.change(setup.main, "2026-02-10", {setup.screws, "50", "0.35"}, {setup.bolts, "8", nil})
      StockSpec.change(setup.annex, "2026-02-11", {setup.screws, "10", nil})
      StockSpec.change(setup.main, "2026-03-10", {setup.screws, "-60", nil})

      Api.count_movements(system).should eq(5)
      Api.movements(system, Api::MovementQuery.new(direction: "out")).map(&.quantity).should eq([d("60")])
      Api.movements(system, Api::MovementQuery.new(stock_code: "vis", repository_id: setup.main.id)).size.should eq(3)
      Api.movements(system, Api::MovementQuery.new(date_from: date("2026-02-01"), date_to: date("2026-02-28"),
        limit: 1, offset: 1)).map(&.stock_code).should eq(["BOUL-01"])

      # (100 × 0,20 + 50 × 0,35) ÷ 150 = 0,25
      valuation = Api.valuation(system, date("2026-03-31"))
      main = valuation.rows.find! { |row| row.repository_id == setup.main.id && row.stock_code == "VIS" }
      {main.quantity, main.unit_cost, main.value}.should eq({d("90"), d("0.25"), d("22.5")})
      annex = valuation.rows.find! { |row| row.repository_id == setup.annex.id }
      annex.value.should eq(d("2.5"))
      valuation.rows.find! { |row| row.stock_code == "BOUL-01" }.value.should be_nil
      valuation.total.should eq(d("25"))

      # Au 31 janvier, seule la première entrée est valorisée.
      Api.valuation(system, date("2026-01-31")).rows.first.unit_cost.should eq(d("0.2"))

      csv = String.new(Api.export_valuation(system, date("2026-03-31")).content)
      csv.lines.first.should eq("Dépôt;Code stock;Article;Quantité;Coût unitaire;Valeur")
      csv.should contain("Entrepôt principal;VIS;Vis inox;90.0000;0.2500;22.50")
      csv.lines.last.should eq("Total;;;;;25.00")
      history = String.new(Api.export_movements(system, Api::MovementQuery.new(direction: "out")).content)
      history.lines[1].should eq("2026-03-10;Entrepôt principal;VIS;VIS;Vis inox;Sortie;60.0000;;;")
      state = String.new(Api.export_state(system, Api::StateQuery.new(date("2026-01-01"), date("2026-12-31"))).content)
      state.should contain("Annexe;VIS;Vis inox;0.0000;10.0000;0.0000;10.0000")
    end
  end
end
