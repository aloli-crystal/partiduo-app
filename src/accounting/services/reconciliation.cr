# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Accounting
    # Rapprochement bancaire, héritier de `compta_fin_rec.inc.php` : les
    # opérations d'un journal financier qui ne citent encore aucun relevé,
    # leur montant du point de vue de la banque (`quant_fin.qf_amount` : la
    # ligne du compte de la fiche Banque, débit positif), les soldes du
    # compte, rapproché et non rapproché. Service interne.
    module Reconciliation
      alias Api = Partiduo::Api::Accounting

      ZERO = BigDecimal.new(0)

      # Montant en paramètre d'un message : deux décimales, point décimal
      # (l'interface le présente selon la langue).
      def self.raw(value : BigDecimal) : String
        integer, _, decimals = value.round(2, mode: :ties_away).to_s.partition('.')
        "#{integer}.#{decimals.ljust(2, '0')}"
      end

      # Compte et fiche Banque du journal ; `nil` s'il n'en a pas.
      def self.bank(ledger : Ledger) : {Int64, Int64}?
        card_id = ledger.bank_card_id.try(&.to_i64)
        account = Ledgers.account_of(ledger)
        return if card_id.nil? || account.nil?
        {account.id!.to_i64, card_id}
      end

      # Montant des écritures pour la banque (débit positif), par écriture.
      def self.amounts(entry_ids : Array(Int64), bank : {Int64, Int64}?) : Hash(Int64, BigDecimal)
        result = {} of Int64 => BigDecimal
        return result if entry_ids.empty? || bank.nil?
        account_id, card_id = bank
        sql = <<-SQL
          SELECT x.entry_id, sum(CASE WHEN x.side = 'debit' THEN x.amount ELSE -x.amount END)
          FROM accounting_entry_line x
          WHERE x.entry_id = ANY($1) AND x.account_id = $2 AND x.card_id = $3
          GROUP BY x.entry_id
          SQL
        Marten::DB::Connection.default.open do |db|
          db.query_each(sql, args: [entry_ids, account_id, card_id]) do |result_set|
            result[result_set.read(Int64)] = result_set.read(BigDecimal)
          end
        end
        result
      end

      # Soldes du compte de la fiche Banque (tous journaux) entre deux dates :
      # total, part des écritures rapprochées, part des autres.
      def self.balances(bank : {Int64, Int64}?, from : Time?, to : Time?) : {BigDecimal, BigDecimal, BigDecimal}
        return {ZERO, ZERO, ZERO} if bank.nil?
        account_id, card_id = bank
        args = [account_id, card_id] of ::DB::Any
        clauses = ["x.account_id = $1", "x.card_id = $2"]
        from.try { |day| args << day; clauses << "e.date >= $#{args.size}::date" }
        to.try { |day| args << day; clauses << "e.date <= $#{args.size}::date" }
        sql = <<-SQL
          SELECT COALESCE(sum(CASE WHEN x.side = 'debit' THEN x.amount ELSE -x.amount END), 0),
                 COALESCE(sum(CASE WHEN x.side = 'debit' THEN x.amount ELSE -x.amount END)
                   FILTER (WHERE e.statement_id IS NOT NULL), 0)
          FROM accounting_entry_line x
          JOIN accounting_entry e ON e.id = x.entry_id
          WHERE #{clauses.join(" AND ")}
          SQL
        total, reconciled = Marten::DB::Connection.default.open do |db|
          db.query_one(sql, args: args, as: {BigDecimal, BigDecimal})
        end
        {total, reconciled, total - reconciled}
      end

      def self.line_view(entry : Entry, amount : BigDecimal, statement : BankStatement?) : Api::ReconciliationLineView
        Api::ReconciliationLineView.new(
          entry_id: entry.id!.to_i64, date: entry.date!, receipt: entry.receipt, internal_code: entry.internal_code.to_s,
          label: entry.label.to_s, amount: amount, statement_id: statement.try(&.id!.to_i64),
          statement_reference: statement.try(&.reference.to_s),
        )
      end

      def self.statement_view(statement : BankStatement, ledger : Ledger) : Api::BankStatementView
        entries = Entry.filter(statement_id: statement.id).to_a
        amounts = amounts(entries.map(&.id!.to_i64), bank(ledger))
        Api::BankStatementView.new(
          id: statement.id!.to_i64, ledger_id: ledger.id!.to_i64, ledger_code: ledger.code.to_s,
          reference: statement.reference.to_s, start_balance: statement.start_balance,
          end_balance: statement.end_balance, amount: amounts.values.sum(ZERO), entry_count: entries.size,
          attachment_id: statement.attachment_id.try(&.to_i64), created_by_id: statement.created_by_id.try(&.to_i64),
          created_at: statement.created_at!,
        )
      end
    end
  end
end
