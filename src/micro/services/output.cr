# SPDX-License-Identifier: AGPL-3.0-or-later

require "csv"
require "pdf-a"

module Partiduo
  module Micro
    # Éditions du livre des recettes et du registre des achats (ADR-007 D1) :
    #
    # * CSV : séparateur `;`, UTF-8, montants au point décimal, dates
    #   `AAAA-MM-JJ`, cellules de texte protégées contre les formules
    #   (D-2F-009), en-têtes dans la langue courante ;
    # * PDF : PDF/A-2b (`prod-crystal/pdf-a`), A4 paysage, polices DejaVu
    #   embarquées, en-tête (société, titre, période), pied numéroté, total
    #   et récapitulatif par nature.
    #
    # Service interne ; le module ne dépend d'aucun autre (ADR-006 D3), d'où
    # sa propre mise en page plutôt que celle des éditions comptables.
    module Output
      alias Api = Partiduo::Api::Micro

      FONT_REGULAR = {{ read_file("#{__DIR__}/../../../data/fonts/DejaVuSans.ttf") }}
      FONT_BOLD    = {{ read_file("#{__DIR__}/../../../data/fonts/DejaVuSans-Bold.ttf") }}

      COLUMNS = %w[number date party label nature method reference amount vat_amount]
      WEIGHTS = [1.1, 0.9, 2.2, 2.4, 1.4, 1.0, 1.2, 1.0, 0.9]

      def self.plain(value : BigDecimal) : String
        text = value.round(2, mode: :ties_away).to_s
        integer, _, fraction = text.partition('.')
        "#{integer}.#{fraction.ljust(2, '0')[0, 2]}"
      end

      def self.amount(value : BigDecimal) : String
        text = plain(value)
        negative = text.starts_with?('-')
        integer, _, fraction = text.lchop('-').partition('.')
        thousands, decimal = case I18n.locale
                             when "en" then {",", "."}
                             when "nl" then {".", ","}
                             else           {" ", ","}
                             end
        grouped = integer.reverse.scan(/\d{1,3}/).map(&.[0]).join(thousands).reverse
        "#{negative ? "-" : ""}#{grouped}#{decimal}#{fraction}"
      end

      def self.date(value : Time) : String
        case I18n.locale
        when "en" then value.to_s("%Y-%m-%d")
        when "nl" then value.to_s("%d-%m-%Y")
        else           value.to_s("%d/%m/%Y")
        end
      end

      def self.protect(text : String) : String
        text.starts_with?(/[=+\-@\t\r]/) ? "'#{text}" : text
      end

      def self.file(register : String, lines : Array(Api::LineView), query : Api::RegisterQuery,
                    format : Api::ExportFormat) : Api::FileView
        name = I18n.t("micro.export.filename.#{register}")
        if format.csv?
          Api::FileView.new("#{name}.csv", "text/csv; charset=utf-8", csv(lines))
        else
          Api::FileView.new("#{name}.pdf", "application/pdf", pdf(register, lines, query))
        end
      end

      def self.csv(lines : Array(Api::LineView)) : Bytes
        CSV.build(separator: ';') do |csv|
          csv.row(COLUMNS.map { |key| protect(I18n.t("micro.columns.#{key}")) })
          lines.each do |line|
            csv.row([protect(line.number), line.date.to_s("%Y-%m-%d"), protect(line.party_name), protect(line.label),
                     protect(line.nature_label), I18n.t(line.method_key), protect(line.reference), plain(line.amount),
                     plain(line.vat_amount)])
          end
        end.to_slice
      end

      def self.company_name : String
        Partiduo::Api::Core.settings(Partiduo::Api::Actor.system).company_name
      rescue Partiduo::Api::NotFound
        ""
      end

      def self.pdf(register : String, lines : Array(Api::LineView), query : Api::RegisterQuery) : Bytes
        title = I18n.t("micro.reports.#{register}")
        subtitle = [] of String
        from, to = query.from, query.to
        if from && to
          subtitle << I18n.t("micro.reports.period", {"from" => date(from), "to" => date(to)})
        end
        document = PDF::A::Document.new(PDF::A::Profile::A_2B)
        document.title = title
        document.author = company_name
        document.creator = "Partiduo #{Partiduo::VERSION}"
        document.producer = "Partiduo #{Partiduo::VERSION}"
        document.lang = I18n.locale
        rows = lines.map do |line|
          [line.number, date(line.date), line.party_name, line.label, line.nature_label, I18n.t(line.method_key),
           line.reference, amount(line.amount), amount(line.vat_amount)]
        end
        totals = [] of Array(String)
        total = lines.sum(BigDecimal.new(0), &.amount)
        totals << ["", "", "", I18n.t("micro.reports.total"), "", "", "", amount(total),
                   amount(lines.sum(BigDecimal.new(0), &.vat_amount))]
        lines.group_by(&.nature_label).to_a.sort_by!(&.[0]).each do |label, group|
          totals << ["", "", "", I18n.t("micro.reports.total_nature", {"nature" => label}), "", "", "",
                     amount(group.sum(BigDecimal.new(0), &.amount)), amount(group.sum(BigDecimal.new(0), &.vat_amount))]
        end
        Writer.new(document, title, subtitle, rows, totals).draw
        document.to_slice
      end

      # Mise en page d'un tableau A4 paysage, page après page.
      class Writer
        MARGIN     =   36.0
        ROW_HEIGHT =   11.0
        FONT_SIZE  =    7.5
        BOTTOM     =   40.0
        WIDTH      = 841.89
        HEIGHT     = 595.28

        @regular : PDF::Fonts::TrueTypeFont
        @bold : PDF::Fonts::TrueTypeFont
        @pages = [] of PDF::Page
        @page : PDF::Page? = nil
        @y = 0.0
        @edges = [] of {Float64, Float64}

        def initialize(@document : PDF::A::Document, @title : String, @subtitle : Array(String),
                       @rows : Array(Array(String)), @totals : Array(Array(String)))
          @regular = @document.load_font(FONT_REGULAR.to_slice, "DejaVuSans")
          @bold = @document.load_font(FONT_BOLD.to_slice, "DejaVuSans-Bold")
          usable = WIDTH - 2 * MARGIN
          total = WEIGHTS.sum
          x = MARGIN
          @edges = WEIGHTS.map do |weight|
            span = usable * weight / total
            edge = {x, x + span}
            x += span
            edge
          end
        end

        def draw : Nil
          new_page
          @rows.each { |row| draw_row(row, false) }
          @totals.each { |row| draw_row(row, true) }
          footers
        end

        private def page : PDF::Page
          @page || raise "page absente"
        end

        private def new_page : Nil
          current = @document.page(WIDTH, HEIGHT) { }
          @pages << current
          @page = current
          @y = HEIGHT - MARGIN
          text(Output.company_name, MARGIN, @y - 10, 9.0, true)
          text_right(@title, WIDTH - MARGIN, @y - 10, 11.0, true)
          @y -= 24
          @subtitle.each do |line|
            text_right(line, WIDTH - MARGIN, @y, 8.0)
            @y -= 11
          end
          @y -= 6
          page.fill_color("#e8eef0")
          page.rectangle(MARGIN, @y - 3, WIDTH - 2 * MARGIN, ROW_HEIGHT + 2)
          page.fill
          COLUMNS.each_with_index { |key, index| cell(I18n.t("micro.columns.#{key}"), index, true) }
          @y -= ROW_HEIGHT + 3
        end

        private def draw_row(row : Array(String), bold : Bool) : Nil
          new_page if @y - ROW_HEIGHT < BOTTOM
          row.each_with_index { |value, index| cell(value, index, bold) }
          @y -= ROW_HEIGHT
        end

        private def cell(content : String, index : Int32, bold : Bool) : Nil
          left, edge = @edges[index]
          font = bold ? @bold : @regular
          fitted = content
          while !fitted.empty? && font.string_width(fitted, FONT_SIZE) > edge - left - 4
            fitted = fitted[0, fitted.size - 1]
          end
          if index >= 7
            text_right(fitted, edge - 2, @y, FONT_SIZE, bold)
          else
            text(fitted, left + 2, @y, FONT_SIZE, bold)
          end
        end

        private def footers : Nil
          count = @pages.size
          @pages.each_with_index do |current, index|
            @page = current
            label = I18n.t("micro.reports.page", {"page" => (index + 1).to_s, "count" => count.to_s})
            text_right(label, WIDTH - MARGIN, 22.0, 7.0)
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
      end
    end
  end
end
