# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Lot 6 — Stock : cas limites des règles (`Stock_Goods::record_save`,
# `Stock::summary`, `take_last_inventory`), droits par commande, module
# inactif et contraintes d'intégrité en base.
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

private def line(card : Partiduo::Api::Cards::CardView, quantity : String, cost : String? = nil) : Api::ChangeLineInput
  Api::ChangeLineInput.new(card.id, d(quantity), cost.try { |value| d(value) })
end

private def counted(card : Partiduo::Api::Cards::CardView, quantity : String, cost : String? = nil) : Api::InventoryLineInput
  Api::InventoryLineInput.new(card.id, d(quantity), cost.try { |value| d(value) })
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

# Chaque appel du contrat, avec l'acteur donné (identifiants fictifs : le
# refus doit précéder toute recherche).
private def each_call(actor : Partiduo::Api::Actor, & : String, String, Proc(Nil) ->) : Nil
  day = date("2026-06-30")
  change = Api::ChangeInput.new(1_i64, day, [Api::ChangeLineInput.new(1_i64, d("1"))])
  inventory = Api::InventoryInput.new(1_i64, day, [Api::InventoryLineInput.new(1_i64, d("1"))])
  state = Api::StateQuery.new(day, day)
  {
    {"settings", Api::READ, -> { Api.settings(actor); nil }},
    {"repositories", Api::READ, -> { Api.repositories(actor); nil }},
    {"repository", Api::READ, -> { Api.repository(actor, 1_i64); nil }},
    {"items", Api::READ, -> { Api.items(actor); nil }},
    {"item", Api::READ, -> { Api.item(actor, 1_i64); nil }},
    {"changes", Api::READ, -> { Api.changes(actor); nil }},
    {"change", Api::READ, -> { Api.change(actor, 1_i64); nil }},
    {"movements", Api::READ, -> { Api.movements(actor); nil }},
    {"count_movements", Api::READ, -> { Api.count_movements(actor); nil }},
    {"quantity", Api::READ, -> { Api.quantity(actor, 1_i64); nil }},
    {"state", Api::READ, -> { Api.state(actor, state); nil }},
    {"valuation", Api::READ, -> { Api.valuation(actor); nil }},
    {"export_movements", Api::READ, -> { Api.export_movements(actor); nil }},
    {"export_state", Api::READ, -> { Api.export_state(actor, state); nil }},
    {"export_valuation", Api::READ, -> { Api.export_valuation(actor); nil }},
    {"check_change", Api::WRITE, -> { Api.check_change(actor, change); nil }},
    {"record_change", Api::WRITE, -> { Api.record_change(actor, change); nil }},
    {"delete_change", Api::WRITE, -> { Api.delete_change(actor, 1_i64); nil }},
    {"inventory_proposal", Api::WRITE, -> { Api.inventory_proposal(actor, 1_i64, day); nil }},
    {"check_inventory", Api::WRITE, -> { Api.check_inventory(actor, inventory); nil }},
    {"record_inventory", Api::WRITE, -> { Api.record_inventory(actor, inventory); nil }},
    {"update_settings", Api::SETTINGS_WRITE, -> { Api.update_settings(actor, Api::SettingsInput.new(nil)); nil }},
    {"check_repository", Api::SETTINGS_WRITE, -> { Api.check_repository(actor, Api::RepositoryInput.new("X")); nil }},
    {"create_repository", Api::SETTINGS_WRITE, -> { Api.create_repository(actor, Api::RepositoryInput.new("X")); nil }},
    {"update_repository", Api::SETTINGS_WRITE, -> { Api.update_repository(actor, 1_i64, Api::RepositoryInput.new("X")); nil }},
    {"delete_repository", Api::SETTINGS_WRITE, -> { Api.delete_repository(actor, 1_i64); nil }},
    {"track_item", Api::SETTINGS_WRITE, -> { Api.track_item(actor, Api::ItemInput.new(1_i64)); nil }},
    {"untrack_item", Api::SETTINGS_WRITE, -> { Api.untrack_item(actor, 1_i64); nil }},
  }.each { |(name, permission, call)| yield name, permission, call }
end

