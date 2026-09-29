# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    # Contrat du socle — tableau neutre en PDF/A-2b (ADR-005 D5, BLOCAGES
    # B-CRIT-001) : une interface qui a déjà lu et mis en forme les lignes
    # d'une liste par le contrat en obtient le PDF, sans dépendre elle-même
    # de `pdf-a` (ADR-005 D3). Le service ne lit aucune donnée métier : il
    # rend ce qu'on lui donne, dans la langue courante, avec l'en-tête de la
    # société et un pied numéroté.
    module Core
      TABLE_COLUMN_KINDS = %w[text amount date number]
      TABLE_ROW_STYLES   = %w[line heading subtotal total]
      MAX_TABLE_COLUMNS  =    30
      MAX_TABLE_ROWS     = 20000
      MAX_TABLE_CELL     =   500

      # Colonne : titre traduit, nature (`TABLE_COLUMN_KINDS` : les montants et
      # les nombres s'alignent à droite), largeur relative (0,2 à 10).
      record TableColumnInput, title : String, kind : String = "text", weight : Float64 = 1.0

      # Ligne : cellules déjà mises en forme (texte affiché), style
      # (`TABLE_ROW_STYLES`), retrait de la première cellule (0 à 10).
      record TableRowInput, cells : Array(String), style : String = "line", indent : Int32 = 0

      # Tableau : nom du fichier (sans extension ; lettres, chiffres, `-`,
      # `_`, `.`), titre, sous-titres (période, filtres), colonnes, lignes ;
      # `landscape` `nil` : paysage au-delà de six colonnes.
      record TableInput,
        name : String,
        title : String,
        columns : Array(TableColumnInput),
        rows : Array(TableRowInput),
        subtitle : Array(String) = [] of String,
        landscape : Bool? = nil

      record FileView, filename : String, content_type : String, content : Bytes

      # PDF/A-2b d'un tableau. Tout utilisateur authentifié au niveau exigé
      # (aucune donnée n'est lue). Refus : `core.errors.table.*`.
      def self.table_pdf(actor : Actor, input : TableInput) : Result(FileView)
        Guard.authorize!(actor, nil)
        errors = table_errors(input)
        return Result(FileView).failure(errors) unless errors.empty?
        columns = input.columns.map do |column|
          Partiduo::Core::TableOutput::Column.new(column.title.strip, column.weight, column_kind(column.kind))
        end
        rows = input.rows.map do |row|
          cells = row.cells.map { |cell| cell[0, MAX_TABLE_CELL].as(Partiduo::Core::TableOutput::Cell) }
          Partiduo::Core::TableOutput::Row.new(cells, row_style(row.style), row.indent)
        end
        name = input.name.gsub(/[^A-Za-z0-9._\-]+/, "-").strip("-.").presence || "export"
        table = Partiduo::Core::TableOutput::Table.new(name, input.title.strip, input.subtitle, columns, rows,
          input.landscape.nil? ? input.columns.size > 6 : input.landscape == true)
        Result(FileView).success(FileView.new("#{name}.pdf", "application/pdf", Partiduo::Core::TableOutput.pdf(table)))
      end

      private def self.column_kind(kind : String) : Symbol
        case kind
        when "amount" then :amount
        when "date"   then :date
        when "number" then :number
        else               :text
        end
      end

      private def self.row_style(style : String) : Symbol
        case style
        when "heading"  then :heading
        when "subtotal" then :subtotal
        when "total"    then :total
        else                 :line
        end
      end

      private def self.table_errors(input : TableInput) : Array(FieldError)
        errors = [] of FieldError
        table = ->(field : String, code : String, params : Hash(String, String)) do
          errors << FieldError.new(field, "core.errors.table.#{code}", params)
          nil
        end
        none = {} of String => String
        table.call("title", "title.blank", none) if input.title.strip.empty?
        if input.columns.empty? || input.columns.size > MAX_TABLE_COLUMNS
          table.call("columns", "columns.count", {"max" => MAX_TABLE_COLUMNS.to_s})
        end
        input.columns.each_with_index do |column, index|
          unless TABLE_COLUMN_KINDS.includes?(column.kind) && (0.2..10.0).includes?(column.weight)
            table.call("columns[#{index}]", "columns.column", none)
          end
        end
        table.call("rows", "rows.count", {"max" => MAX_TABLE_ROWS.to_s}) if input.rows.size > MAX_TABLE_ROWS
        input.rows.each_with_index do |row, index|
          if row.cells.size > input.columns.size || !TABLE_ROW_STYLES.includes?(row.style) || !(0..10).includes?(row.indent)
            table.call("rows[#{index}]", "rows.row", none)
            break
          end
        end
        errors
      end
    end
  end
end
