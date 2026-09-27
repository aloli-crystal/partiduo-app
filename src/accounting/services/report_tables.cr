# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Accounting
    # Tableaux imprimables des éditions (`ReportOutput::Table`), dans la
    # langue courante. Service interne.
    module ReportTables
      alias Api = Partiduo::Api::Accounting
      alias Out = ReportOutput

      private def self.t(key : String, params = {} of String => String) : String
        I18n.t("accounting.reports.#{key}", params)
      end

      private def self.column(key : String, weight : Float64 = 1.0, kind : Symbol = :text) : Out::Column
        Out::Column.new(t("columns.#{key}"), weight, kind)
      end

      private def self.name(key : String, from : Time?, to : Time) : String
        dates = from ? "#{from.to_s("%Y%m%d")}-#{to.to_s("%Y%m%d")}" : to.to_s("%Y%m%d")
        "#{key}-#{dates}"
      end

      # --- Balance générale ----------------------------------------------------------

      def self.trial_balance(view : Api::TrialBalanceView) : Out::Table
        columns = [column("account", 1.2), column("label", 3.2),
                   column("opening_debit", 1.3, :amount), column("opening_credit", 1.3, :amount),
                   column("debit", 1.3, :amount), column("credit", 1.3, :amount),
                   column("balance_debit", 1.3, :amount), column("balance_credit", 1.3, :amount)]
        cells = ->(row : Api::TrialBalanceRowView) do
          [row.opening.debit, row.opening.credit, row.debit, row.credit, row.closing.debit, row.closing.credit] of Out::Cell
        end
        rows = [] of Out::Row
        view.rows.group_by(&.number[0].to_s).each do |digit, list|
          list.each { |row| rows << Out::Row.new([row.number, row.label] of Out::Cell + cells.call(row)) }
          if total = view.classes.find(&.number.==(digit))
            rows << Out::Row.new([digit, t("class_total", {"class" => digit})] of Out::Cell + cells.call(total), :subtotal)
          end
        end
        rows << Out::Row.new(["", t("total")] of Out::Cell + cells.call(view.total), :total)
        summary = view.summary
        rows << Out::Row.new(["", t("summary.balance_sheet"), nil, nil, nil, nil] of Out::Cell + split(summary.balance_sheet), :subtotal)
        rows << Out::Row.new(["", t("summary.expenses"), nil, nil, nil, nil] of Out::Cell + split(summary.expenses), :subtotal)
        rows << Out::Row.new(["", t("summary.income"), nil, nil, nil, nil] of Out::Cell + split(summary.income), :subtotal)
        rows << Out::Row.new(["", t("summary.result"), nil, nil, nil, nil, nil, summary.result] of Out::Cell, :total)
        Out::Table.new(name("trial-balance", view.date_from, view.date_to), t("titles.trial_balance"),
          [Out.period(view.date_from, view.date_to)], columns, rows, landscape: true)
      end

      private def self.split(signed : BigDecimal) : Array(Out::Cell)
        balance = Api::SplitBalance.of(signed)
        [balance.debit, balance.credit] of Out::Cell
      end

      # --- Balance des tiers ---------------------------------------------------------

      def self.auxiliary_balance(view : Api::AuxiliaryBalanceView) : Out::Table
        columns = [column("card", 1.2), column("name", 3.0), column("account", 1.0),
                   column("opening_debit", 1.2, :amount), column("opening_credit", 1.2, :amount),
                   column("debit", 1.2, :amount), column("credit", 1.2, :amount),
                   column("balance_debit", 1.2, :amount), column("balance_credit", 1.2, :amount)]
        cells = ->(row : Api::AuxiliaryBalanceRowView) do
          [row.opening.debit, row.opening.credit, row.debit, row.credit, row.closing.debit, row.closing.credit] of Out::Cell
        end
        rows = view.rows.map do |row|
          Out::Row.new([row.card_code, row.card_name, row.account_number || ""] of Out::Cell + cells.call(row))
        end
        rows << Out::Row.new(["", t("total"), ""] of Out::Cell + cells.call(view.total), :total)
        Out::Table.new(name("auxiliary-balance", view.date_from, view.date_to), t("titles.auxiliary_balance"),
          [Out.period(view.date_from, view.date_to)], columns, rows, landscape: true)
      end

      # --- Balance âgée --------------------------------------------------------------

      def self.aged_balance(view : Api::AgedBalanceView) : Out::Table
        columns = [column("card", 1.2), column("date", 1.0, :date), column("receipt", 1.1), column("label", 2.6),
                   column("due_date", 1.0, :date), column("days", 0.6, :number),
                   column("not_due", 1.2, :amount), column("days_1_30", 1.2, :amount),
                   column("days_31_60", 1.2, :amount), column("over_60", 1.2, :amount), column("remaining", 1.2, :amount)]
        rows = [] of Out::Row
        view.rows.each do |row|
          rows << Out::Row.new([row.card_code, nil, nil, row.card_name] of Out::Cell, :heading)
          row.items.each do |item|
            buckets = [nil, nil, nil, nil] of Out::Cell
            index = item.days <= 0 ? 0 : item.days <= 30 ? 1 : item.days <= 60 ? 2 : 3
            buckets[index] = item.amount
            rows << Out::Row.new(["", item.date, item.receipt || item.matching_code || "", item.label, item.due_date,
                                  item.days] of Out::Cell + buckets + [item.amount] of Out::Cell)
          end
          rows << Out::Row.new(["", nil, nil, t("card_total", {"card" => row.card_code}), nil, nil] of Out::Cell +
                               ageing(row.ageing) + [row.remaining] of Out::Cell, :subtotal)
        end
        rows << Out::Row.new(["", nil, nil, t("total"), nil, nil] of Out::Cell + ageing(view.ageing) +
                             [view.remaining] of Out::Cell, :total)
        Out::Table.new(name("aged-balance", nil, view.as_of), t("titles.aged_balance"),
          [t("as_of", {"date" => Out.format_date(view.as_of)})], columns, rows, landscape: true)
      end

      private def self.ageing(view : Api::AgeingView) : Array(Out::Cell)
        [view.not_due, view.days_1_30, view.days_31_60, view.over_60] of Out::Cell
      end

      # --- Grand livre ---------------------------------------------------------------

      def self.general_ledger(view : Api::GeneralLedgerView) : Out::Table
        columns = [column("date", 1.0, :date), column("ledger", 0.7), column("receipt", 1.1), column("label", 3.4),
                   column(view.by_card ? "account" : "card", 1.1), column("matching", 0.6),
                   column("debit", 1.3, :amount), column("credit", 1.3, :amount), column("balance", 1.3, :amount)]
        rows = [] of Out::Row
        view.sections.each do |section|
          rows << Out::Row.new(["#{section.key} #{section.label}"] of Out::Cell, :heading)
          unless section.opening_balance.zero?
            rows << Out::Row.new([nil, nil, nil, t("opening"), nil, nil, nil, nil, section.opening_balance] of Out::Cell)
          end
          rows.concat(section.lines.map do |line|
            other = view.by_card ? line.account_number : (line.card_code || "")
            Out::Row.new([line.date, line.ledger_code, line.receipt || line.internal_code, line.label, other,
                          line.matching_code || "", line.debit, line.credit, line.balance] of Out::Cell)
          end)
          rows << Out::Row.new([nil, nil, nil, t("section_total", {"key" => section.key}), nil, nil,
                                section.total_debit, section.total_credit, section.closing_balance] of Out::Cell, :subtotal)
        end
        rows << Out::Row.new([nil, nil, nil, t("total"), nil, nil, view.total_debit, view.total_credit, nil] of Out::Cell, :total)
        key = view.by_card ? "auxiliary_ledger" : "general_ledger"
        Out::Table.new(name(key.tr("_", "-"), view.date_from, view.date_to), t("titles.#{key}"),
          [Out.period(view.date_from, view.date_to)], columns, rows, landscape: true)
      end

      # --- Journaux ------------------------------------------------------------------

      def self.journals(view : Api::JournalView) : Out::Table
        columns = [column("date", 1.0, :date), column("receipt", 1.1), column("internal_code", 1.0),
                   column("account", 1.1), column("card", 1.1), column("label", 3.6),
                   column("debit", 1.3, :amount), column("credit", 1.3, :amount)]
        rows = [] of Out::Row
        view.ledgers.each do |ledger|
          rows << Out::Row.new(["#{ledger.ledger_code} #{ledger.ledger_name}"] of Out::Cell, :heading)
          ledger.entries.each do |entry|
            rows << Out::Row.new([entry.date, entry.receipt || "", entry.internal_code, nil, nil, entry.label] of Out::Cell, :subtotal)
            rows.concat(entry.lines.map do |line|
              Out::Row.new([nil, nil, nil, line.account_number, line.card_code || "", line.label,
                            line.debit, line.credit] of Out::Cell)
            end)
          end
          ledger.months.each do |month|
            rows << Out::Row.new([nil, nil, nil, nil, nil, t("month_total", {"month" => month.key}),
                                  month.debit, month.credit] of Out::Cell, :subtotal)
          end
          rows << Out::Row.new([nil, nil, nil, nil, nil, t("section_total", {"key" => ledger.ledger_code}),
                                ledger.total_debit, ledger.total_credit] of Out::Cell, :total)
        end
        rows << Out::Row.new([nil, nil, nil, nil, nil, t("total"), view.total_debit, view.total_credit] of Out::Cell, :total)
        Out::Table.new(name("journals", view.date_from, view.date_to), t("titles.journals"),
          [Out.period(view.date_from, view.date_to)], columns, rows, landscape: true)
      end

      # --- États ---------------------------------------------------------------------

      def self.statement(view : Api::FinancialStatementView) : Out::Table
        with_gross = view.lines.any?(&.gross)
        columns = [column("rubric", 5.0)]
        columns.concat([column("gross", 1.4, :amount), column("less", 1.4, :amount)]) if with_gross
        columns << column("net", 1.4, :amount)
        columns << column("previous", 1.4, :amount) if view.previous_from
        rows = view.lines.map do |line|
          cells = [I18n.t(line.label_key)] of Out::Cell
          cells.concat([line.gross, line.less] of Out::Cell) if with_gross
          cells << line.net
          cells << line.previous if view.previous_from
          style = case line.style
                  when "heading"  then :heading
                  when "subtotal" then :subtotal
                  when "total"    then :total
                  else                 :line
                  end
          Out::Row.new(cells, style, indent: line.level)
        end
        unless view.difference.zero?
          rows << Out::Row.new([t("difference")] of Out::Cell + Array(Out::Cell).new(columns.size - 2, nil) +
                               [view.difference] of Out::Cell, :total)
        end
        view.unmapped.each do |account|
          rows << Out::Row.new([t("unmapped", {"number" => account.number, "label" => account.label})] of Out::Cell +
                               Array(Out::Cell).new(columns.size - 2, nil) + [account.balance] of Out::Cell)
        end
        subtitle = [Out.period(view.date_from, view.date_to)]
        if (from = view.previous_from) && (to = view.previous_to)
          subtitle << t("previous_period", {"period" => Out.period(from, to)})
        end
        subtitle << t("partial") if view.partial
        key = view.kind.code
        Out::Table.new(name(key.tr("_", "-"), view.date_from, view.date_to),
          I18n.t("accounting.reports.titles.#{key}_#{view.regime}"), subtitle, columns, rows)
      end

      def self.custom_report(view : Api::ReportResultView) : Out::Table
        columns = [column("label", 5.0), column("formula", 2.5), column("amount", 1.5, :amount)]
        rows = view.lines.map { |line| Out::Row.new([line.label, line.formula, line.amount] of Out::Cell) }
        slug = view.name.downcase.gsub(/[^a-z0-9]+/, "-").strip('-').presence || "report"
        Out::Table.new(name(slug, view.date_from, view.date_to), view.name, [Out.period(view.date_from, view.date_to)],
          columns, rows)
      end
    end
  end
end
