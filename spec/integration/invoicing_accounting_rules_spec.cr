# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Lot 2F — intégration par événements, cas limites (ADR-006 D3,
# D-INV-009, D-INT-005) : un paiement lettré avec plusieurs factures, un
# trop-perçu, une facture d'acompte encaissée, un lettrage sans référence de
# facture.

private alias Acc = Partiduo::Api::Accounting
private alias Inv = Partiduo::Api::Invoicing
private alias I = IntegrationSpec

private def d(text : String) : BigDecimal
  BigDecimal.new(text)
end

private def customer_line(setup : InvoicingSpec::Setup, invoice : Inv::DocumentView) : Int64
  I.line(I.entry("invoice:#{invoice.id}"), I.card_account(setup.customer.id)).id
end

describe "Facturation et Comptabilité actives — cas limites (lot 2F)" do
  it "répartit un paiement lettré avec deux factures par date : la plus ancienne d'abord" do
    with_active_modules(I::BOTH) do
      setup = I.setup
      first = InvoicingSpec.issued(setup, on: "2026-09-10")  # 1 019,76
      second = InvoicingSpec.issued(setup, on: "2026-09-15") # 1 019,76
      InvoicingSpec.capture("payment.matched") do |events|
        I.bank_receipt(setup.customer.code, "1500", [customer_line(setup, first), customer_line(setup, second)])
        events.size.should eq(1)
        amounts = events.first["amounts"].split(';').to_h { |pair| {pair.split('=')[0], BigDecimal.new(pair.split('=')[1])} }
        amounts["invoice:#{first.id}"].should eq(d("1019.76"))
        amounts["invoice:#{second.id}"].should eq(d("480.24"))
      end
      I.document(first.id).status.should eq("paid")
      partial = I.document(second.id)
      partial.status.should eq("partially_paid")
      partial.totals.amount_due.should eq(d("539.52"))
    end
  end

  it "plafonne un trop-perçu au montant de la facture ; l'excédent reste dû au client en comptabilité" do
    with_active_modules(I::BOTH) do
      setup = I.setup
      invoice = InvoicingSpec.issued(setup)
      InvoicingSpec.capture("payment.matched") do |events|
        I.bank_receipt(setup.customer.code, "1100", [customer_line(setup, invoice)])
        events.first["amounts"].should eq("invoice:#{invoice.id}=1019.76")
      end
      paid = I.document(invoice.id)
      paid.status.should eq("paid")
      paid.totals.paid.should eq(d("1019.76"))
      statement = Acc.account_statement(I.system, Acc::StatementQuery.new(card: setup.customer.code,
        as_of: I.date("2026-09-30")))
      statement.balance.should eq(d("-80.24"))
      statement.remaining.should eq(d("-80.24"))
    end
  end

  it "comptabilise la facture d'acompte et la passe à payée à son encaissement" do
    with_active_modules(I::BOTH) do
      setup = I.setup
      order = InvoicingSpec.issued(setup, "order", on: "2026-09-01")
      deposit = Inv.transform(InvoicingSpec.actor, order.id,
        Inv::TransformInput.new("deposit_invoice", deposit_percent: d("30"))).value!
      deposit = InvoicingSpec.issue(deposit.id, "2026-09-02")
      entry = I.entry("invoice:#{deposit.id}")
      entry.receipt.should eq(deposit.number)
      entry.amount.should eq(deposit.totals.total_gross)
      I.bank_receipt(setup.customer.code, deposit.totals.total_gross.to_s,
        [I.line(entry, I.card_account(setup.customer.id)).id], "2026-09-05")
      I.document(deposit.id).status.should eq("paid")
    end
  end

  it "n'écrit pas de vente pour un devis, une commande ou un bon de livraison" do
    with_active_modules(I::BOTH) do
      setup = I.setup
      quote = InvoicingSpec.issued(setup, "quote", on: "2026-09-01")
      order = InvoicingSpec.issued(setup, "order", on: "2026-09-02")
      delivery = InvoicingSpec.issued(setup, "delivery_note", on: "2026-09-03")
      [quote, order, delivery].each { |document| I.entries("invoice:#{document.id}").should be_empty }
      Acc.count_entries(I.system).should eq(0)
    end
  end

  it "laisse la facture intacte quand l'écriture de vente est annulée par extourne" do
    with_active_modules(I::BOTH) do
      setup = I.setup
      invoice = InvoicingSpec.issued(setup)
      sale = I.entry("invoice:#{invoice.id}")
      Acc.cancel_entry(I.system, Acc::CancelEntryInput.new(sale.id)).value!
      I.document(invoice.id).status.should eq("issued")
      I.document(invoice.id).totals.paid.should eq(d("0"))
    end
  end

  it "ignore côté Facturation un lettrage sans référence de facture (achats)" do
    with_active_modules(I::BOTH) do
      setup = I.setup
      supplier = EntrySpec.card("SUPPLIER", "Fournisseur lettré")
      purchase = Acc.post_purchase(I.system, EntrySpec.document("A01", supplier.code,
        [EntrySpec.item("100", account: "603")], "2026-09-10")).value!
      account = EntrySpec.card_account(supplier)
      InvoicingSpec.capture("payment.matched") do |events|
        Acc.post_financial(I.system, Acc::FinancialInput.new(ledger_id: Acc.ledger_by_code(I.system, "F01").id,
          date: I.date("2026-09-20"), lines: [Acc::PaymentLineInput.new(d("-120"), card: supplier.code,
          match_line_ids: [I.line(purchase, account).id])])).value!
        events.size.should eq(1)
        events.first["sources"].should eq("")
      end
      Inv.documents(InvoicingSpec.actor, Inv::DocumentQuery.new(status: "paid")).should be_empty
      setup.customer.id.should be > 0
    end
  end
end
