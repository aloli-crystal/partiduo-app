# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Accounting
    # Grand livre (`impress_gl_comptes`, `impress_poste`) et journaux
    # (`impress_jrn`, `Print_Ledger_*`). Service interne.
    module LedgerReports
      alias Api = Partiduo::Api::Accounting

      ZERO = BigDecimal.new(0)

      record Line,
        line_id : Int64,
        entry_id : Int64,
        ledger_id : Int64,
        date : Time,
        ledger_code : String,
        receipt : String?,
        internal_code : String,
        entry_label : String,
        label : String,
        number : String,
        account_label : String,
        card_id : Int64?,
        debit : Bool,
        amount : BigDecimal,
        matching_id : Int64?,
        reversal_of_id : Int64? do
        def debit_amount : BigDecimal
          debit ? amount : ZERO
        end

        def credit_amount : BigDecimal
          debit ? ZERO : amount
        end
      end

      LINES_SQL = <<-SQL
        SELECT x.id, e.id, e.ledger_id, e.date, l.code, e.receipt, COALESCE(e.internal_code, ''), e.label,
               COALESCE(NULLIF(x.label, ''), e.label), a.number, a.label, x.card_id, x.side = 'debit', x.amount,
               x.matching_id, e.reversal_of_id
        FROM accounting_entry_line x
        JOIN accounting_entry e ON e.id = x.entry_id
        JOIN accounting_ledger l ON l.id = e.ledger_id
        JOIN accounting_account a ON a.id = x.account_id
        WHERE %{where}
        ORDER BY %{order}
        SQL

      def self.lines(where : String, args : Array(::DB::Any), order : String) : Array(Line)
        sql = LINES_SQL % {where: where, order: order}
        Marten::DB::Connection.default.open do |db|
          db.query_all(sql, args: args) do |result_set|
            Line.new(
              line_id: result_set.read(Int64), entry_id: result_set.read(Int64), ledger_id: result_set.read(Int64),
              date: result_set.read(Time), ledger_code: result_set.read(String), receipt: result_set.read(String?),
              internal_code: result_set.read(String), entry_label: result_set.read(String),
              label: result_set.read(String), number: result_set.read(String),
              account_label: result_set.read(String), card_id: result_set.read(Int64?), debit: result_set.read(Bool),
              amount: result_set.read(BigDecimal), matching_id: result_set.read(Int64?),
              reversal_of_id: result_set.read(Int64?),
            )
          end
        end
      end

      # --- Grand livre -------------------------------------------------------------

      def self.general_ledger(query : Api::GeneralLedgerQuery, readable : Array(Int64)) : Api::GeneralLedgerView
        from, to = ReportData.range(query.date_from, query.date_to)
        ledger_ids = ReportData.ledgers(readable, query.ledger_ids)
        cards = ledger_cards(query)
        by_card = !cards.nil?
        card_ids = cards.try(&.keys)
        sums = ReportData.sums(ledger_ids, from, to, by_card: by_card, account_from: query.account_from,
          account_to: query.account_to, card_ids: card_ids)
        return view(from, to, by_card, [] of Api::GeneralLedgerSectionView) if sums.empty?

        args = [from, to] of ::DB::Any
        where = ["e.ledger_id IN (#{ledger_ids.join(", ")})", "e.date >= $1::date", "e.date <= $2::date"]
        where.concat(ReportData.account_clauses(args, query.account_from, query.account_to, nil))
        where << "x.card_id IN (#{card_ids.join(", ")})" if card_ids
        order = by_card ? "x.card_id, e.date, e.id, x.position" : "a.number, e.date, e.id, x.position"
        rows = lines(where.join(" AND "), args, order)
        known = cards || {} of Int64 => Partiduo::Api::Cards::CardView
        grouped = by_card ? rows.group_by(&.card_id.to_s) : rows.group_by(&.number)
        keyed = by_card ? sums.group_by(&.card_id.to_s) : sums.group_by(&.number)
        codes = {} of Int64 => String
        sections = keyed.compact_map do |key, list|
          opening = list.sum(ZERO, &.opening)
          movements = grouped[key]? || [] of Line
          next if movements.empty? && opening.zero?
          card = list.first.card_id.try { |id| known[id]? }
          title = card ? {card.code, card.name} : {key, list.first.label}
          section(title, opening, movements, known, codes)
        end
        sections.sort_by! { |section| by_card ? section.label.downcase + "\u0000" + section.key : section.key }
        view(from, to, by_card, sections)
      end

      # Fiches d'un grand livre des tiers (`by_card` ou `card`), `nil` pour
      # un grand livre par compte.
      private def self.ledger_cards(query : Api::GeneralLedgerQuery) : Hash(Int64, Partiduo::Api::Cards::CardView)?
        if code = query.card.try(&.strip.presence)
          card = Partiduo::Api::Cards.card_by_code(Partiduo::Api::Actor.system, code) ||
                 raise Partiduo::Api::NotFound.new("card", code)
          {card.id => card}
        elsif query.by_card
          ReportData.cards(ReportData.kinds(query.kind, Balances::TIERS_KINDS))
        end
      end

      private def self.section(title : {String, String}, opening : BigDecimal, movements : Array(Line),
                               cards : Hash(Int64, Partiduo::Api::Cards::CardView),
                               codes : Hash(Int64, String)) : Api::GeneralLedgerSectionView
        balance = opening
        lines = movements.map do |line|
          balance += line.debit ? line.amount : -line.amount
          Api::GeneralLedgerLineView.new(
            line_id: line.line_id, entry_id: line.entry_id, date: line.date, ledger_code: line.ledger_code,
            receipt: line.receipt, internal_code: line.internal_code, label: line.label,
            account_number: line.number,
            card_code: line.card_id.try { |id| codes.put_if_absent(id) { card_code_of(id, cards) } },
            debit: line.debit_amount, credit: line.credit_amount, balance: balance,
            matching_code: line.matching_id.try { |id| Matchings.code(id) },
          )
        end
        debit = lines.sum(ZERO, &.debit)
        credit = lines.sum(ZERO, &.credit)
        Api::GeneralLedgerSectionView.new(title[0], title[1], opening, lines, debit, credit, opening + debit - credit)
      end

      private def self.view(from : Time, to : Time, by_card : Bool, sections : Array(Api::GeneralLedgerSectionView)) : Api::GeneralLedgerView
        Api::GeneralLedgerView.new(
          date_from: from, date_to: to, by_card: by_card, sections: sections,
          total_debit: sections.sum(ZERO, &.total_debit), total_credit: sections.sum(ZERO, &.total_credit),
        )
      end

      private def self.card_code_of(id : Int64, cards : Hash(Int64, Partiduo::Api::Cards::CardView)) : String
        cards[id]?.try(&.code) || Partiduo::Api::Cards.card(Partiduo::Api::Actor.system, id).code
      rescue Partiduo::Api::NotFound
        ""
      end

      # --- Journaux ------------------------------------------------------------------

      def self.journals(query : Api::JournalQuery, readable : Array(Int64)) : Api::JournalView
        from, to = ReportData.range(query.date_from, query.date_to)
        ledger_ids = ReportData.ledgers(readable, query.ledger_ids)
        ledgers = Ledger.filter(id__in: ledger_ids).order(:code).to_a
        rows = if ledger_ids.empty?
                 [] of Line
               else
                 lines("e.ledger_id IN (#{ledger_ids.join(", ")}) AND e.date >= $1::date AND e.date <= $2::date",
                   [from, to] of ::DB::Any, "e.ledger_id, e.date, e.id, x.position")
               end
        by_ledger = rows.group_by(&.ledger_id)
        codes = {} of Int64 => String
        none = {} of Int64 => Partiduo::Api::Cards::CardView
        card_code = ->(id : Int64?) { id.try { |found| codes.put_if_absent(found) { card_code_of(found, none) } } }

        views = ledgers.map do |ledger|
          ledger_lines = by_ledger[ledger.pk!.as(Int64)]? || [] of Line
          entries = ledger_lines.chunk_while { |a, b| a.entry_id == b.entry_id }.map do |chunk|
            first = chunk.first
            lines = chunk.map do |line|
              Api::JournalLineView.new(
                account_number: line.number, account_label: line.account_label, card_code: card_code.call(line.card_id),
                label: line.label, debit: line.debit_amount, credit: line.credit_amount,
              )
            end
            Api::JournalEntryView.new(
              entry_id: first.entry_id, date: first.date, receipt: first.receipt, internal_code: first.internal_code,
              label: first.entry_label, reversal_of_id: first.reversal_of_id, lines: lines,
              debit: lines.sum(ZERO, &.debit), credit: lines.sum(ZERO, &.credit),
            )
          end.to_a
          months = entries.group_by(&.date.to_s("%Y-%m")).map do |month, list|
            Api::JournalTotalView.new(month, "", list.size, list.sum(ZERO, &.debit), list.sum(ZERO, &.credit))
          end
          accounts = ledger_lines.group_by(&.number).map do |number, list|
            Api::JournalTotalView.new(number, list.first.account_label, list.map(&.entry_id).uniq!.size,
              list.sum(ZERO, &.debit_amount), list.sum(ZERO, &.credit_amount))
          end.sort_by!(&.key)
          Api::LedgerJournalView.new(
            ledger_id: ledger.pk!.as(Int64), ledger_code: ledger.code.to_s, ledger_name: ledger.name.to_s,
            ledger_kind: Api::LedgerKind.from_code(ledger.kind.to_s), entries: entries, months: months,
            accounts: accounts, total_debit: entries.sum(ZERO, &.debit), total_credit: entries.sum(ZERO, &.credit),
          )
        end
        Api::JournalView.new(
          date_from: from, date_to: to, ledgers: views, entries: views.sum(0, &.entries.size),
          total_debit: views.sum(ZERO, &.total_debit), total_credit: views.sum(ZERO, &.total_credit),
        )
      end
    end
  end
end
