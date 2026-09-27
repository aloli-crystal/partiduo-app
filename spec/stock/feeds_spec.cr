# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Lot 6 — mouvements de stock issus de la Facturation et de la Comptabilité
# par les événements (D-STK-004). Chaque exemple fixe ses modules actifs.
private alias Api = Partiduo::Api::Stock
private alias Inv = Partiduo::Api::Invoicing
private alias Acc = Partiduo::Api::Accounting

private def d(text : String) : BigDecimal
  BigDecimal.new(text)
end

private def system : Partiduo::Api::Actor
  Partiduo::Api::Actor.system
end

private def movements(source : String) : Array(Api::MovementView)
  Api.movements(system, Api::MovementQuery.new(source: source))
end

private def summary(source : String) : Array({String, String, BigDecimal})
  movements(source).map { |movement| {movement.stock_code, movement.direction, movement.quantity} }
end

# Facturation : dépôt par défaut, carton de ramettes suivi (la prestation
# « Conseil » ne l'est pas).
private def invoicing_setup : InvoicingSpec::Setup
  setup = InvoicingSpec.setup
  StockSpec.repository("Entrepôt")
  Api.track_item(system, Api::ItemInput.new(setup.goods.id)).value!
  setup
end

describe "Stock alimenté par la Facturation (D-STK-004)" do
  it "sort les articles d'un bon de livraison ; la facture qui en découle ne les sort pas une seconde fois" do
    with_active_modules("invoicing,stock") do
      setup = invoicing_setup
      delivery = InvoicingSpec.issued(setup, "delivery_note")
      summary("delivery_note:#{delivery.id}").should eq([{"RAMETTES", "out", d("2")}])
      movements("delivery_note:#{delivery.id}").first.comment.should eq(delivery.number)

      invoice = Inv.transform(InvoicingSpec.actor, delivery.id, Inv::TransformInput.new("invoice")).value!
      InvoicingSpec.issue(invoice.id)
      movements("invoice:").should be_empty
      StockSpec.quantity(setup.goods).should eq(d("-2"))
    end
  end

  it "sort les articles d'une facture directe et les rentre à l'avoir ; ignore l'acompte" do
    with_active_modules("invoicing,stock") do
      setup = invoicing_setup
      invoice = InvoicingSpec.issued(setup)
      summary("invoice:#{invoice.id}").should eq([{"RAMETTES", "out", d("2")}])
      credit = Inv.transform(InvoicingSpec.actor, invoice.id, Inv::TransformInput.new("credit_note")).value!
      Inv.update_document(InvoicingSpec.actor, credit.id, InvoicingSpec.document_input(setup, "credit_note",
        credited_document_id: invoice.id, lines: [InvoicingSpec.line(setup, "1", item_card_id: setup.goods.id)])).value!
      credit = InvoicingSpec.issue(credit.id, "2026-09-16")
      summary("credit_note:#{credit.id}").should eq([{"RAMETTES", "in", d("1")}])
      StockSpec.quantity(setup.goods).should eq(d("-1"))

      order = InvoicingSpec.issued(setup, "order")
      deposit = Inv.transform(InvoicingSpec.actor, order.id, Inv::TransformInput.new("deposit_invoice", d("30"))).value!
      InvoicingSpec.issue(deposit.id)
      movements("invoice:#{deposit.id}").should be_empty
      movements("deposit_invoice:").should be_empty
    end
  end

  it "ne sort pas une facture issue d'une commande déjà livrée" do
    with_active_modules("invoicing,stock") do
      setup = invoicing_setup
      order = InvoicingSpec.issued(setup, "order")
      delivery = Inv.transform(InvoicingSpec.actor, order.id, Inv::TransformInput.new("delivery_note")).value!
      InvoicingSpec.issue(delivery.id)
      invoice = Inv.transform(InvoicingSpec.actor, order.id, Inv::TransformInput.new("invoice")).value!
      InvoicingSpec.issue(invoice.id)
      Api.count_movements(system).should eq(1)
      summary("delivery_note:#{delivery.id}").should eq([{"RAMETTES", "out", d("2")}])
    end
  end

  it "ne sort pas une facture tirée du devis quand la commande issue du devis est livrée" do
    with_active_modules("invoicing,stock") do
      setup = invoicing_setup
      quote = InvoicingSpec.issued(setup, "quote")
      order = Inv.transform(InvoicingSpec.actor, quote.id, Inv::TransformInput.new("order")).value!
      InvoicingSpec.issue(order.id)
      delivery = Inv.transform(InvoicingSpec.actor, order.id, Inv::TransformInput.new("delivery_note")).value!
      InvoicingSpec.issue(delivery.id)
      invoice = Inv.transform(InvoicingSpec.actor, quote.id, Inv::TransformInput.new("invoice")).value!
      InvoicingSpec.issue(invoice.id)
      movements("invoice:#{invoice.id}").should be_empty
      StockSpec.quantity(setup.goods).should eq(d("-2"))
    end
  end

  it "n'inscrit rien sans dépôt par défaut, et n'empêche pas l'émission" do
    with_active_modules("invoicing,stock") do
      setup = InvoicingSpec.setup
      Api.track_item(system, Api::ItemInput.new(setup.goods.id)).value!
      invoice = InvoicingSpec.issued(setup)
      invoice.number.should_not be_nil
      Api.count_movements(system).should eq(0)
    end
  end
