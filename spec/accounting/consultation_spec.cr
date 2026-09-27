# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Recherche d'écritures (`Acc_Ledger_Search`) et consultation d'un compte ou
# d'un tiers (ADR-005 D9 ; `Lettering::get_balance_ageing`).

private alias Api = Partiduo::Api::Accounting

private def system
  Partiduo::Api::Actor.system
end

private def d(text : String) : BigDecimal
  BigDecimal.new(text)
end

private def sale(customer, amount : String, day : String, due : String? = nil) : Api::EntryView
  Api.post_sale(system, EntrySpec.document("V01", customer.code, [EntrySpec.item(amount, account: "706")], day,
    due_date: due.try { |value| EntrySpec.date(value) }, label: "Facture #{amount}")).value!
end

private def pay(customer, amount : String, day : String, match : Array(Int64) = [] of Int64) : Api::EntryView
  Api.post_financial(system, Api::FinancialInput.new(ledger_id: EntrySpec.ledger("F01").id, date: EntrySpec.date(day),
    lines: [Api::PaymentLineInput.new(d(amount), card: customer.code, match_line_ids: match)])).value!.first
end

private def line_of(view : Api::EntryView, card) : Int64
  view.lines.find! { |line| line.card_id == card.id }.id
end

describe_module "ACCOUNTING", "Consultation" do
  describe ".entries" do
    it "cherche par journal, dates, compte, fiche, pièce, texte, montant, source" do
      EntrySpec.setup
      customer = EntrySpec.card("CUSTOMER", "Client recherché")
      a = sale(customer, "100", "2026-02-01")
      b = sale(customer, "250", "2026-03-01")
      c = EntrySpec.post_misc([EntrySpec.debit("681", "40"), EntrySpec.credit("641", "40")], "2026-03-10",
        label: "Dotation mars", source: "fec:OD-3")

      Api.entries(system).map(&.id).should eq([a.id, b.id, c.id])
      Api.count_entries(system).should eq(3)
      Api.entries(system, Api::EntryQuery.new(ledger_kind: Api::LedgerKind::Sale)).map(&.id).should eq([a.id, b.id])
      Api.entries(system, Api::EntryQuery.new(ledger_id: EntrySpec.ledger("O01").id)).map(&.id).should eq([c.id])
      Api.entries(system, Api::EntryQuery.new(date_from: EntrySpec.date("2026-02-15"), date_to: EntrySpec.date("2026-03-05")))
        .map(&.id).should eq([b.id])
      Api.entries(system, Api::EntryQuery.new(period_id: EntrySpec.period("2026-03-01").id)).map(&.id).should eq([b.id, c.id])
      Api.entries(system, Api::EntryQuery.new(account: "681")).map(&.id).should eq([c.id])
      Api.entries(system, Api::EntryQuery.new(account: "68", account_prefix: true)).map(&.id).should eq([c.id])
      Api.entries(system, Api::EntryQuery.new(card: customer.code)).map(&.id).should eq([a.id, b.id])
      Api.entries(system, Api::EntryQuery.new(card: "INCONNU")).should be_empty
      Api.entries(system, Api::EntryQuery.new(receipt: b.receipt)).map(&.id).should eq([b.id])
      Api.entries(system, Api::EntryQuery.new(text: "dotation")).map(&.id).should eq([c.id])
      Api.entries(system, Api::EntryQuery.new(text: "50%")).should be_empty
      Api.entries(system, Api::EntryQuery.new(text: c.internal_code)).map(&.id).should eq([c.id])
      Api.entries(system, Api::EntryQuery.new(amount_min: d("100"), amount_max: d("200"))).map(&.id).should eq([a.id])
      Api.entries(system, Api::EntryQuery.new(source: "fec:OD-3")).map(&.id).should eq([c.id])
      Api.entries(system, Api::EntryQuery.new(offset: 1, limit: 1)).map(&.id).should eq([b.id])
      Api.count_entries(system, Api::EntryQuery.new(ledger_kind: Api::LedgerKind::Sale)).should eq(2)

      Api.cancel_entry(system, Api::CancelEntryInput.new(c.id)).value!
      Api.entries(system, Api::EntryQuery.new(include_cancelled: false)).map(&.id).should eq([a.id, b.id])
    end

    it "ne montre que les journaux lisibles de l'acteur" do
      EntrySpec.setup
      view = EntrySpec.post_misc([EntrySpec.debit("681", "10"), EntrySpec.credit("641", "10")])
      user_id, actor = AccountingSpec.user_actor("lecteur@example.com", "accounting.entry.read")
      Partiduo::Api::Auth.set_ledger_security(system, user_id, true).value!
      Api.entries(actor).should be_empty
      expect_raises(Partiduo::Api::NotFound) { Api.entry(actor, view.id) }
      Partiduo::Api::Auth.set_ledger_access(system, user_id, EntrySpec.ledger("O01").id, "R").value!
      Api.entries(actor).map(&.id).should eq([view.id])
      expect_raises(Partiduo::Api::Forbidden) { Api.entries(actor_with("accounting.entry.post")) }
    end
  end

  describe ".account_statement" do
    it "donne solde, reste dû, échu, balance âgée et mouvements d'un tiers (ADR-005 D9)" do
      EntrySpec.setup
      customer = EntrySpec.card("CUSTOMER", "Client suivi")
      old = sale(customer, "100", "2026-01-05", "2026-01-20")     # 120 TTC, échue de 71 jours
      mid = sale(customer, "200", "2026-02-01", "2026-03-01")     # 240, échue de 32 jours
      recent = sale(customer, "50", "2026-03-10", "2026-03-25")   # 60, échue de 8 jours
      future = sale(customer, "1000", "2026-03-20", "2026-04-30") # 1200, non échue
      paid = sale(customer, "10", "2026-01-10")                   # 12, payée
      pay(customer, "12", "2026-01-15", [line_of(paid, customer)])
      pay(customer, "40", "2026-03-30", [line_of(mid, customer)]) # acompte : lettrage partiel, reliquat 200

      query = Api::StatementQuery.new(card: customer.code, as_of: EntrySpec.date("2026-04-02"))
      statement = Api.account_statement(system, query)

      statement.card_code.should eq(customer.code)
      statement.card_name.should eq("Client suivi")
      statement.account.try(&.number).should eq(EntrySpec.card_account(customer))
      statement.balance.should eq(d("1580.00"))
      statement.remaining.should eq(d("1580.00"))
      statement.overdue.should eq(d("380.00"))
      statement.ageing.not_due.should eq(d("1200.00"))
      statement.ageing.days_1_30.should eq(d("60.00"))
      statement.ageing.days_31_60.should eq(d("200.00"))
      statement.ageing.over_60.should eq(d("120.00"))
      statement.ageing.total.should eq(statement.remaining)
      statement.total_debit.should eq(d("1632.00"))
      statement.total_credit.should eq(d("52"))

      statement.lines.size.should eq(7)
      statement.lines.map(&.balance).should eq([
        d("120.00"), d("132.00"), d("120.00"), d("360.00"), d("420.00"), d("1620.00"), d("1580.00"),
      ])
      first = statement.lines.first
      first.entry_id.should eq(old.id)
      first.ledger_code.should eq("V01")
      first.receipt.should eq(old.receipt)
      first.label.should eq("Facture 100")
      first.overdue.should be_true
      statement.lines.find! { |line| line.entry_id == paid.id }.overdue.should be_false
      statement.lines.find! { |line| line.entry_id == future.id }.overdue.should be_false
      statement.lines.find! { |line| line.entry_id == paid.id }.matching_code.should_not be_nil
      recent.id.should be > 0

      open_only = Api.account_statement(system, query.copy_with(unmatched_only: true))
      open_only.lines.map(&.entry_id).should_not contain(paid.id)
      open_only.lines.size.should eq(5)

      window = Api.account_statement(system, query.copy_with(date_from: EntrySpec.date("2026-02-01"),
        date_to: EntrySpec.date("2026-02-28")))
      window.opening_balance.should eq(d("120.00"))
      window.lines.map(&.entry_id).should eq([mid.id])
      window.balance.should eq(d("360.00"))
    end

    it "consulte un compte par son numéro, créditeur pour un fournisseur" do
      EntrySpec.setup
      supplier = EntrySpec.card("SUPPLIER", "Fournisseur")
      Api.post_purchase(system, EntrySpec.document("A01", supplier.code, [EntrySpec.item("100", account: "603")])).value!
      statement = Api.account_statement(system, Api::StatementQuery.new(account: EntrySpec.card_account(supplier),
        as_of: EntrySpec.date("2026-03-15")))
      statement.balance.should eq(d("-120.00"))
      statement.remaining.should eq(d("-120.00"))
      statement.overdue.should eq(d("0"))
      statement.ageing.not_due.should eq(d("-120.00"))
      statement.card_id.should be_nil
      expect_raises(Partiduo::Api::NotFound) { Api.account_statement(system, Api::StatementQuery.new(account: "999")) }
      expect_raises(Partiduo::Api::NotFound) { Api.account_statement(system, Api::StatementQuery.new(card: "NOPE")) }
    end
  end

  describe ".party_balances" do
    it "agrège reste dû et échu des clients et des fournisseurs comme les relevés (D-2F-005)" do
      EntrySpec.setup
      first = EntrySpec.card("CUSTOMER", "Client A")
      second = EntrySpec.card("CUSTOMER", "Client B")
      silent = EntrySpec.card("CUSTOMER", "Client sans mouvement")
      sale(first, "100", "2026-01-05", "2026-01-20")           # 120, échue
      partial = sale(first, "200", "2026-02-01", "2026-03-01") # 240, échue, 40 payés
      pay(first, "40", "2026-03-30", [line_of(partial, first)])
      sale(second, "1000", "2026-03-20", "2026-04-30") # 1200, non échue
      settled = sale(second, "10", "2026-01-10")       # 12, payée
      pay(second, "12", "2026-01-15", [line_of(settled, second)])
      supplier = EntrySpec.card("SUPPLIER", "Fournisseur")
      Api.post_purchase(system, EntrySpec.document("A01", supplier.code, [EntrySpec.item("100", account: "603")],
        "2026-01-10")).value!
      as_of = EntrySpec.date("2026-04-02")

      customers = Api.party_balances(system, "customer", as_of)
      statements = [first, second, silent].map do |card|
        Api.account_statement(system, Api::StatementQuery.new(card: card.code, as_of: as_of))
      end
      customers.remaining.should eq(statements.sum(BigDecimal.new(0), &.remaining))
      customers.overdue.should eq(statements.sum(BigDecimal.new(0), &.overdue))
      customers.remaining.should eq(d("1520"))
      customers.overdue.should eq(d("320"))
      customers.cards.should eq(2)
      customers.worst_card_code.should eq(first.code)
      customers.worst_card_name.should eq("Client A")
      customers.worst_overdue.should eq(d("320"))

      suppliers = Api.party_balances(system, "supplier", as_of)
      suppliers.remaining.should eq(d("-120"))
      suppliers.overdue.should eq(d("-120"))
      suppliers.worst_card_code.should eq(supplier.code)

      nothing = Api.party_balances(system, "customer", EntrySpec.date("2026-01-01"))
      nothing.overdue.should eq(BigDecimal.new(0))
      nothing.worst_card_code.should be_nil
      expect_raises(Partiduo::Api::Forbidden) { Api.party_balances(actor_with("cards.card.read"), "customer") }
    end
  end
end
