# SPDX-License-Identifier: AGPL-3.0-or-later

require "csv"

module Partiduo
  module Analytic
    # Exports CSV des éditions analytiques (`export_anc_*_csv.php`), aux
    # conventions des éditions comptables : séparateur `;`, UTF-8, montants au
    # point décimal (deux décimales), dates `AAAA-MM-JJ`, cellules de texte
    # protégées contre les formules (D-2F-009), en-têtes dans la langue
    # courante. Service interne.
    module Exports
      alias Api = Partiduo::Api::Analytic

      alias Cell = String | BigDecimal | Time?

      def self.file(name : String, headers : Array(String), rows : Array(Array(Cell))) : Api::FileView
        text = CSV.build(separator: ';') do |csv|
          csv.row(headers.map { |key| I18n.t("analytic.reports.columns.#{key}") })
          rows.each { |row| csv.row(row.map { |cell| format(cell) }) }
        end
        Api::FileView.new("#{name}.csv", "text/csv; charset=utf-8", text.to_slice)
      end

      def self.balance(view : Api::BalanceView) : Api::FileView
        rows = view.rows.map { |row| balance_cells(row) }
        rows << ([I18n.t("analytic.reports.total"), nil, nil] of Cell) + amount_cells(view.total)
        file("anc-balance-#{slug(view.plan.name)}", %w[post description group debit credit balance side], rows)
      end

      def self.cross_balance(view : Api::CrossBalanceView) : Api::FileView
        rows = view.rows.map do |row|
          ([row.post.code, row.post.description, row.other_post.code, row.other_post.description] of Cell) +
            amount_cells(row.amounts)
        end
        file("anc-balance-double", %w[post description other_post other_description debit credit balance side], rows)
      end

      def self.group_balance(view : Api::GroupBalanceView) : Api::FileView
        rows = [] of Array(Cell)
        view.sections.each do |section|
          section.rows.each do |row|
            rows << ([section.group_code, row.post.code, row.post.description] of Cell) + amount_cells(row.amounts)
          end
        end
        file("anc-balance-group", %w[group post description debit credit balance side], rows)
      end

      def self.history(view : Api::HistoryView) : Api::FileView
        file("anc-history", %w[date post ledger internal_code receipt account card description debit credit],
          view.operations.map { |operation| operation_cells(operation) })
      end

      def self.ledger(view : Api::LedgerView) : Api::FileView
        rows = [] of Array(Cell)
        view.sections.each do |section|
          section_lines = section.lines
          section_lines.each { |line| rows << operation_cells(line.operation) + ([line.running] of Cell) }
        end
        file("anc-ledger", %w[date post ledger internal_code receipt account card description debit credit running], rows)
      end

      def self.table(view : Api::TableView) : Api::FileView
        headers = [view.axis.card? ? "card" : "account", "label"]
        text = CSV.build(separator: ';') do |csv|
          csv.row(headers.map { |key| I18n.t("analytic.reports.columns.#{key}") } +
                  view.posts.map { |post| protect(post.code) } + [I18n.t("analytic.reports.total")])
          view.rows.each do |row|
            csv.row([protect(row.key), protect(row.label)] + view.posts.map { |post| format(row.amounts[post.id]?) } +
                    [format(row.total)])
          end
          csv.row([I18n.t("analytic.reports.total"), ""] + view.posts.map { |post| format(view.column_totals[post.id]?) } +
                  [format(view.total)])
        end
        Api::FileView.new("anc-table.csv", "text/csv; charset=utf-8", text.to_slice)
      end

      # --- Cellules -------------------------------------------------------------------

      private def self.balance_cells(row : Api::BalanceRowView) : Array(Cell)
        ([row.post.code, row.post.description, row.group_code] of Cell) + amount_cells(row.amounts)
      end

      private def self.amount_cells(amounts : Api::Amounts) : Array(Cell)
        [amounts.debit, amounts.credit, amounts.balance, amounts.side.try { |side| I18n.t("analytic.reports.side.#{side.code}") }] of Cell
      end

      private def self.operation_cells(operation : Api::OperationView) : Array(Cell)
        [operation.date, operation.post.code, operation.ledger_code, operation.internal_code, operation.receipt,
         operation.account_number, operation.card_code, operation.description, operation.debit, operation.credit] of Cell
      end

      def self.format(cell : Cell) : String
        case cell
        when BigDecimal then plain(cell)
        when Time       then cell.to_s("%Y-%m-%d")
        when String     then protect(cell)
        else                 ""
        end
      end

      def self.plain(value : BigDecimal) : String
        text = value.round(2, mode: :ties_away).to_s
        integer, _, fraction = text.partition('.')
        "#{integer}.#{fraction.ljust(2, '0')[0, 2]}"
      end

      # Montant d'un paramètre d'erreur (`FieldError#params`) : valeur brute
      # au point décimal, deux décimales ; l'interface le présente selon la
      # langue (`Format#message`, D-ANA-015).
      def self.raw(value : BigDecimal) : String
        plain(value)
      end

      # Partie de nom de fichier sûre pour un en-tête `Content-Disposition` :
      # minuscules ASCII, chiffres, `_` et `-` ; tout autre caractère devient
      # `-` (nom de plan libre, D-ANA-016).
      def self.slug(text : String) : String
        cleaned = text.unicode_normalize(:nfkd).gsub(/\p{Mn}/, "").downcase.gsub(/[^a-z0-9_-]+/, "-").strip('-')
        cleaned.empty? ? "plan" : cleaned
      end

      # Cellule de texte commençant par `=`, `+`, `-`, `@`, une tabulation ou
      # un retour chariot : préfixée d'une apostrophe (D-2F-009).
      def self.protect(text : String) : String
        text.starts_with?(/[=+\-@\t\r]/) ? "'#{text}" : text
      end
    end
  end
end
