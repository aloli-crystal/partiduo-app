# SPDX-License-Identifier: AGPL-3.0-or-later

require "csv"

module Partiduo
  module Stock
    # Exports CSV du stock (`export_stock_histo_csv.php`,
    # `export_stock_resume_list.php`), aux conventions des éditions :
    # séparateur `;`, UTF-8, quantités au point décimal (quatre décimales),
    # montants à deux décimales, dates `AAAA-MM-JJ`, cellules de texte
    # protégées contre les formules (D-2F-009), en-têtes dans la langue
    # courante. Service interne.
    module Exports
      alias Api = Partiduo::Api::Stock

      alias Cell = String | BigDecimal | Time?

      def self.history(views : Array(Api::MovementView)) : Api::FileView
        rows = views.map do |view|
          [view.date, view.repository_name, view.stock_code, view.card_code, view.card_name,
           I18n.t(view.direction_key), quantity(view.quantity), view.unit_cost.try { |cost| quantity(cost) },
           view.source, view.comment] of Cell
        end
        file("stock-history", %w[date repository stock_code card card_name direction quantity unit_cost source comment], rows)
      end

      def self.state(view : Api::StateView) : Api::FileView
        rows = view.rows.map do |row|
          [row.repository_name, row.stock_code, row.card_names.join(", "), quantity(row.opening),
           quantity(row.quantity_in), quantity(row.quantity_out), quantity(row.closing)] of Cell
        end
        file("stock-state", %w[repository stock_code card_name opening quantity_in quantity_out closing], rows)
      end

      def self.valuation(view : Api::ValuationView) : Api::FileView
        rows = view.rows.map do |row|
          [row.repository_name, row.stock_code, row.card_names.join(", "), quantity(row.quantity),
           row.unit_cost.try { |cost| quantity(cost) }, row.value.try { |value| amount(value) }] of Cell
        end
        rows << [I18n.t("stock.columns.total"), nil, nil, nil, nil, amount(view.total)] of Cell
        file("stock-valuation", %w[repository stock_code card_name quantity unit_cost value], rows)
      end

      private def self.file(name : String, headers : Array(String), rows : Array(Array(Cell))) : Api::FileView
        text = CSV.build(separator: ';') do |csv|
          csv.row(headers.map { |key| I18n.t("stock.columns.#{key}") })
          rows.each { |row| csv.row(row.map { |cell| format(cell) }) }
        end
        Api::FileView.new("#{name}.csv", "text/csv; charset=utf-8", text.to_slice)
      end

      private def self.format(cell : Cell) : String
        case cell
        when Time   then cell.to_s("%Y-%m-%d")
        when String then protect(cell)
        else             ""
        end
      end

      # Nombre au point décimal, `digits` décimales.
      def self.fixed(value : BigDecimal, digits : Int32) : String
        text = value.round(digits, mode: :ties_away).to_s
        integer, _, fraction = text.partition('.')
        "#{integer}.#{fraction.ljust(digits, '0')[0, digits]}"
      end

      private def self.quantity(value : BigDecimal) : String
        fixed(value, 4)
      end

      private def self.amount(value : BigDecimal) : String
        fixed(value, 2)
      end

      # Cellule de texte commençant par `=`, `+`, `-`, `@`, une tabulation ou
      # un retour chariot : préfixée d'une apostrophe (D-2F-009). Les
      # nombres déjà mis en forme gardent leur signe.
      private def self.protect(text : String) : String
        return text if text.matches?(/\A-?\d+(\.\d+)?\z/)
        text.starts_with?(/[=+\-@\t\r]/) ? "'#{text}" : text
      end
    end
  end
end
