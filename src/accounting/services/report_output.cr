# SPDX-License-Identifier: AGPL-3.0-or-later

require "csv"
require "pdf-a"

module Partiduo
  module Accounting
    # Sortie des éditions en CSV et en PDF (ADR-005 : « export CSV et PDF
    # depuis chaque liste »), à partir d'un tableau neutre (`Table`) que
    # construit `ReportTables` pour chaque édition.
    #
    # * CSV : séparateur `;`, UTF-8, montants au point décimal, dates
    #   `AAAA-MM-JJ`, cellules de texte protégées contre les formules
    #   (D-2F-009) ; en-têtes dans la langue courante ;
    # * PDF : PDF/A-2b (`prod-crystal/pdf-a`), A4 (paysage pour les
    #   tableaux larges), polices DejaVu embarquées, montants et dates selon
    #   la langue courante, en-tête (société, titre, période) et pied
    #   numéroté sur chaque page.
    module ReportOutput
      FONT_REGULAR = {{ read_file("#{__DIR__}/../../../data/fonts/DejaVuSans.ttf") }}
      FONT_BOLD    = {{ read_file("#{__DIR__}/../../../data/fonts/DejaVuSans-Bold.ttf") }}

      alias Cell = String | BigDecimal | Time | Int32?

      # Colonne : titre (déjà traduit), largeur relative, nature (`text`,
      # `amount`, `date`, `number`).
      record Column, title : String, weight : Float64 = 1.0, kind : Symbol = :text do
        def right? : Bool
          kind.in?(:amount, :number)
        end
      end

      # Ligne : `style` `:line`, `:heading`, `:subtotal` ou `:total` ;
      # `indent` : retrait de la première cellule.
      record Row, cells : Array(Cell), style : Symbol = :line, indent : Int32 = 0

      record Table,
        name : String,
        title : String,
        subtitle : Array(String),
        columns : Array(Column),
        rows : Array(Row),
        landscape : Bool = false

      # --- Formats -----------------------------------------------------------------

      def self.plain(value : BigDecimal) : String
        text = value.round(2, mode: :ties_away).to_s
        integer, _, fraction = text.partition('.')
        "#{integer}.#{fraction.ljust(2, '0')[0, 2]}"
      end

      def self.format_amount(value : BigDecimal, locale : String = I18n.locale) : String
        text = plain(value)
        negative = text.starts_with?('-')
        integer, _, fraction = text.lchop('-').partition('.')
        thousands, decimal = case locale
                             when "en" then {",", "."}
                             when "nl" then {".", ","}
                             else           {" ", ","}
                             end
        grouped = integer.reverse.scan(/\d{1,3}/).map(&.[0]).join(thousands).reverse
        "#{negative ? "-" : ""}#{grouped}#{decimal}#{fraction}"
      end

      def self.format_date(value : Time, locale : String = I18n.locale) : String
        case locale
        when "en" then value.to_s("%Y-%m-%d")
        when "nl" then value.to_s("%d-%m-%Y")
        else           value.to_s("%d/%m/%Y")
        end
      end

      def self.period(from : Time, to : Time) : String
        I18n.t("accounting.reports.period", {"from" => format_date(from), "to" => format_date(to)})
      end

      # Cellule de texte d'un CSV : une valeur qui commence par `=`, `+`,
      # `-`, `@`, une tabulation ou un retour chariot est préfixée d'une
      # apostrophe (D-2F-009).
      def self.csv_text(text : String) : String
        text.starts_with?(/[=+\-@\t\r]/) ? "'#{text}" : text
      end

      # --- CSV -----------------------------------------------------------------------

      def self.csv(table : Table) : Bytes
        CSV.build(separator: ';') do |csv|
          csv.row table.columns.map { |column| csv_text(column.title) }
          table.rows.each do |row|
            csv.row(row.cells.map do |cell|
              case cell
              when BigDecimal then plain(cell)
              when Time       then cell.to_s("%Y-%m-%d")
              when Int32      then cell.to_s
              when String     then csv_text(cell)
              else                 ""
              end
            end)
          end
        end.to_slice
      end

      def self.file(table : Table, format : Partiduo::Api::Accounting::ExportFormat) : Partiduo::Api::Accounting::FileView
        if format.csv?
          Partiduo::Api::Accounting::FileView.new("#{table.name}.csv", "text/csv", csv(table))
        else
          Partiduo::Api::Accounting::FileView.new("#{table.name}.pdf", "application/pdf", pdf(table))
        end
      end

      # --- PDF -----------------------------------------------------------------------

      def self.pdf(table : Table) : Bytes
        document = PDF::A::Document.new(PDF::A::Profile::A_2B)
        document.title = table.title
        document.author = company_name
        document.creator = "Partiduo #{Partiduo::VERSION}"
        document.producer = "Partiduo #{Partiduo::VERSION}"
        document.lang = I18n.locale
        PdfWriter.new(document, table).draw
        document.to_slice
      end

      def self.company_name : String
        Partiduo::Api::Core.settings(Partiduo::Api::Actor.system).company_name
      rescue Partiduo::Api::NotFound
        ""
      end

      # Mise en page d'un tableau, page après page.
      class PdfWriter
        MARGIN     = 36.0
        ROW_HEIGHT = 11.0
        FONT_SIZE  =  7.5
        BOTTOM     = 40.0

        @width : Float64
        @height : Float64
        @regular : PDF::Fonts::TrueTypeFont
        @bold : PDF::Fonts::TrueTypeFont
        @pages = [] of PDF::Page
        @page : PDF::Page? = nil
        @y = 0.0
        @edges = [] of {Float64, Float64}

        def initialize(@document : PDF::A::Document, @table : Table)
          @width, @height = @table.landscape ? {841.89, 595.28} : {595.28, 841.89}
          @regular = @document.load_font(FONT_REGULAR.to_slice, "DejaVuSans")
          @bold = @document.load_font(FONT_BOLD.to_slice, "DejaVuSans-Bold")
          usable = @width - 2 * MARGIN
          total = @table.columns.sum(&.weight)
          x = MARGIN
          @edges = @table.columns.map do |column|
            span = usable * column.weight / total
            edge = {x, x + span}
            x += span
            edge
          end
        end

        def draw : Nil
          new_page
          @table.rows.each { |row| draw_row(row) }
          footers
        end

        private def page : PDF::Page
          @page || raise "page absente"
        end

        private def new_page : Nil
          current = @document.page(@width, @height) { }
          @pages << current
          @page = current
          @y = @height - MARGIN
          text(ReportOutput.company_name, MARGIN, @y - 10, 9.0, bold: true)
          text_right(@table.title, @width - MARGIN, @y - 10, 11.0, bold: true)
          @y -= 24
          @table.subtitle.each do |line|
            text_right(line, @width - MARGIN, @y, 8.0)
            @y -= 11
          end
          @y -= 6
          header
        end

        private def header : Nil
          band(@y - 3, ROW_HEIGHT + 2, "#e8eef0")
          @table.columns.each_with_index do |column, index|
            cell(column.title, index, column.right?, bold: true)
          end
          @y -= ROW_HEIGHT + 3
        end

        private def draw_row(row : Row) : Nil
          new_page if @y - ROW_HEIGHT < BOTTOM
          bold = row.style != :line
          rule(@y + ROW_HEIGHT - 2) if row.style == :total
          row.cells.each_with_index do |value, index|
            column = @table.columns[index]? || next
            content = case value
                      when BigDecimal then ReportOutput.format_amount(value)
                      when Time       then ReportOutput.format_date(value)
                      when Int32      then value.to_s
                      when String     then value
                      else                 ""
                      end
            content = ("  " * row.indent) + content if index.zero? && row.indent > 0
            cell(content, index, column.right?, bold: bold)
          end
          @y -= ROW_HEIGHT
        end

        private def cell(content : String, index : Int32, right : Bool, bold : Bool = false) : Nil
          left, edge = @edges[index]
          room = edge - left - 4
          font = bold ? @bold : @regular
          fitted = content
          while !fitted.empty? && font.string_width(fitted, FONT_SIZE) > room
            fitted = fitted[0, fitted.size - 1]
          end
          if right
            text_right(fitted, edge - 2, @y, FONT_SIZE, bold)
          else
            text(fitted, left + 2, @y, FONT_SIZE, bold)
          end
        end

        private def footers : Nil
          count = @pages.size
          @pages.each_with_index do |current, index|
            @page = current
            label = I18n.t("accounting.reports.page", {"page" => (index + 1).to_s, "count" => count.to_s})
            text_right(label, @width - MARGIN, 22.0, 7.0)
            text("Partiduo", MARGIN, 22.0, 7.0)
          end
        end

        private def text(value : String, x : Float64, y : Float64, size : Float64, bold : Bool = false) : Nil
          return if value.empty?
          page.fill_color("#1a1a1a")
          page.font(bold ? @bold : @regular, size: size)
          page.text(value, at: {x, y})
        end

        private def text_right(value : String, right : Float64, y : Float64, size : Float64, bold : Bool = false) : Nil
          width = (bold ? @bold : @regular).string_width(value, size)
          text(value, right - width, y, size, bold)
        end

        private def rule(y : Float64) : Nil
          page.stroke_color("#8a969c")
          page.line_width(0.5)
          page.move_to(MARGIN, y)
          page.line_to(@width - MARGIN, y)
          page.stroke
        end

        private def band(y : Float64, height : Float64, color : String) : Nil
          page.fill_color(color)
          page.rectangle(MARGIN, y, @width - 2 * MARGIN, height)
          page.fill
        end
      end
    end
  end
end