end

describe "Stock alimenté par la Comptabilité (D-STK-004)" do
  it "entre les achats au coût unitaire, sort les ventes, inverse à l'extourne" do
    with_active_modules("accounting,stock") do
      EntrySpec.setup
      StockSpec.repository("Entrepôt")
      supplier = EntrySpec.card("SUPPLIER", "Visserie Durand")
      customer = EntrySpec.card("CUSTOMER", "Garage Martin")
      screws = EntrySpec.card("PURCHASE", "Vis")
      other = EntrySpec.card("PURCHASE", "Fournitures")
      Api.track_item(system, Api::ItemInput.new(screws.id, "VIS")).value!

      purchase = Acc.post_purchase(system, EntrySpec.document("A01", supplier.code, [
        EntrySpec.item("100", item: screws.code, quantity: d("50")),
        EntrySpec.item("20", item: other.code, quantity: d("3")),
      ])).value!
      moved = movements("entry:#{purchase.id}")
      moved.map { |movement| {movement.stock_code, movement.direction, movement.quantity, movement.unit_cost} }
        .should eq([{"VIS", "in", d("50"), d("2")}])

      sale = Acc.post_sale(system, EntrySpec.document("V01", customer.code, [
        EntrySpec.item("60", item: screws.code, account: "707", quantity: d("10")),
      ], day: "2026-03-20")).value!
      summary("entry:#{sale.id}").should eq([{"VIS", "out", d("10")}])

      refund = Acc.post_purchase(system, EntrySpec.document("A01", supplier.code, [
        EntrySpec.item("-10", item: screws.code, quantity: d("-5")),
      ], day: "2026-03-25")).value!
      summary("entry:#{refund.id}").should eq([{"VIS", "out", d("5")}])
      StockSpec.quantity(screws).should eq(d("35"))

      reversal = Acc.cancel_entry(system, Acc::CancelEntryInput.new(purchase.id, EntrySpec.date("2026-03-31"))).value!
      moved = movements("entry:#{reversal.id}")
      moved.map { |movement| {movement.direction, movement.quantity, movement.unit_cost, movement.date} }
        .should eq([{"out", d("50"), d("2"), EntrySpec.date("2026-03-31")}])
      StockSpec.quantity(screws).should eq(d("-15"))
      # L'entrée extournée ne compte plus dans le coût moyen.
      Api.valuation(system, EntrySpec.date("2026-12-31")).rows.first.unit_cost.should be_nil
    end
  end

  it "n'inscrit pas les écritures d'un journal financier ou d'opérations diverses" do
    with_active_modules("accounting,stock") do
      EntrySpec.setup
      StockSpec.repository("Entrepôt")
      goods = EntrySpec.card("PURCHASE", "Vis")
      Api.track_item(system, Api::ItemInput.new(goods.id)).value!
      EntrySpec.post_misc([EntrySpec.debit("", "80", goods.code), EntrySpec.credit("400", "80")])
      Api.count_movements(system).should eq(0)
    end
  end
end

describe "Stock avec la Facturation et la Comptabilité (D-STK-004)" do
  it "compte une seule fois la facture et son écriture de vente" do
    with_active_modules("accounting,invoicing,stock") do
      setup = IntegrationSpec.setup
      StockSpec.repository("Entrepôt")
      Api.track_item(system, Api::ItemInput.new(setup.goods.id)).value!
      invoice = InvoicingSpec.issued(setup)
      IntegrationSpec.entry("invoice:#{invoice.id}")
      Api.count_movements(system).should eq(1)
      summary("invoice:#{invoice.id}").should eq([{"RAMETTES", "out", d("2")}])
    end
  end
end
