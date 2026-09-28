# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    # Contrat du module Comptabilité — rapprochement bancaire (ADR-006 D1,
    # héritier de `compta_fin_rec.inc.php`) : les opérations d'un journal
    # financier sont rattachées au relevé de la banque qui les porte ; le
    # total rapproché doit égaler l'écart entre les soldes de début et de fin
    # du relevé. Documentation : `doc/api/accounting-reconciliation.adoc`.
    module Accounting
      # Opération d'un journal financier ; `amount` : montant pour la banque
      # (entrée positive, sortie négative).
      record ReconciliationLineView,
        entry_id : Int64,
        date : Time,
        receipt : String?,
        internal_code : String,
        label : String,
        amount : BigDecimal,
        statement_id : Int64?,
        statement_reference : String?

      record BankStatementView,
        id : Int64,
        ledger_id : Int64,
        ledger_code : String,
        reference : String,
        start_balance : BigDecimal?,
        end_balance : BigDecimal?,
        amount : BigDecimal,
        entry_count : Int32,
        attachment_id : Int64?,
        created_by_id : Int64?,
        created_at : Time

      # État du rapprochement d'un journal financier : soldes du compte de sa
      # fiche Banque (tous journaux) entre `date_from` et `date_to`, part
      # rapprochée et non rapprochée, opérations du journal sans relevé,
      # relevés déjà rapprochés (du plus récent au plus ancien).
      record ReconciliationView,
        ledger_id : Int64,
        ledger_code : String,
        ledger_name : String,
        account_number : String?,
        date_from : Time?,
        date_to : Time?,
        balance : BigDecimal,
        reconciled_balance : BigDecimal,
        unreconciled_balance : BigDecimal,
        unreconciled : Array(ReconciliationLineView),
        statements : Array(BankStatementView) do
        def unreconciled_total : BigDecimal
          unreconciled.sum(BigDecimal.new(0), &.amount)
        end
      end

      record BankStatementDetailView, statement : BankStatementView, lines : Array(ReconciliationLineView)

      # Rapprochement d'un relevé. Soldes de début et de fin donnés tous
      # deux et différents : le total des opérations cochées doit égaler leur
      # écart (règle d'origine).
      record ReconcileInput,
        ledger_id : Int64,
        reference : String,
        entry_ids : Array(Int64),
        start_balance : BigDecimal? = nil,
        end_balance : BigDecimal? = nil,
        attachment_id : Int64? = nil

      MAX_STATEMENT_REFERENCE = 40

      # Journaux financiers visibles de l'acteur (choix du journal à rapprocher).
      def self.reconciliation(actor : Actor, ledger_id : Int64, date_from : Time? = nil,
                              date_to : Time? = nil) : ReconciliationView
        Guard.authorize!(actor, "accounting.entry.read", module_code: MODULE_CODE)
        ledger = financial_ledger!(actor, ledger_id, write: false)
        bank = Partiduo::Accounting::Reconciliation.bank(ledger)
        entries = Partiduo::Accounting::Entry.filter(ledger_id: ledger.id, statement_id: nil).order(:date, :id).to_a
        amounts = Partiduo::Accounting::Reconciliation.amounts(entries.map(&.id!.to_i64), bank)
        lines = entries.map do |entry|
          Partiduo::Accounting::Reconciliation.line_view(entry, amounts[entry.id!.to_i64]? || BigDecimal.new(0), nil)
        end
        total, reconciled, unreconciled = Partiduo::Accounting::Reconciliation.balances(bank, date_from, date_to)
        account = bank.try { |(account_id, _)| Partiduo::Accounting::Account.get(id: account_id).try(&.number.to_s) }
        ReconciliationView.new(
          ledger_id: ledger.id!.to_i64, ledger_code: ledger.code.to_s, ledger_name: ledger.name.to_s,
          account_number: account, date_from: date_from, date_to: date_to, balance: total,
          reconciled_balance: reconciled, unreconciled_balance: unreconciled, unreconciled: lines,
          statements: bank_statements(actor, ledger_id),
        )
      end

      def self.bank_statements(actor : Actor, ledger_id : Int64) : Array(BankStatementView)
        Guard.authorize!(actor, "accounting.entry.read", module_code: MODULE_CODE)
        ledger = financial_ledger!(actor, ledger_id, write: false)
        Partiduo::Accounting::BankStatement.filter(ledger_id: ledger.id).order("-created_at", "-id").map do |statement|
          Partiduo::Accounting::Reconciliation.statement_view(statement, ledger)
        end
      end

      def self.bank_statement(actor : Actor, id : Int64) : BankStatementDetailView
        Guard.authorize!(actor, "accounting.entry.read", module_code: MODULE_CODE)
        statement = Partiduo::Accounting::BankStatement.get(id: id) || raise NotFound.new("bank_statement", id)
        ledger = financial_ledger!(actor, statement.ledger_id!.as(Int).to_i64, write: false)
        entries = Partiduo::Accounting::Entry.filter(statement_id: statement.id).order(:date, :id).to_a
        amounts = Partiduo::Accounting::Reconciliation.amounts(entries.map(&.id!.to_i64), Partiduo::Accounting::Reconciliation.bank(ledger))
        lines = entries.map do |entry|
          Partiduo::Accounting::Reconciliation.line_view(entry, amounts[entry.id!.to_i64]? || BigDecimal.new(0), statement)
        end
        BankStatementDetailView.new(Partiduo::Accounting::Reconciliation.statement_view(statement, ledger), lines)
      end

      # Rattache les opérations cochées au relevé `reference` (créé).
      #
      # Erreurs : `accounting.errors.reconciliation.reference.blank`,
      # `.reference.too_long`, `.reference.taken`, `.entries.blank`,
      # `.entries.invalid` (`%{id}`), `.mismatch` (`%{expected}`,
      # `%{selected}`, `%{difference}`), `.ledger_kind`.
      def self.reconcile(actor : Actor, input : ReconcileInput) : Result(BankStatementView)
        Guard.authorize!(actor, "accounting.matching.write", module_code: MODULE_CODE)
        ledger = financial_ledger!(actor, input.ledger_id, write: true)
        reference = input.reference.strip
        errors = [] of FieldError
        if reference.empty?
          errors << FieldError.new("reference", "accounting.errors.reconciliation.reference.blank")
        elsif reference.size > MAX_STATEMENT_REFERENCE
          errors << FieldError.new("reference", "accounting.errors.reconciliation.reference.too_long",
            {"max" => MAX_STATEMENT_REFERENCE.to_s})
        end
        ids = input.entry_ids.uniq
        errors << FieldError.new("entry_ids", "accounting.errors.reconciliation.entries.blank") if ids.empty?
        return Result(BankStatementView).failure(errors) unless errors.empty?

        Transaction.run do
          entries = Partiduo::Accounting::Entry.all.lock.filter(id__in: ids).to_a
          errors = selection_errors(ledger, reference, ids, entries)
          next Result(BankStatementView).failure(errors) unless errors.empty?
          if mismatch = mismatch_error(ledger, ids, input)
            next Result(BankStatementView).failure(mismatch)
          end

          statement = Partiduo::Accounting::BankStatement.create!(
            ledger_id: ledger.id, reference: reference, start_balance: input.start_balance,
            end_balance: input.end_balance, attachment_id: input.attachment_id, created_by_id: actor.user_id,
          )
          entries.each do |entry|
            entry.statement_id = statement.id!.to_i64
            entry.save!
          end
          Result(BankStatementView).success(Partiduo::Accounting::Reconciliation.statement_view(statement, ledger))
        end
      end

      # Annule un rapprochement : les opérations du relevé redeviennent non
      # rapprochées, le relevé disparaît.
      def self.unreconcile(actor : Actor, statement_id : Int64) : Result(Nil)
        Guard.authorize!(actor, "accounting.matching.write", module_code: MODULE_CODE)
        Transaction.run do
          statement = Partiduo::Accounting::BankStatement.all.lock.filter(id: statement_id).first ||
                      raise NotFound.new("bank_statement", statement_id)
          financial_ledger!(actor, statement.ledger_id!.as(Int).to_i64, write: true)
          Partiduo::Accounting::Entry.filter(statement_id: statement.id).each do |entry|
            entry.statement_id = nil
            entry.save!
          end
          statement.delete
          Result(Nil).success(nil)
        end
      end

      # Opérations du journal, non rapprochées ; numéro libre dans le journal.
      private def self.selection_errors(ledger : Partiduo::Accounting::Ledger, reference : String, ids : Array(Int64),
                                        entries : Array(Partiduo::Accounting::Entry)) : Array(FieldError)
        errors = [] of FieldError
        ids.each do |id|
          entry = entries.find(&.id.==(id))
          if entry.nil? || entry.ledger_id != ledger.id || !entry.statement_id.nil?
            errors << FieldError.new("entry_ids", "accounting.errors.reconciliation.entries.invalid", {"id" => id.to_s})
          end
        end
        if Partiduo::Accounting::BankStatement.filter(ledger_id: ledger.id, reference: reference).exists?
          errors << FieldError.new("reference", "accounting.errors.reconciliation.reference.taken", {"reference" => reference})
        end
        errors
      end

      # Règle d'origine : soldes donnés et différents, le total coché doit
      # égaler leur écart.
      private def self.mismatch_error(ledger : Partiduo::Accounting::Ledger, ids : Array(Int64), input : ReconcileInput) : FieldError?
        start, finish = input.start_balance, input.end_balance
        return if start.nil? || finish.nil?
        expected = finish - start
        amounts = Partiduo::Accounting::Reconciliation.amounts(ids, Partiduo::Accounting::Reconciliation.bank(ledger))
        selected = amounts.values.sum(BigDecimal.new(0))
        return if expected.zero? || expected == selected
        FieldError.base("accounting.errors.reconciliation.mismatch", {
          "expected"   => Partiduo::Accounting::Reconciliation.raw(expected),
          "selected"   => Partiduo::Accounting::Reconciliation.raw(selected),
          "difference" => Partiduo::Accounting::Reconciliation.raw(selected - expected),
        })
      end

      # Journal financier que l'acteur peut lire (ou écrire) ; `NotFound`
      # s'il ne le voit pas, `Forbidden` s'il ne peut y écrire.
      private def self.financial_ledger!(actor : Actor, ledger_id : Int64, write : Bool) : Partiduo::Accounting::Ledger
        ledger = Partiduo::Accounting::Ledger.filter(id: ledger_id).first || raise NotFound.new("ledger", ledger_id)
        access = Partiduo::Accounting::Ledgers.access(actor, ledger_id)
        raise NotFound.new("ledger", ledger_id) unless Partiduo::Accounting::Ledgers.visible?(actor, access)
        raise Forbidden.new("accounting.matching.write") if write && !access.writable?
        unless ledger.kind == LedgerKind::Financial.code
          raise NotFound.new("ledger", ledger_id)
        end
        ledger
      end
    end
  end
end
