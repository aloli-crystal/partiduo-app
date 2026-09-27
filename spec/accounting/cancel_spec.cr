# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Annulation par extourne (`Acc_Ledger::reverse`, testReverse de
# `acc_ledgerTest.php`).

private alias Api = Partiduo::Api::Accounting

private def system
  Partiduo::Api::Actor.system
end

private def d(text : String) : BigDecimal
  BigDecimal.new(text)
end

describe_module "ACCOUNTING", "Annulation par extourne" do
  it "passe l'écriture inverse, avec une nouvelle pièce, et lettre chaque ligne avec son extourne" do
    EntrySpec.setup
    supplier = EntrySpec.card("SUPPLIER", "Fournisseur")
    original = Api.post_purchase(system, EntrySpec.document("A01", supplier.code, [EntrySpec.item("100", account: "603")],
      label: "Facture 12")).value!

    reversal = nil
    ReferentialSpec.capture_events("entry.cancelled") do |cancelled|
      ReferentialSpec.capture_events("entry.posted") do |posted|
        reversal = Api.cancel_entry(system, Api::CancelEntryInput.new(original.id, EntrySpec.date("2026-04-02"),
          "Annulation facture 12")).value!
        posted.map(&.["entry_id"]).should eq([ReferentialSpec.present(reversal).id.to_s])
        posted[0]["reversal_of"].should eq(original.id.to_s)
      end
      cancelled.size.should eq(1)
      cancelled[0]["entry_id"].should eq(original.id.to_s)
      cancelled[0]["reversal_entry_id"].should eq(ReferentialSpec.present(reversal).id.to_s)
    end
    reversal = ReferentialSpec.present(reversal)

    reversal.reversal?.should be_true
    reversal.reversal_of_id.should eq(original.id)
    reversal.date.should eq(EntrySpec.date("2026-04-02"))
    reversal.label.should eq("Annulation facture 12")
    reversal.ledger_id.should eq(original.ledger_id)
    reversal.receipt.should_not eq(original.receipt)
    reversal.lines.map { |line| {line.account_number, line.side.opposite, line.amount, line.card_id} }
      .should eq(original.lines.map { |line| {line.account_number, line.side, line.amount, line.card_id} })

    reloaded = Api.entry(system, original.id)
    reloaded.cancelled?.should be_true
    reloaded.reversed_by_id.should eq(reversal.id)
    reloaded.lines.each_with_index do |line, index|
      line.matching_id.should_not be_nil
      line.matching_id.should eq(reversal.lines[index].matching_id)
    end
    Api.account_statement(system, Api::StatementQuery.new(card: supplier.code)).remaining.should eq(d("0"))
  end

  it "défait le lettrage d'une facture payée : le paiement redevient ouvert" do
    EntrySpec.setup
    customer = EntrySpec.card("CUSTOMER", "Client")
    invoice = Api.post_sale(system, EntrySpec.document("V01", customer.code, [EntrySpec.item("100", account: "706")])).value!
    invoice_line = invoice.lines.find! { |line| line.card_id == customer.id }
    Api.post_financial(system, Api::FinancialInput.new(ledger_id: EntrySpec.ledger("F01").id,
      date: EntrySpec.date("2026-03-20"),
      lines: [Api::PaymentLineInput.new(d("120"), card: customer.code, match_line_ids: [invoice_line.id])])).value!

    Api.cancel_entry(system, Api::CancelEntryInput.new(invoice.id)).value!

    statement = Api.account_statement(system, Api::StatementQuery.new(card: customer.code))
    statement.remaining.should eq(d("-120.00")) # avoir de 120 : le paiement reste à rembourser
    statement.balance.should eq(d("-120.00"))
  end

  it "prend la date de l'écriture par défaut et refuse une période close" do
    EntrySpec.setup
    view = EntrySpec.post_misc([EntrySpec.debit("681", "10"), EntrySpec.credit("641", "10")], "2026-02-10")
    Partiduo::Api::Core.close_period(system, EntrySpec.period("2026-02-10").id).value!
    result = Api.cancel_entry(system, Api::CancelEntryInput.new(view.id))
    result.errors_for("date").map(&.key).should eq(["accounting.errors.entry.date.period_closed"])

    reversal = Api.cancel_entry(system, Api::CancelEntryInput.new(view.id, EntrySpec.date("2026-03-01"))).value!
    reversal.label.should eq(view.label)
  end

  it "refuse d'annuler deux fois, ou d'annuler une extourne" do
    EntrySpec.setup
    view = EntrySpec.post_misc([EntrySpec.debit("681", "10"), EntrySpec.credit("641", "10")])
    reversal = Api.cancel_entry(system, Api::CancelEntryInput.new(view.id)).value!
    Api.cancel_entry(system, Api::CancelEntryInput.new(view.id)).error_keys
      .should eq(["accounting.errors.entry.cancel.already_cancelled"])
    Api.cancel_entry(system, Api::CancelEntryInput.new(reversal.id)).error_keys
      .should eq(["accounting.errors.entry.cancel.is_reversal"])
    expect_raises(Partiduo::Api::NotFound) { Api.cancel_entry(system, Api::CancelEntryInput.new(999999_i64)) }
  end

  it "exige la permission accounting.entry.cancel" do
    EntrySpec.setup
    view = EntrySpec.post_misc([EntrySpec.debit("681", "10"), EntrySpec.credit("641", "10")])
    expect_raises(Partiduo::Api::Forbidden) do
      Api.cancel_entry(actor_with("accounting.entry.post"), Api::CancelEntryInput.new(view.id))
    end
  end
end
