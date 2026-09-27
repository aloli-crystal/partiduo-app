# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    # Contrat du module Comptabilité — fin d'exercice : écriture de clôture
    # des comptes de charges et de produits, écriture de réouverture
    # (à-nouveaux) de l'exercice suivant (héritières d'`Operation_Closing`
    # et d'`Operation_Opening`, D-CLO-001). Documentation :
    # `doc/api/accounting-closing.adoc`.
    module Accounting
      # Ligne proposée. `result` : ligne du compte de résultat, calculée ;
      # `card_disabled` : la fiche est désactivée, la ligne sera passée sur le
      # compte seul.
      record ClosingLineView,
        account : String,
        account_label : String,
        card_id : Int64?,
        card_code : String?,
        card_name : String?,
        card_disabled : Bool,
        side : Side,
        amount : BigDecimal,
        result : Bool = false

      # Écriture proposée. `kind` : `closing` ou `opening` ; `date` : dernier
      # jour de l'exercice (clôture) ou premier jour (réouverture) ;
      # `source_fiscal_year_id` : exercice dont les soldes sont repris ;
      # `result_account_missing` : le compte de résultat n'existe pas ou
      # n'est pas utilisable directement ; `posted_entry_id` : écriture déjà
      # passée (une seule par exercice et par sorte).
      record ClosingProposalView,
        kind : String,
        fiscal_year_id : Int64,
        source_fiscal_year_id : Int64?,
        date : Time?,
        profit_account : String,
        loss_account : String,
        lines : Array(ClosingLineView),
        result_account_missing : Bool,
        posted_entry_id : Int64? do
        def debit : BigDecimal
          lines.select(&.side.debit?).sum(BigDecimal.new(0), &.amount)
        end

        def credit : BigDecimal
          lines.select(&.side.credit?).sum(BigDecimal.new(0), &.amount)
        end

        # Résultat de l'exercice : positif pour un bénéfice.
        def result : BigDecimal
          line = lines.find(&.result)
          return BigDecimal.new(0) if line.nil?
          line.side.credit? ? line.amount : -line.amount
        end

        def posted? : Bool
          !posted_entry_id.nil?
        end
      end

      # Passage d'une écriture de fin d'exercice dans un journal
      # d'opérations diverses. Comptes de résultat vides : ceux que propose
      # le régime.
      record ClosingInput,
        fiscal_year_id : Int64,
        ledger_id : Int64,
        profit_account : String? = nil,
        loss_account : String? = nil,
        label : String? = nil

      # Clôture proposée d'un exercice : comptes 6 et 7 soldés, résultat au
      # compte de bénéfice ou de perte.
      def self.closing_proposal(actor : Actor, fiscal_year_id : Int64, profit_account : String? = nil,
                                loss_account : String? = nil) : ClosingProposalView
        Guard.authorize!(actor, "accounting.period.close", module_code: MODULE_CODE)
        year = Partiduo::Api::Core.fiscal_year(actor, fiscal_year_id)
        profit, loss = result_accounts(profit_account, loss_account)
        from, to = year.starts_on, year.ends_on
        balances = from && to ? Partiduo::Accounting::Closing.balances(from, to, true, false) : [] of Partiduo::Accounting::Closing::Balance
        lines = balances.map { |balance| Partiduo::Accounting::Closing.line(balance, true, {} of Int64 => Partiduo::Api::Cards::CardView) }
        proposal("closing", year.id, year.id, to, profit, loss, lines)
      end

      # Réouverture proposée d'un exercice : soldes des comptes hors classes
      # 6 et 7 à la fin de l'exercice précédent (celui qui s'achève la veille
      # de son premier jour), par compte et par fiche.
      def self.opening_proposal(actor : Actor, fiscal_year_id : Int64, profit_account : String? = nil,
                                loss_account : String? = nil) : ClosingProposalView
        Guard.authorize!(actor, "accounting.period.close", module_code: MODULE_CODE)
        year = Partiduo::Api::Core.fiscal_year(actor, fiscal_year_id)
        profit, loss = result_accounts(profit_account, loss_account)
        previous = previous_year(actor, year)
        lines = [] of ClosingLineView
        if previous && (from = previous.starts_on) && (to = previous.ends_on)
          balances = Partiduo::Accounting::Closing.balances(from, to, false, true)
          cards = Partiduo::Accounting::Closing.cards(balances)
          lines = balances.map { |balance| Partiduo::Accounting::Closing.line(balance, false, cards) }
        end
        proposal("opening", year.id, previous.try(&.id), year.starts_on, profit, loss, lines)
      end

      # Passe l'écriture de clôture proposée, au dernier jour de l'exercice.
      #
      # Erreurs : `accounting.errors.closing.already_posted`, `.nothing`,
      # `.ledger_kind`, `.fiscal_year_closed`, et celles de `post_entry`
      # (compte de résultat inconnu, période close…).
      def self.post_closing_entry(actor : Actor, input : ClosingInput) : Result(EntryView)
        post_year_end(actor, input, "closing")
      end

      # Passe l'écriture de réouverture proposée, au premier jour de
      # l'exercice. Erreurs : celles de `post_closing_entry`, et
      # `accounting.errors.closing.no_previous` (aucun exercice ne s'achève
      # la veille).
      def self.post_opening_entry(actor : Actor, input : ClosingInput) : Result(EntryView)
        post_year_end(actor, input, "opening")
      end

      private def self.post_year_end(actor : Actor, input : ClosingInput, kind : String) : Result(EntryView)
        Guard.authorize!(actor, "accounting.period.close", module_code: MODULE_CODE)
        Guard.authorize!(actor, "accounting.entry.post", module_code: MODULE_CODE)
        Transaction.run do
          # Deux passages concurrents : le second attend le premier, puis voit
          # son écriture (l'index unique de `source` le refuserait sinon).
          Partiduo::Accounting::Closing.lock(input.fiscal_year_id)
          proposal = if kind == "closing"
                       closing_proposal(actor, input.fiscal_year_id, input.profit_account, input.loss_account)
                     else
                       opening_proposal(actor, input.fiscal_year_id, input.profit_account, input.loss_account)
                     end
          errors = year_end_errors(actor, proposal, input)
          date = proposal.date
          next Result(EntryView).failure(errors) unless errors.empty? && date

          year = Partiduo::Api::Core.fiscal_year(actor, input.fiscal_year_id)
          label = input.label.try(&.strip).presence ||
                  I18n.t("accounting.closing.#{kind}_label", year: year.label)
          lines = proposal.lines.map do |line|
            card = line.card_disabled ? nil : line.card_code
            EntryLineInput.new(account: line.account, side: line.side, amount: line.amount, card: card)
          end
          entry = EntryInput.new(
            ledger_id: input.ledger_id, date: date, lines: lines, label: label,
            source: Partiduo::Accounting::Closing.source(kind, input.fiscal_year_id),
          )
          post_entry(actor, entry)
        end
      end

      private def self.year_end_errors(actor : Actor, proposal : ClosingProposalView, input : ClosingInput) : Array(FieldError)
        errors = [] of FieldError
        if proposal.posted?
          errors << FieldError.base("accounting.errors.closing.already_posted")
          return errors
        end
        if proposal.kind == "opening" && proposal.source_fiscal_year_id.nil?
          errors << FieldError.base("accounting.errors.closing.no_previous")
          return errors
        end
        errors << FieldError.base("accounting.errors.closing.nothing") if proposal.lines.empty? || proposal.date.nil?
        if Partiduo::Api::Core.fiscal_year(actor, input.fiscal_year_id).closed?
          errors << FieldError.base("accounting.errors.closing.fiscal_year_closed")
        end
        ledger = Partiduo::Accounting::Ledger.filter(id: input.ledger_id).first || raise NotFound.new("ledger", input.ledger_id)
        unless ledger.kind == LedgerKind::Misc.code
          errors << FieldError.new("ledger_id", "accounting.errors.closing.ledger_kind", {"code" => ledger.code.to_s})
        end
        errors
      end

      private def self.result_accounts(profit : String?, loss : String?) : {String, String}
        default_profit, default_loss = Partiduo::Accounting::Closing.default_result_accounts
        {
          Partiduo::Accounting::Chart.normalize(profit.try(&.strip).presence || default_profit),
          Partiduo::Accounting::Chart.normalize(loss.try(&.strip).presence || default_loss),
        }
      end

      # Exercice qui s'achève la veille du premier jour de `year`.
      private def self.previous_year(actor : Actor, year : Partiduo::Api::Core::FiscalYearView) : Partiduo::Api::Core::FiscalYearView?
        starts = year.starts_on
        return if starts.nil?
        Partiduo::Api::Core.fiscal_years(actor).find { |other| other.ends_on == starts - 1.day }
      end

      private def self.proposal(kind : String, fiscal_year_id : Int64, source_id : Int64?, date : Time?, profit : String,
                                loss : String, lines : Array(ClosingLineView)) : ClosingProposalView
        result = Partiduo::Accounting::Closing.result_line(lines, profit, loss)
        lines << result if result
        missing = result ? !usable_account?(result.account) : false
        ClosingProposalView.new(
          kind: kind, fiscal_year_id: fiscal_year_id, source_fiscal_year_id: source_id, date: date,
          profit_account: profit, loss_account: loss, lines: lines, result_account_missing: missing,
          posted_entry_id: Partiduo::Accounting::Closing.posted_entry_id(Partiduo::Accounting::Closing.source(kind, fiscal_year_id)),
        )
      end

      private def self.usable_account?(number : String) : Bool
        Partiduo::Accounting::Account.filter(number: number, direct_use: true).exists?
      end
    end
  end
end