describe "Stock : module inactif et droits, commande par commande" do
  it "lève ModuleDisabled sur chaque appel quand le Stock est inactif" do
    with_active_modules("accounting,invoicing,followup") do
      each_call(system) do |name, _, call|
        {name, refused? { call.call }}.should eq({name, :disabled})
      end
    end
  end

  it "ne s'active pas sans la Facturation ni la Comptabilité" do
    Partiduo::Modules.activation_errors(Set{"STOCK"})
      .should contain("STOCK requiert l'un de INVOICING, ACCOUNTING, tous inactifs")
    Partiduo::Modules.activation_errors(Set{"STOCK", "INVOICING"}).should be_empty
    Partiduo::Modules.activation_errors(Set{"STOCK", "ACCOUNTING"}).should be_empty
  end

  it "exige la permission propre à chaque appel, avant toute recherche" do
    with_active_modules("invoicing,stock") do
      each_call(actor_with) do |name, _, call|
        {name, refused? { call.call }}.should eq({name, :forbidden})
      end
      [Api::READ, Api::WRITE, Api::SETTINGS_WRITE].each do |held|
        each_call(actor_with(held)) do |name, permission, call|
          next if permission == held
          # Écrire n'emporte pas lire, ni l'inverse.
          {name, held, refused? { call.call }}.should eq({name, held, :forbidden})
        end
      end
    end
  end

  it "donne les permissions du Stock au profil ACCOUNTANT par défaut" do
    with_active_modules("invoicing,stock") do
      profile = Partiduo::Api::Auth.ensure_default_profiles(system).find!(&.code.==("ACCOUNTANT"))
      profile.permissions.select(&.starts_with?("stock.")).sort!
        .should eq(["stock.movement.read", "stock.movement.write", "stock.settings.write"])
    end
  end
end

