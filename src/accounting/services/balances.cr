# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Accounting
    # Balances (lot 3) : balance générale (`Acc_Balance::get_row`), balance
    # des tiers (`balance_card.inc.php`) et balance âgée (`Balance_Age`,
    # règles du relevé `EntryQueries.statement`). Service interne.
    module Balances
      alias Api = Partiduo::Api::Accounting

      ZERO = BigDecimal.new(0)

      # Natures des fiches de tiers suivies par défaut (clients et
      # fournisseurs) et de celles qui portent un compte auxiliaire dans le
      # FEC (hors articles et banques).
      TIERS_KINDS     = %w[customer supplier]
      AUXILIARY_KINDS = Partiduo::Api::Cards::KINDS - %w[item bank]

      # --- Balance générale ------------------------------------------------------

      def self.trial_balance(query : Api::TrialBalanceQuery, readable : Array(Int64)) : Api::TrialBalanceView
        from, to = ReportData.range(query.date_from, query.date_to)
        ledger_ids = ReportData.ledgers(readable, query.ledger_ids, query.ledger_kinds)
        sums = ReportData.sums(ledger_ids, from, to, account_from: query.account_from, account_to: query.account_to)
        rows = sums.map { |sum| row(sum.number, sum.label, ReportData.account_kind(sum.kind), [sum]) }
        rows.reject!(&.closing.signed.zero?) if query.nonzero_only
        classes = rows.group_by(&.number[0].to_s).map do |digit, list|
          label = Account.filter(number: digit).first.try(&.label.to_s) || ""
          merge(digit, label, list)
        end
        balance_sheet = expenses = income = ZERO
        rows.each do |item|
          case item.number[0]
          when '6'      then expenses += item.closing.signed
          when '7'      then income += item.closing.signed
          when '1'..'5' then balance_sheet += item.closing.signed
          end
        end
        Api::TrialBalanceView.new(
          date_from: from, date_to: to, rows: rows, classes: classes, total: merge("", "", rows),
          summary: Api::ClassSummaryView.new(balance_sheet, expenses, income),
        )
      end

      private def self.row(number : String, label : String, kind : Api::AccountKind?, sums : Array(ReportData::Sum)) : Api::TrialBalanceRowView
        opening = sums.sum(ZERO, &.opening)
        debit = sums.sum(ZERO, &.debit)
        credit = sums.sum(ZERO, &.credit)
        Api::TrialBalanceRowView.new(
          number: number, label: label, kind: kind, opening: Api::SplitBalance.of(opening), debit: debit, credit: credit,
          closing: Api::SplitBalance.of(opening + debit - credit), lines: sums.sum(0, &.lines),
        )
      end

      # Total de lignes de balance : les soldes sont additionnés colonne par
      # colonne (`tot_deb_saldo`, `tot_cred_saldo`), pas compensés.
      def self.merge(number : String, label : String, rows : Array(Api::TrialBalanceRowView)) : Api::TrialBalanceRowView
        Api::TrialBalanceRowView.new(
          number: number, label: label, kind: nil,
          opening: Api::SplitBalance.new(rows.sum(ZERO, &.opening.debit), rows.sum(ZERO, &.opening.credit)),
          debit: rows.sum(ZERO, &.debit), credit: rows.sum(ZERO, &.credit),
          closing: Api::SplitBalance.new(rows.sum(ZERO, &.closing.debit), rows.sum(ZERO, &.closing.credit)),
          lines: rows.sum(0, &.lines),
        )
      end

      # --- Balance des tiers -------------------------------------------------------

      def self.auxiliary_balance(query : Api::AuxiliaryBalanceQuery, readable : Array(Int64)) : Api::AuxiliaryBalanceView
        from, to = ReportData.range(query.date_from, query.date_to)
        cards = ReportData.cards(ReportData.kinds(query.kind, TIERS_KINDS))
        ledger_ids = ReportData.ledgers(readable, query.ledger_ids)
        sums = ReportData.sums(ledger_ids, from, to, by_card: true, account_prefix: query.account, card_ids: cards.keys)
        accounts = CardAccount.filter(card_id__in: cards.keys).join(:account).to_a
          .to_h { |link| {link.card_id!.to_i64, link.account!.number.to_s} }
        rows = sums.group_by { |sum| sum.card_id || 0_i64 }.compact_map do |card_id, list|
          card = cards[card_id]? || next
          opening = list.sum(ZERO, &.opening)
          debit = list.sum(ZERO, &.debit)
          credit = list.sum(ZERO, &.credit)
          Api::AuxiliaryBalanceRowView.new(
            card_id: card_id, card_code: card.code, card_name: card.name, card_kind: card.kind,
            account_number: accounts[card_id]?, opening: Api::SplitBalance.of(opening), debit: debit, credit: credit,
            closing: Api::SplitBalance.of(opening + debit - credit), lines: list.sum(0, &.lines),
          )
        end
        rows.reject!(&.closing.signed.zero?) if query.nonzero_only
        rows.sort_by! { |row| {row.card_name.downcase, row.card_code} }
        total = Api::AuxiliaryBalanceRowView.new(
          card_id: 0_i64, card_code: "", card_name: "", card_kind: "", account_number: nil,
          opening: Api::SplitBalance.new(rows.sum(ZERO, &.opening.debit), rows.sum(ZERO, &.opening.credit)),
          debit: rows.sum(ZERO, &.debit), credit: rows.sum(ZERO, &.credit),
          closing: Api::SplitBalance.new(rows.sum(ZERO, &.closing.debit), rows.sum(ZERO, &.closing.credit)),
          lines: rows.sum(0, &.lines),
        )
        Api::AuxiliaryBalanceView.new(date_from: from, date_to: to, rows: rows, total: total)
      end

      # --- Balance âgée --------------------------------------------------------

      record Line,
        card_id : Int64,
        line_id : Int64,
        entry_id : Int64,
        date : Time,
        due_date : Time?,
        ledger_code : String,
        receipt : String?,
        label : String,
        amount : BigDecimal,
        matching_id : Int64? do
        def reference : Time
          due_date || date
        end
      end

      # Éléments ouverts de chaque fiche au jour `as_of`, avec les règles
      # de `account_statement` arrêté à cette date (D-TST-002) : lignes non
      # lettrées, et reliquat de chaque lettrage partiel (écart de toutes
      # ses lignes datées au plus tard `as_of`), daté de la plus ancienne
      # échéance de la fiche dans ce lettrage.
      def self.aged_balance(query : Api::AgedBalanceQuery, readable : Array(Int64)) : Api::AgedBalanceView
        as_of = Posting.day(query.as_of || Partiduo::Config.today)
        cards = if code = query.card.try(&.strip.presence)
                  card = Partiduo::Api::Cards.card_by_code(Partiduo::Api::Actor.system, code) ||
                         raise Partiduo::Api::NotFound.new("card", code)
                  {card.id => card}
                else
                  ReportData.cards(ReportData.kinds(query.kind, TIERS_KINDS))
                end
        ledger_ids = ReportData.ledgers(readable, query.ledger_ids)
        lines = party_lines(cards.keys, ledger_ids, as_of)
        differences = EntryQueries.matching_differences(lines.compact_map(&.matching_id).uniq!, as_of)
        rows = lines.group_by(&.card_id).compact_map do |card_id, list|
          items = open_items(list, differences, as_of)
          next if items.empty?
          card = cards[card_id]
          buckets = ageing(items)
          remaining = items.sum(ZERO, &.amount)
          next if remaining.zero? && items.all?(&.amount.zero?)
          Api::AgedBalanceRowView.new(
            card_id: card_id, card_code: card.code, card_name: card.name, card_kind: card.kind,
            remaining: remaining, overdue: items.select { |item| item.days > 0 }.sum(ZERO, &.amount),
            ageing: buckets, items: items,
          )
        end
        rows.sort_by! { |row| {row.card_name.downcase, row.card_code} }
        Api::AgedBalanceView.new(
          as_of: as_of, rows: rows, remaining: rows.sum(ZERO, &.remaining), overdue: rows.sum(ZERO, &.overdue),
          ageing: Api::AgeingView.new(rows.sum(ZERO, &.ageing.not_due), rows.sum(ZERO, &.ageing.days_1_30),
            rows.sum(ZERO, &.ageing.days_31_60), rows.sum(ZERO, &.ageing.over_60)),
        )
      end

      private def self.party_lines(card_ids : Array(Int64), ledger_ids : Array(Int64), as_of : Time) : Array(Line)
        return [] of Line if card_ids.empty? || ledger_ids.empty?
        sql = <<-SQL
          SELECT x.card_id, x.id, e.id, e.date, e.due_date, l.code, e.receipt,
                 COALESCE(NULLIF(x.label, ''), e.label),
                 CASE WHEN x.side = 'debit' THEN x.amount ELSE -x.amount END, x.matching_id
          FROM accounting_entry_line x
          JOIN accounting_entry e ON e.id = x.entry_id
          JOIN accounting_ledger l ON l.id = e.ledger_id
          WHERE x.card_id IN (#{card_ids.join(", ")}) AND e.ledger_id IN (#{ledger_ids.join(", ")})
            AND e.date <= $1::date
          ORDER BY e.date, e.id, x.position
          SQL
        Marten::DB::Connection.default.open do |db|
          db.query_all(sql, args: [as_of.as(::DB::Any)]) do |result_set|
            Line.new(
              card_id: result_set.read(Int64), line_id: result_set.read(Int64), entry_id: result_set.read(Int64),
              date: result_set.read(Time), due_date: result_set.read(Time?), ledger_code: result_set.read(String),
              receipt: result_set.read(String?), label: result_set.read(String), amount: result_set.read(BigDecimal),
              matching_id: result_set.read(Int64?),
            )
          end
        end
      end

      private def self.open_items(lines : Array(Line), differences : Hash(Int64, BigDecimal), as_of : Time) : Array(Api::OpenItemView)
        items = [] of Api::OpenItemView
        partials = {} of Int64 => Time
        lines.each do |line|
          if matching_id = line.matching_id
            next if differences[matching_id]?.try(&.zero?)
            partials[matching_id] = [partials[matching_id]? || line.reference, line.reference].min
          else
            items << Api::OpenItemView.new(
              line_id: line.line_id, entry_id: line.entry_id, date: line.date, due_date: line.due_date,
              ledger_code: line.ledger_code, receipt: line.receipt, label: line.label, matching_code: nil,
              days: (as_of - line.reference).days.to_i32, amount: line.amount,
            )
          end
        end
        partials.each do |matching_id, reference|
          code = Matchings.code(matching_id)
          items << Api::OpenItemView.new(
            line_id: nil, entry_id: nil, date: reference, due_date: nil, ledger_code: nil, receipt: nil,
            label: code, matching_code: code, days: (as_of - reference).days.to_i32,
            amount: differences[matching_id]? || ZERO,
          )
        end
        items.sort_by! { |item| {item.due_date || item.date, item.line_id || 0_i64} }
      end

      # Tranches du relevé : non échu, 1 à 30 jours, 31 à 60, plus de 60.
      private def self.ageing(items : Array(Api::OpenItemView)) : Api::AgeingView
        buckets = Array.new(4) { ZERO }
        items.each do |item|
          index = if item.days <= 0
                    0
                  elsif item.days <= 30
                    1
                  elsif item.days <= 60
                    2
                  else
                    3
                  end
          buckets[index] += item.amount
        end
        Api::AgeingView.new(buckets[0], buckets[1], buckets[2], buckets[3])
      end
    end
  end
end
