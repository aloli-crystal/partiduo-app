# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Balances (lot 3) : balance générale (`Acc_Balance`), balance des tiers
# (`balance_card.inc.php`), balance âgée (`Balance_Age`).

private alias Api = Partiduo::Api::Accounting

private def system
  Partiduo::Api::Actor.system
end

private def d(text : String) : BigDecimal
  BigDecimal.new(text)
end

private def date(text : String) : Time
  EntrySpec.date(text)
end

private def row(view : Api::TrialBalanceView, number : String) : Api::TrialBalanceRowView
  view.rows.find(&.number.==(number)) || raise "compte #{number} absent de la balance"
end

describe_module "ACCOUNTING", "Balances" do
  describe ".trial_balance" do
    it "totalise les mouvements par compte, avec soldes, classes et synthèse" do
      data = ReportSpec.dataset
      customer_account = EntrySpec.card_account(data.customer)
      view = Api.trial_balance(system, Api::TrialBalanceQuery.new(date_to: date("2026-12-31")))

      view.date_from.should eq(date("2026-01-01"))
      view.date_to.should eq(date("2026-12-31"))
      view.total.debit.should eq(d("12880"))
      view.total.credit.should eq(d("12880"))
      view.delta.should eq(0)
      view.rows.map(&.number).should eq(view.rows.map(&.number).sort!)

      row(view, "706").credit.should eq(d("1300"))
      row(view, "706").closing.credit.should eq(d("1300"))
      row(view, "706").lines.should eq(2)
      row(view, "706").kind.should eq(Api::AccountKind::Income)
      customer = row(view, customer_account)
      customer.debit.should eq(d("1560"))
      customer.credit.should eq(d("600"))
      customer.closing.debit.should eq(d("960"))
      customer.closing.credit.should eq(0)

      view.classes.map(&.number).should eq(%w[1 2 4 5 6 7])
      view.classes.find!(&.number.==("7")).closing.credit.should eq(d("1300"))
      view.classes.find!(&.number.==("6")).closing.debit.should eq(d("620"))
      view.summary.expenses.should eq(d("620"))
      view.summary.income.should eq(d("-1300"))
      view.summary.result.should eq(d("680"))
      view.summary.balance_sheet.should eq(d("680"))
      # Totaux des soldes : colonne par colonne, sans compensation.
      view.total.closing.debit.should eq(view.rows.sum(BigDecimal.new(0), &.closing.debit))
    end

    it "reporte en ouverture les lignes de l'exercice antérieures à date_from" do
      data = ReportSpec.dataset
      customer_account = EntrySpec.card_account(data.customer)
      view = Api.trial_balance(system, Api::TrialBalanceQuery.new(date_from: date("2026-03-01"), date_to: date("2026-06-30")))
      customer = row(view, customer_account)
      customer.opening.debit.should eq(d("1200"))
      customer.debit.should eq(0)
      customer.credit.should eq(d("600"))
      customer.closing.debit.should eq(d("600"))
      customer.lines.should eq(1)
      row(view, "101").opening.credit.should eq(d("10000"))
      row(view, "101").lines.should eq(0)
      view.rows.any?(&.number.==("706")).should be_true
      view.total.opening.debit.should eq(view.total.opening.credit)
    end

    it "filtre par comptes, journaux et soldes non nuls" do
      ReportSpec.dataset
      by_range = Api.trial_balance(system, Api::TrialBalanceQuery.new(account_from: "6", account_to: "7"))
      by_range.rows.map(&.number).should eq(%w[6061 681 706])
      sales = Api.trial_balance(system, Api::TrialBalanceQuery.new(ledger_kinds: [Api::LedgerKind::Sale]))
      sales.total.debit.should eq(d("1560"))
      misc = Api.trial_balance(system, Api::TrialBalanceQuery.new(ledger_ids: [EntrySpec.ledger("O01").id]))
      misc.rows.map(&.number).should eq(%w[101 281 510001 681])

      # Compte soldé : la vente et son règlement complet.
      customer = EntrySpec.card("CUSTOMER", "Client soldé")
      sale = Api.post_sale(system, EntrySpec.document("V01", customer.code, [EntrySpec.item("100", account: "706")],
        "2026-08-01")).value!
      Api.post_financial(system, Api::FinancialInput.new(ledger_id: EntrySpec.ledger("F01").id,
        date: date("2026-08-02"), lines: [Api::PaymentLineInput.new(d("120"), card: customer.code,
        match_line_ids: [sale.lines.find! { |line| line.card_id == customer.id }.id])]))
      account = EntrySpec.card_account(customer)
      Api.trial_balance(system).rows.any?(&.number.==(account)).should be_true
      Api.trial_balance(system, Api::TrialBalanceQuery.new(nonzero_only: true)).rows.any?(&.number.==(account)).should be_false
    end

    it "exige la permission des éditions et le module Comptabilité" do
      ReportSpec.dataset
      expect_raises(Partiduo::Api::Forbidden) { Api.trial_balance(actor_with("accounting.entry.read")) }
      _, reader = AccountingSpec.user_actor("lecteur@example.test", "accounting.report.read")
      Api.trial_balance(reader).total.debit.should eq(d("12880"))
      with_active_modules("invoicing") do
        expect_raises(Partiduo::Api::ModuleDisabled) { Api.trial_balance(system) }
      end
    end
  end

  describe ".auxiliary_balance" do
    it "totalise par fiche de tiers" do
      data = ReportSpec.dataset
      view = Api.auxiliary_balance(system)
      view.rows.map(&.card_code).should eq([data.customer.code, data.supplier.code])
      customer = view.rows.first
      customer.card_name.should eq("Client Alpha")
      customer.account_number.should eq(EntrySpec.card_account(data.customer))
      customer.debit.should eq(d("1560"))
      customer.credit.should eq(d("600"))
      customer.closing.debit.should eq(d("960"))
      view.rows.last.closing.credit.should eq(d("600"))
      view.total.closing.debit.should eq(d("960"))
      view.total.closing.credit.should eq(d("600"))

      Api.auxiliary_balance(system, Api::AuxiliaryBalanceQuery.new(kind: "supplier")).rows.map(&.card_code)
        .should eq([data.supplier.code])
      later = Api.auxiliary_balance(system, Api::AuxiliaryBalanceQuery.new(date_from: date("2026-07-01")))
      later.rows.first.opening.debit.should eq(d("600"))
      later.rows.first.debit.should eq(d("360"))
      # Seules les fiches de tiers : pas l'article, pas la banque.
      view.rows.none?(&.card_kind.==("item")).should be_true
    end
  end

  describe ".aged_balance" do
    it "classe les éléments ouverts par ancienneté, comme le relevé" do
      data = ReportSpec.dataset
      view = Api.aged_balance(system, Api::AgedBalanceQuery.new(as_of: date("2026-09-27")))
      view.rows.map(&.card_code).should eq([data.customer.code, data.supplier.code])
      customer = view.rows.first
      customer.remaining.should eq(d("960"))
      customer.overdue.should eq(d("960"))
      customer.ageing.days_31_60.should eq(d("360"))
      customer.ageing.over_60.should eq(d("600"))
      customer.items.size.should eq(2)
      partial = customer.items.find!(&.matching_code)
      partial.amount.should eq(d("600"))
      partial.date.should eq(date("2026-03-01"))
      partial.entry_id.should be_nil
      view.rows.last.ageing.over_60.should eq(d("-600"))
      view.remaining.should eq(d("360"))

      [data.customer, data.supplier].each do |card|
        statement = Api.account_statement(system, Api::StatementQuery.new(card: card.code, as_of: date("2026-09-27"),
          date_to: date("2026-09-27")))
        row = view.rows.find!(&.card_id.==(card.id))
        row.ageing.should eq(statement.ageing)
        row.remaining.should eq(statement.remaining)
        row.overdue.should eq(statement.overdue)
      end
    end

    it "arrête la balance à as_of : un règlement postérieur ne compte pas" do
      data = ReportSpec.dataset
      before = Api.aged_balance(system, Api::AgedBalanceQuery.new(as_of: date("2026-03-01"), card: data.customer.code))
      before.rows.size.should eq(1)
      before.rows.first.remaining.should eq(d("1200"))
      before.rows.first.ageing.not_due.should eq(d("1200"))
      Api.aged_balance(system, Api::AgedBalanceQuery.new(kind: "supplier")).rows.map(&.card_code).should eq([data.supplier.code])
      expect_raises(Partiduo::Api::NotFound) { Api.aged_balance(system, Api::AgedBalanceQuery.new(card: "INCONNU")) }
    end
  end
end