describe_module "STOCK", "Stock : cas limites" do
  describe "dépôts et paramètres" do
    it "contrôle longueurs et pays, accepte de garder son propre nom en changeant la casse" do
      setup = StockSpec.setup
      Api.check_repository(system, Api::RepositoryInput.new("x" * 101, city: "c" * 101, phone: "0" * 41))
        .error_keys.should eq(["stock.errors.repository.name_too_long", "stock.errors.repository.too_long",
                               "stock.errors.repository.too_long"])
      Api.check_repository(system, Api::RepositoryInput.new("x" * 100, country_code: "be")).success?.should be_true
      renamed = Api.update_repository(system, setup.main.id, Api::RepositoryInput.new(" ENTREPÔT principal ",
        country_code: "be")).value!
      {renamed.name, renamed.country_code, renamed.default}.should eq({"ENTREPÔT principal", "BE", true})
      Api.update_repository(system, setup.annex.id, Api::RepositoryInput.new("entrepôt Principal")).error_keys
        .should eq(["stock.errors.repository.name_taken"])
      expect_raises(Partiduo::Api::NotFound) { Api.update_repository(system, 999_999_i64, Api::RepositoryInput.new("Y")) }
      expect_raises(Partiduo::Api::NotFound) { Api.delete_repository(system, 999_999_i64) }
    end

    it "vide le dépôt par défaut quand on le supprime ; le dépôt créé ensuite le devient" do
      setup = StockSpec.setup
      Api.delete_repository(system, setup.main.id).success?.should be_true
      Api.settings(system).default_repository_id.should be_nil
      Api.repository(system, setup.annex.id).default.should be_false
      third = StockSpec.repository("Troisième")
      third.default.should be_true
      Api.update_settings(system, Api::SettingsInput.new(nil)).value!.default_repository_id.should be_nil
      Api.repositories(system).none?(&.default).should be_true
    end

    it "refuse de supprimer un dépôt qui porte un inventaire sans écart" do
      setup = StockSpec.setup
      inventory = Api.record_inventory(system, Api::InventoryInput.new(setup.annex.id, date("2026-06-30"),
        [counted(setup.screws, "0")])).value!
      inventory.movements.should be_empty
      Api.delete_repository(system, setup.annex.id).error_keys.should eq(["stock.errors.repository.in_use"])
      Api.delete_change(system, inventory.id).success?.should be_true
      Api.delete_repository(system, setup.annex.id).success?.should be_true
    end
  end

  describe "articles suivis" do
    it "change le code stock sans toucher aux mouvements passés" do
      setup = StockSpec.setup
      StockSpec.change(setup.main, "2026-02-01", {setup.screws, "10", nil})
      Api.track_item(system, Api::ItemInput.new(setup.screws.id, "vis-inox")).value!.stock_code.should eq("VIS-INOX")
      Api.items(system).size.should eq(2)
      StockSpec.change(setup.main, "2026-02-02", {setup.screws, "3", nil})
      Api.movements(system).map(&.stock_code).should eq(["VIS", "VIS-INOX"])
      StockSpec.quantity(setup.screws).should eq(d("3"))
      state = Api.state(system, Api::StateQuery.new(date("2026-01-01"), date("2026-12-31")))
      state.rows.map { |row| {row.stock_code, row.closing} }.should eq([{"VIS", d("10")}, {"VIS-INOX", d("3")}])
    end

    it "additionne sous un code commun les mouvements de toutes ses fiches" do
      setup = StockSpec.setup
      Api.track_item(system, Api::ItemInput.new(setup.service.id, "BOUL-01")).value!
      StockSpec.change(setup.main, "2026-02-01", {setup.bolts, "10", nil}, {setup.service, "5", nil})
      StockSpec.quantity(setup.bolts).should eq(d("15"))
      StockSpec.quantity(setup.service).should eq(d("15"))
      row = StockSpec.row(Api.state(system, Api::StateQuery.new(date("2026-01-01"), date("2026-12-31"))), setup.main, "BOUL-01")
      row.card_names.should eq(["Boulons", "Montage"])
      # Une seule ligne par code dans l'inventaire proposé.
      Api.inventory_proposal(system, setup.main.id, date("2026-12-31")).map(&.stock_code).should eq(["BOUL-01", "VIS"])
    end

    it "refuse un code stock trop long ou contenant un blanc, et une fiche non suivie" do
      setup = StockSpec.setup
      Api.track_item(system, Api::ItemInput.new(setup.service.id, "A" * 41)).error_keys
        .should eq(["stock.errors.item.too_long"])
      Api.track_item(system, Api::ItemInput.new(setup.service.id, "A B")).error_keys
        .should eq(["stock.errors.item.invalid"])
      Api.track_item(system, Api::ItemInput.new(setup.service.id, "A" * 40)).success?.should be_true
      expect_raises(Partiduo::Api::NotFound) { Api.untrack_item(system, 999_999_i64) }
      Api.untrack_item(system, setup.service.id).success?.should be_true
      expect_raises(Partiduo::Api::NotFound) { Api.quantity(system, setup.service.id) }
    end

    it "valide et normalise le code repris de la fiche quand le code saisi est vide" do
      setup = StockSpec.setup
      Api.track_item(system, Api::ItemInput.new(setup.service.id, "   ")).value!.stock_code.should eq("MONTAGE")
      # Un second suivi de la même fiche met à jour l'article, sans doublon.
      Api.track_item(system, Api::ItemInput.new(setup.service.id, "mont-01")).value!.stock_code.should eq("MONT-01")
      Partiduo::Stock::Item.filter(card_id: setup.service.id).count.should eq(1)
      Partiduo::Stock::Rules.effective_code(Api::ItemInput.new(setup.service.id),
        Partiduo::Stock::Cards::Info.new(1_i64, " montage bis ", "Montage", "item")).should eq("MONTAGE BIS")
    end

    it "suit la fiche : supprimée sans mouvement, protégée avec" do
      setup = StockSpec.setup
      Partiduo::Api::Cards.delete_card(system, setup.bolts.id).success?.should be_true
      Api.item(system, setup.bolts.id).should be_nil
      StockSpec.change(setup.main, "2026-02-01", {setup.screws, "1", nil})
      Api.untrack_item(system, setup.screws.id).success?.should be_true
      Partiduo::Api::Cards.delete_card(system, setup.screws.id).error_keys.should eq(["cards.errors.card.base.in_use"])
      Api.movements(system).first.card_name.should eq("Vis inox")
    end
  end

  describe "opérations manuelles" do
    it "accepte quatre décimales et refuse coût négatif, coût trop précis et motif trop long" do
      setup = StockSpec.setup
      Api.record_change(system, Api::ChangeInput.new(setup.main.id, date("2026-03-01"),
        [line(setup.screws, "1.2345", "0.0001")])).value!.movements.first.quantity.should eq(d("1.2345"))
      result = Api.check_change(system, Api::ChangeInput.new(setup.main.id, date("2026-03-01"),
        [line(setup.screws, "1", "-1"), line(setup.screws, "1", "0.00001")], "m" * 1001))
      result.errors.map { |error| {error.field, error.key} }.should eq([
        {"comment", "stock.errors.change.too_long"},
        {"lines[0].unit_cost", "stock.errors.change.cost_negative"},
        {"lines[1].unit_cost", "stock.errors.change.cost_scale"},
      ])
      ReferentialSpec.expect_translated(result)
    end

    it "garde l'auteur et le motif débarrassé de ses blancs" do
      setup = StockSpec.setup
      _, writer = AccountingSpec.user_actor("magasin@example.test", Api::WRITE, Api::READ)
      change = Api.record_change(writer, Api::ChangeInput.new(setup.main.id, date("2026-03-01"),
        [line(setup.screws, "-4")], "  Casse  ")).value!
      change.comment.should eq("Casse")
      change.created_by_id.should eq(writer.user_id)
      movement = change.movements.first
      {movement.direction, movement.quantity, movement.signed_quantity, movement.comment, movement.source}
        .should eq({"out", d("4"), d("-4"), "Casse", ""})
      movement.created_by_id.should eq(writer.user_id)
      expect_raises(Partiduo::Api::NotFound) { Api.change(system, 999_999_i64) }
      expect_raises(Partiduo::Api::NotFound) { Api.delete_change(system, 999_999_i64) }
    end

    it "refuse toute saisie dans un exercice clos" do
      setup = StockSpec.setup
      year = ReferentialSpec.fiscal_year(2025)
      StockSpec.change(setup.main, "2025-12-01", {setup.screws, "10", nil})
      Partiduo::Api::Core.close_fiscal_year(system, year.id).success?.should be_true
      Api.check_change(system, Api::ChangeInput.new(setup.main.id, date("2025-12-31"), [line(setup.screws, "1")]))
        .error_keys.should eq(["stock.errors.change.closed_period"])
      Api.record_inventory(system, Api::InventoryInput.new(setup.main.id, date("2025-12-31"), [counted(setup.screws, "8")]))
        .error_keys.should eq(["stock.errors.change.closed_period"])
      Api.delete_change(system, Api.changes(system).first.id).error_keys.should eq(["stock.errors.change.closed_period"])
      # Hors de tout exercice, la saisie reste libre.
      StockSpec.change(setup.main, "2027-01-05", {setup.screws, "1", nil}).movements.size.should eq(1)
    end

    it "filtre les opérations par dépôt, dates et nature" do
      setup = StockSpec.setup
      StockSpec.change(setup.main, "2026-02-01", {setup.screws, "10", nil})
      StockSpec.change(setup.annex, "2026-03-01", {setup.screws, "10", nil})
      Api.record_inventory(system, Api::InventoryInput.new(setup.main.id, date("2026-04-01"), [counted(setup.screws, "9")])).value!
      Api.changes(system, Api::ChangeQuery.new(repository_id: setup.main.id)).size.should eq(2)
      Api.changes(system, Api::ChangeQuery.new(kind: "inventory")).map(&.kind_key).should eq(["stock.change_kinds.inventory"])
      Api.changes(system, Api::ChangeQuery.new(date_from: date("2026-02-15"), date_to: date("2026-03-15")))
        .map(&.repository_name).should eq(["Annexe"])
    end
  end

  describe "inventaire" do
    it "calcule l'écart au jour de l'inventaire, dans le seul dépôt compté" do
      setup = StockSpec.setup
      StockSpec.change(setup.main, "2026-06-01", {setup.screws, "50", nil})
      StockSpec.change(setup.annex, "2026-06-01", {setup.screws, "7", nil})
      # Mouvement postérieur à l'inventaire : hors de la quantité théorique.
      StockSpec.change(setup.main, "2026-07-10", {setup.screws, "5", nil})
      Api.inventory_proposal(system, setup.main.id, date("2026-06-30")).find!(&.stock_code.==("VIS")).quantity.should eq(d("50"))
      inventory = Api.record_inventory(system, Api::InventoryInput.new(setup.main.id, date("2026-06-30"),
        [counted(setup.screws, "45", "9.99")])).value!
      # Une sortie ne porte pas de coût, même saisi.
      inventory.movements.map { |movement| {movement.direction, movement.quantity, movement.unit_cost} }
        .should eq([{"out", d("5"), nil}])
      StockSpec.quantity(setup.screws, repository: setup.main).should eq(d("50"))
      StockSpec.quantity(setup.screws, repository: setup.annex).should eq(d("7"))
    end

    it "refuse un inventaire vide, un dépôt inconnu et une fiche non suivie" do
      setup = StockSpec.setup
      Api.check_inventory(system, Api::InventoryInput.new(999_i64, date("2026-06-30"), [] of Api::InventoryLineInput))
        .error_keys.should eq(["stock.errors.change.repository_unknown", "stock.errors.inventory.lines_required"])
      result = Api.check_inventory(system, Api::InventoryInput.new(setup.main.id, date("2026-06-30"),
        [counted(setup.service, "1"), counted(setup.screws, "1.00001")]))
      result.errors.map { |error| {error.field, error.key} }.should eq([
        {"lines[0].card_id", "stock.errors.change.not_tracked"},
        {"lines[1].counted", "stock.errors.change.quantity_scale"},
      ])
      expect_raises(Partiduo::Api::NotFound) { Api.inventory_proposal(system, 999_999_i64, date("2026-06-30")) }
    end
  end

  describe "historique, état et valorisation" do
    it "borne l'historique et filtre par fiche et par origine" do
      setup = StockSpec.setup
      StockSpec.change(setup.main, "2026-02-01", {setup.screws, "10", nil}, {setup.bolts, "2", nil})
      Api.movements(system, Api::MovementQuery.new(limit: 0)).should be_empty
      Api.movements(system, Api::MovementQuery.new(limit: -5)).should be_empty
      Api.movements(system, Api::MovementQuery.new(offset: -3)).size.should eq(2)
      Api.movements(system, Api::MovementQuery.new(card_id: setup.bolts.id)).map(&.stock_code).should eq(["BOUL-01"])
      Api.count_movements(system, Api::MovementQuery.new(source: "invoice:")).should eq(0)
      Api.count_movements(system, Api::MovementQuery.new(stock_code: " boul-01 ")).should eq(1)
    end

    it "ouvre l'état sur les mouvements antérieurs et exclut ceux d'après la période" do
      setup = StockSpec.setup
      StockSpec.change(setup.main, "2026-01-31", {setup.screws, "10", nil})
      StockSpec.change(setup.main, "2026-02-01", {setup.screws, "4", nil})
      StockSpec.change(setup.main, "2026-02-28", {setup.screws, "-6", nil})
      StockSpec.change(setup.main, "2026-03-01", {setup.screws, "100", nil})
      row = StockSpec.row(Api.state(system, Api::StateQuery.new(date("2026-02-01"), date("2026-02-28"))), setup.main, "VIS")
      {row.opening, row.quantity_in, row.quantity_out, row.closing}.should eq({d("10"), d("4"), d("6"), d("8")})
      Api.state(system, Api::StateQuery.new(date("2025-01-01"), date("2025-12-31"))).rows.should be_empty
    end

    it "valorise un dépôt, écarte les quantités nulles et ne valorise pas un code sans coût" do
      setup = StockSpec.setup
      StockSpec.change(setup.main, "2026-01-10", {setup.screws, "10", "1.5"}, {setup.bolts, "4", nil})
      StockSpec.change(setup.annex, "2026-01-10", {setup.screws, "2", nil})
      StockSpec.change(setup.main, "2026-02-10", {setup.bolts, "-4", nil})
      valuation = Api.valuation(system, date("2026-03-31"), setup.main.id)
      valuation.rows.map { |row| {row.stock_code, row.quantity, row.unit_cost, row.value} }
        .should eq([{"VIS", d("10"), d("1.5"), d("15")}])
      # Coût moyen commun à tous les dépôts (D-STK-005).
      Api.valuation(system, date("2026-03-31"), setup.annex.id).rows.first.value.should eq(d("3"))
      Api.valuation(system, date("2026-03-31")).total.should eq(d("18"))
      Api.valuation(system, date("2025-12-31")).rows.should be_empty
    end

    it "arrondit le coût moyen à quatre décimales et la valeur au centime" do
      setup = StockSpec.setup
      StockSpec.change(setup.main, "2026-01-10", {setup.screws, "3", "1"}, {setup.bolts, "1", "1"})
      StockSpec.change(setup.main, "2026-01-11", {setup.screws, "3", "2"})
      StockSpec.change(setup.main, "2026-01-12", {setup.screws, "1", "2"})
      # (3 × 1 + 3 × 2 + 1 × 2) ÷ 7 = 1,571428…
      row = Api.valuation(system, date("2026-01-31")).rows.find!(&.stock_code.==("VIS"))
      {row.unit_cost, row.value}.should eq({d("1.5714"), d("11")})
    end

    it "protège les exports contre les formules" do
      setup = StockSpec.setup
      StockSpec.change(setup.main, "2026-02-01", {setup.screws, "10", nil}, comment: "=HYPERLINK(\"x\")")
      csv = String.new(Api.export_movements(system).content)
      csv.should contain(%(;"'=HYPERLINK))
      Api.export_movements(system).content_type.should start_with("text/csv")
    end
  end

  describe "intégrité en base" do
    it "refuse sens inconnu, quantité nulle, coût négatif, fiche inexistante et opération de nature inconnue" do
      setup = StockSpec.setup
      movement = StockSpec.change(setup.main, "2026-02-01", {setup.screws, "10", nil}).movements.first
      {
        "direction = 'x'"   => /stock_movement_direction_check/,
        "quantity = 0"      => /stock_movement_quantity_check/,
        "quantity = -1"     => /stock_movement_quantity_check/,
        "unit_cost = -0.01" => /stock_movement_unit_cost_check/,
        "card_id = 987654"  => /stock_movement_card_fk/,
      }.each do |assignment, error|
        expect_raises(Exception, error) do
          EntrySpec.sql_transaction(&.exec("UPDATE stock_movement SET #{assignment} WHERE id = $1", movement.id))
        end
      end
      expect_raises(Exception, /stock_change_kind_check/) do
        EntrySpec.sql_transaction(&.exec("UPDATE stock_change SET kind = 'loss'"))
      end
      expect_raises(Exception, /stock_item_card_fk/) do
        EntrySpec.sql_transaction(&.exec("UPDATE stock_item SET card_id = 987654 WHERE card_id = $1", setup.screws.id))
      end
      expect_raises(Exception, /foreign key|violates/i) do
        EntrySpec.sql_transaction(&.exec("DELETE FROM stock_repository WHERE id = $1", setup.main.id))
      end
    end

    it "garde une seule ligne de paramètres et un article par fiche" do
      setup = StockSpec.setup
      expect_raises(Exception, /stock_setting_singleton/) do
        EntrySpec.sql_transaction(&.exec("INSERT INTO stock_setting (singleton, created_at, updated_at) VALUES (true, now(), now())"))
      end
      expect_raises(Exception, /stock_setting_singleton_check/) do
        EntrySpec.sql_transaction(&.exec("UPDATE stock_setting SET singleton = false"))
      end
      expect_raises(Exception, /unique|duplicate/i) do
        EntrySpec.sql_transaction(&.exec("INSERT INTO stock_item (card_id, stock_code, created_at, updated_at) " \
                                         "VALUES ($1, 'X', now(), now())", setup.screws.id))
      end
      expect_raises(Exception, /unique|duplicate/i) do
        EntrySpec.sql_transaction(&.exec("INSERT INTO stock_repository (name, created_at, updated_at) " \
                                         "VALUES ('Annexe', now(), now())"))
      end
      EntrySpec.scalar("SELECT count(*) FROM stock_setting").should eq(1)
    end
  end
end
