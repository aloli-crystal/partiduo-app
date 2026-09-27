# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Lot 6 — mouvements automatiques (D-STK-004), cas limites : quantités
# négatives (retour de marchandise, `$nNeg` de `Acc_Ledger_Sale::insert`),
# événement rejoué, Stock inactif, échec d'inscription qui ne bloque pas
# l'opération d'origine.
private alias Api = Partiduo::Api::Stock
private alias Inv = Partiduo::Api::Invoicing
private alias Acc = Partiduo::Api::Accounting

private def d(text : String) : BigDecimal
  BigDecimal.new(text)
end

private def system : Partiduo::Api::Actor
  Partiduo::Api::Actor.system
end

private def summary(source : String) : Array({String, String, BigDecimal})
  Api.movements(system, Api::MovementQuery.new(source: source))
    .map { |movement| {movement.stock_code, movement.direction, movement.quantity} }
end

private def movement_rows : Int64
  EntrySpec.scalar("SELECT count(*) FROM stock_movement").as(Int64)
end

private def tracked_invoicing : InvoicingSpec::Setup
  setup = InvoicingSpec.setup
  StockSpec.repository("Entrepôt")
  Api.track_item(system, Api::ItemInput.new(setup.goods.id)).value!
  setup
end

describe "Mouvements automatiques : Facturation, cas limites" do
  it "rentre en stock une ligne de facture à quantité négative (retour), comme NOALYSS" do
    with_active_modules("invoicing,stock") do
      setup = tracked_invoicing
      invoice = InvoicingSpec.issued(setup, lines: [
        InvoicingSpec.line(setup, "5", item_card_id: setup.goods.id),
        InvoicingSpec.line(setup, "-2", item_card_id: setup.goods.id),
      ])
      summary("invoice:#{invoice.id}").should eq([{"RAMETTES", "out", d("5")}, {"RAMETTES", "in", d("2")}])
      StockSpec.quantity(setup.goods).should eq(d("-3"))
    end
  end

  it "ne compte pas deux fois un événement rejoué, ni une prestation non suivie" do
    with_active_modules("invoicing,stock") do
      setup = tracked_invoicing
      invoice = InvoicingSpec.issued(setup)
      Partiduo::Events.publish("invoice.issued", {"invoice_id" => invoice.id.to_s})
      summary("invoice:#{invoice.id}").should eq([{"RAMETTES", "out", d("2")}])
      movement = Api.movements(system).first
      {movement.date, movement.comment, movement.change_id}.should eq({StockSpec.date("2026-09-15"), invoice.number, nil})
    end
  end

  it "inscrit dans le dépôt par défaut du moment" do
    with_active_modules("invoicing,stock") do
      setup = tracked_invoicing
      other = StockSpec.repository("Magasin")
      Api.update_settings(system, Api::SettingsInput.new(other.id)).value!
      InvoicingSpec.issued(setup)
      Api.movements(system).map(&.repository_name).should eq(["Magasin"])
    end
  end

  it "n'inscrit rien quand le Stock est inactif, sans gêner l'émission" do
    with_active_modules("invoicing") do
      setup = InvoicingSpec.setup
      InvoicingSpec.issued(setup).number.should_not be_nil
      movement_rows.should eq(0)
    end
  end

  it "consigne un échec d'inscription sans annuler l'émission de la facture" do
    with_active_modules("invoicing,stock") do
      setup = tracked_invoicing
      EntrySpec.sql(<<-SQL)
        CREATE FUNCTION spec_stock_refuse() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN RAISE EXCEPTION 'mouvement refusé (spec)'; END $$
        SQL
      EntrySpec.sql("CREATE TRIGGER spec_stock_refuse BEFORE INSERT ON stock_movement " \
                    "FOR EACH ROW EXECUTE FUNCTION spec_stock_refuse()")
      begin
        invoice = InvoicingSpec.issued(setup)
        invoice.number.should_not be_nil
        Inv.document(InvoicingSpec.actor, invoice.id).number.should eq(invoice.number)
        movement_rows.should eq(0)
      ensure
        EntrySpec.sql("DROP TRIGGER IF EXISTS spec_stock_refuse ON stock_movement")
        EntrySpec.sql("DROP FUNCTION IF EXISTS spec_stock_refuse()")
      end
    end
  end
end

