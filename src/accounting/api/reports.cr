# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    # Contrat du module Comptabilité — éditions (lot 3) : balances générale,
    # des tiers et âgée, grand livre, journaux, bilan et compte de résultat
    # (FR et BE), rapports personnalisés (`form_definition`), FEC, et leur
    # export en CSV et en PDF. Types dans `report_types.cr` ; référence :
    # `doc/api/accounting-reports.adoc`.
    #
    # Toutes les éditions exigent `accounting.report.read` et ne lisent que
    # les journaux visibles de l'acteur ; le FEC exige en outre qu'il les
    # voie tous (un FEC est complet ou n'est pas).
    module Accounting
      REPORT_READ  = "accounting.report.read"
      REPORT_WRITE = "accounting.report.write"

      # --- Balances ------------------------------------------------------------------

      def self.trial_balance(actor : Actor, query : TrialBalanceQuery = TrialBalanceQuery.new) : TrialBalanceView
        Guard.authorize!(actor, REPORT_READ, module_code: MODULE_CODE)
        Partiduo::Accounting::Balances.trial_balance(query, readable_ledger_ids(actor))
      end

      def self.auxiliary_balance(actor : Actor, query : AuxiliaryBalanceQuery = AuxiliaryBalanceQuery.new) : AuxiliaryBalanceView
        Guard.authorize!(actor, REPORT_READ, module_code: MODULE_CODE)
        Partiduo::Accounting::Balances.auxiliary_balance(query, readable_ledger_ids(actor))
      end

      # `NotFound` si `query.card` ne désigne aucune fiche.
      def self.aged_balance(actor : Actor, query : AgedBalanceQuery = AgedBalanceQuery.new) : AgedBalanceView
        Guard.authorize!(actor, REPORT_READ, module_code: MODULE_CODE)
        Partiduo::Accounting::Balances.aged_balance(query, readable_ledger_ids(actor))
      end

      # --- Grand livre et journaux ---------------------------------------------------

      # `NotFound` si `query.card` ne désigne aucune fiche.
      def self.general_ledger(actor : Actor, query : GeneralLedgerQuery = GeneralLedgerQuery.new) : GeneralLedgerView
        Guard.authorize!(actor, REPORT_READ, module_code: MODULE_CODE)
        Partiduo::Accounting::LedgerReports.general_ledger(query, readable_ledger_ids(actor))
      end

      def self.journals(actor : Actor, query : JournalQuery = JournalQuery.new) : JournalView
        Guard.authorize!(actor, REPORT_READ, module_code: MODULE_CODE)
        Partiduo::Accounting::LedgerReports.journals(query, readable_ledger_ids(actor))
      end

      # --- Bilan et compte de résultat -----------------------------------------------

      # Régimes dont Partiduo connaît les états (`fr`, `be`).
      def self.statement_regimes(actor : Actor) : Array(String)
        Guard.authorize!(actor, REPORT_READ, module_code: MODULE_CODE)
        Partiduo::Accounting::Statements.regimes
      end

      # `NotFound` pour un régime sans état intégré.
      def self.financial_statement(actor : Actor, query : FinancialStatementQuery) : FinancialStatementView
        Guard.authorize!(actor, REPORT_READ, module_code: MODULE_CODE)
        regime = query.regime.try(&.strip.downcase.presence) || instance_regime
        Partiduo::Accounting::Statements.statement(query, regime, readable_ledger_ids(actor))
      end

      # --- Rapports personnalisés (`form_definition`) --------------------------------

      def self.reports(actor : Actor) : Array(ReportDefinitionView)
        Guard.authorize!(actor, REPORT_READ, module_code: MODULE_CODE)
        Partiduo::Accounting::Report.all.order(:name).map { |report| Partiduo::Accounting::ReportDefinitions.view(report) }
      end

      def self.report(actor : Actor, id : Int64) : ReportDefinitionView
        Guard.authorize!(actor, REPORT_READ, module_code: MODULE_CODE)
        Partiduo::Accounting::ReportDefinitions.view(find_report(id))
      end

      # Requête de contrôle de `create_report` / `update_report` : nom,
      # lignes, formules (erreur sous `lines[<i>].formula`).
      def self.check_report(actor : Actor, input : ReportDefinitionInput, id : Int64? = nil) : Result(Nil)
        Guard.authorize!(actor, REPORT_WRITE, module_code: MODULE_CODE)
        errors = Partiduo::Accounting::ReportDefinitions.errors(input, id)
        errors.empty? ? Result(Nil).success(nil) : Result(Nil).failure(errors)
      end

      def self.create_report(actor : Actor, input : ReportDefinitionInput) : Result(ReportDefinitionView)
        Guard.authorize!(actor, REPORT_WRITE, module_code: MODULE_CODE)
        Transaction.run do
          errors = Partiduo::Accounting::ReportDefinitions.errors(input)
          next Result(ReportDefinitionView).failure(errors) unless errors.empty?
          report = Partiduo::Accounting::ReportDefinitions.save!(Partiduo::Accounting::Report.new, input, actor)
          Result(ReportDefinitionView).success(Partiduo::Accounting::ReportDefinitions.view(report))
        end
      end

      # Remplace le nom et toutes les lignes.
      def self.update_report(actor : Actor, id : Int64, input : ReportDefinitionInput) : Result(ReportDefinitionView)
        Guard.authorize!(actor, REPORT_WRITE, module_code: MODULE_CODE)
        Transaction.run do
          report = Partiduo::Accounting::Report.filter(id: id).lock.first || raise NotFound.new("report", id)
          errors = Partiduo::Accounting::ReportDefinitions.errors(input, id)
          next Result(ReportDefinitionView).failure(errors) unless errors.empty?
          Partiduo::Accounting::ReportDefinitions.save!(report, input, actor)
          Result(ReportDefinitionView).success(Partiduo::Accounting::ReportDefinitions.view(report))
        end
      end

      def self.delete_report(actor : Actor, id : Int64) : Result(Nil)
        Guard.authorize!(actor, REPORT_WRITE, module_code: MODULE_CODE)
        Transaction.run do
          find_report(id).delete
          Result(Nil).success(nil)
        end
      end

      # Calcule un rapport de `date_from` à `date_to` (défauts des éditions).
      def self.run_report(actor : Actor, id : Int64, date_from : Time? = nil, date_to : Time? = nil) : ReportResultView
        Guard.authorize!(actor, REPORT_READ, module_code: MODULE_CODE)
        definition = Partiduo::Accounting::ReportDefinitions.view(find_report(id))
        from, to = Partiduo::Accounting::ReportData.range(date_from, date_to)
        Partiduo::Accounting::ReportDefinitions.run(definition, from, to, readable_ledger_ids(actor))
      end

      # --- Exports CSV et PDF ----------------------------------------------------------

      def self.export(actor : Actor, query : TrialBalanceQuery, format : ExportFormat) : FileView
        Partiduo::Accounting::ReportOutput.file(Partiduo::Accounting::ReportTables.trial_balance(trial_balance(actor, query)), format)
      end

      def self.export(actor : Actor, query : AuxiliaryBalanceQuery, format : ExportFormat) : FileView
        Partiduo::Accounting::ReportOutput.file(Partiduo::Accounting::ReportTables.auxiliary_balance(auxiliary_balance(actor, query)), format)
      end

      def self.export(actor : Actor, query : AgedBalanceQuery, format : ExportFormat) : FileView
        Partiduo::Accounting::ReportOutput.file(Partiduo::Accounting::ReportTables.aged_balance(aged_balance(actor, query)), format)
      end

      def self.export(actor : Actor, query : GeneralLedgerQuery, format : ExportFormat) : FileView
        Partiduo::Accounting::ReportOutput.file(Partiduo::Accounting::ReportTables.general_ledger(general_ledger(actor, query)), format)
      end

      def self.export(actor : Actor, query : JournalQuery, format : ExportFormat) : FileView
        Partiduo::Accounting::ReportOutput.file(Partiduo::Accounting::ReportTables.journals(journals(actor, query)), format)
      end

      def self.export(actor : Actor, query : FinancialStatementQuery, format : ExportFormat) : FileView
        Partiduo::Accounting::ReportOutput.file(Partiduo::Accounting::ReportTables.statement(financial_statement(actor, query)), format)
      end

      def self.export_report(actor : Actor, id : Int64, format : ExportFormat, date_from : Time? = nil,
                             date_to : Time? = nil) : FileView
        view = run_report(actor, id, date_from, date_to)
        Partiduo::Accounting::ReportOutput.file(Partiduo::Accounting::ReportTables.custom_report(view), format)
      end

      # --- FEC -------------------------------------------------------------------------

      # Fichier des écritures comptables d'un exercice (article A47 A-1 du
      # LPF). Refus : dates hors d'un même exercice (`date_from`), journaux
      # que l'acteur ne voit pas (`base`).
      def self.fec(actor : Actor, query : FecQuery = FecQuery.new) : Result(FileView)
        Guard.authorize!(actor, REPORT_READ, module_code: MODULE_CODE)
        readable = readable_ledger_ids(actor).to_set
        unless Partiduo::Accounting::Ledger.all.pluck(:id).all? { |row| readable.includes?(row.first.as(Int64)) }
          return Result(FileView).failure(FieldError.new(FieldError::BASE, "accounting.errors.fec.ledgers"))
        end
        range = Partiduo::Accounting::Fec.range(query) ||
                return Result(FileView).failure(FieldError.new("date_from", "accounting.errors.fec.fiscal_year"))
        name, content = Partiduo::Accounting::Fec.build(query, *range)
        charset = query.encoding.utf8? ? "utf-8" : "iso-8859-15"
        Result(FileView).success(FileView.new(name, "text/plain; charset=#{charset}", content))
      end

      private def self.find_report(id : Int64) : Partiduo::Accounting::Report
        Partiduo::Accounting::Report.filter(id: id).first || raise NotFound.new("report", id)
      end

      private def self.instance_regime : String
        Partiduo::Api::Core.settings(Actor.system).tax_regime.presence || "fr"
      rescue NotFound
        "fr"
      end
    end
  end
end