describe "Mouvements automatiques : Comptabilité, cas limites" do
  it "prend une quantité de 1 à défaut, et une extourne de vente rentre la marchandise" do
    with_active_modules("accounting,stock") do
      EntrySpec.setup
      StockSpec.repository("Entrepôt")
      customer = EntrySpec.card("CUSTOMER", "Garage Martin")
      screws = EntrySpec.card("PURCHASE", "Vis")
      Api.track_item(system, Api::ItemInput.new(screws.id, "VIS")).value!
      sale = Acc.post_sale(system, EntrySpec.document("V01", customer.code, [
        EntrySpec.item("60", item: screws.code, account: "707"),
      ], day: "2026-03-20")).value!
      moved = Api.movements(system, Api::MovementQuery.new(source: "entry:#{sale.id}"))
      moved.map { |movement| {movement.direction, movement.quantity, movement.unit_cost} }.should eq([{"out", d("1"), nil}])
      moved.first.comment.should_not be_empty

      reversal = Acc.cancel_entry(system, Acc::CancelEntryInput.new(sale.id, EntrySpec.date("2026-03-25"))).value!
      summary("entry:#{reversal.id}").should eq([{"VIS", "in", d("1")}])
      StockSpec.quantity(screws).should eq(d("0"))
    end
  end

  it "n'inscrit rien sans dépôt par défaut et n'empêche pas l'écriture" do
    with_active_modules("accounting,stock") do
      EntrySpec.setup
      supplier = EntrySpec.card("SUPPLIER", "Visserie Durand")
      screws = EntrySpec.card("PURCHASE", "Vis")
      Api.track_item(system, Api::ItemInput.new(screws.id)).value!
      purchase = Acc.post_purchase(system, EntrySpec.document("A01", supplier.code, [
        EntrySpec.item("100", item: screws.code, quantity: d("50")),
      ]))
      purchase.success?.should be_true
      Api.count_movements(system).should eq(0)
    end
  end

  it "arrondit le coût unitaire d'un achat à quatre décimales" do
    with_active_modules("accounting,stock") do
      EntrySpec.setup
      StockSpec.repository("Entrepôt")
      supplier = EntrySpec.card("SUPPLIER", "Visserie Durand")
      screws = EntrySpec.card("PURCHASE", "Vis")
      Api.track_item(system, Api::ItemInput.new(screws.id)).value!
      purchase = Acc.post_purchase(system, EntrySpec.document("A01", supplier.code, [
        EntrySpec.item("100", item: screws.code, quantity: d("3")),
      ])).value!
      Api.movements(system, Api::MovementQuery.new(source: "entry:#{purchase.id}")).first.unit_cost.should eq(d("33.3333"))
    end
  end
end

describe "Mouvements automatiques : Facturation et Comptabilité ensemble" do
  it "compte une seule fois l'avoir et son écriture" do
    with_active_modules("accounting,invoicing,stock") do
      setup = IntegrationSpec.setup
      StockSpec.repository("Entrepôt")
      Api.track_item(system, Api::ItemInput.new(setup.goods.id)).value!
      invoice = InvoicingSpec.issued(setup)
      credit = Inv.transform(InvoicingSpec.actor, invoice.id, Inv::TransformInput.new("credit_note")).value!
      Inv.update_document(InvoicingSpec.actor, credit.id, InvoicingSpec.document_input(setup, "credit_note",
        credited_document_id: invoice.id, lines: [InvoicingSpec.line(setup, "1", item_card_id: setup.goods.id)])).value!
      credit = InvoicingSpec.issue(credit.id, "2026-09-16")
      IntegrationSpec.entry("credit_note:#{credit.id}")
      summary("credit_note:#{credit.id}").should eq([{"RAMETTES", "in", d("1")}])
      Api.count_movements(system).should eq(2)
    end
  end
end

describe "Mouvements automatiques : lignes d'articles d'une écriture" do
  it "ne retient que les lignes saisies sans rôle de TVA ou de rôle base" do
    Partiduo::Stock::Feeds.item_line?(0, nil).should be_true
    Partiduo::Stock::Feeds.item_line?(1, "base").should be_true
    Partiduo::Stock::Feeds.item_line?(2, "tax").should be_false
    Partiduo::Stock::Feeds.item_line?(nil, nil).should be_false
    Partiduo::Stock::Feeds.item_line?(3, "vat").should be_false
  end
end
