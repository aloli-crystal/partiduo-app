# SPDX-License-Identifier: AGPL-3.0-or-later

require "csv"
require "pdf-a"

module Partiduo
  module Liberal
    # Éditions du module liberal (ADR-007 D6) :
    #
    # * livre-journal en CSV (séparateur `;`, UTF-8, montants au point
    #   décimal, dates `AAAA-MM-JJ`, cellules protégées contre les formules,
    #   D-2F-009) et en PDF ;
    # * édition de contrôle de la 2035 préparée en PDF : identification,
    #   postes de la 2035-A et de la 2035-B avec ligne et case, tableau des
    #   immobilisations, cessions, réintégrations et déductions, contrôles.
    #
    # PDF/A-2b (`prod-crystal/pdf-a`), A4 paysage, polices DejaVu embarquées,
    # pied numéroté. Mise en page propre au module, qui ne dépend d'aucun
    # autre (ADR-006 D3, comme D-MIC-010). Service interne.
    module Output
      alias Api = Partiduo::Api::Liberal

      FONT_REGULAR = {{ read_file("#{__DIR__}/../../../data/fonts/DejaVuSans.ttf") }}
      FONT_BOLD    = {{ read_file("#{__DIR__}/../../../data/fonts/DejaVuSans-Bold.ttf") }}

      JOURNAL_COLUMNS = %w[number date kind party label heading method reference amount nondeductible]
      JOURNAL_WEIGHTS = [1.1, 0.9, 0.8, 2.0, 2.2, 2.0, 1.0, 1.1, 1.0, 1.0]

      def self.plain(value : BigDecimal) : String
        text = value.round(2, mode: :ties_away).to_s
        integer, _, fraction = text.partition('.')
        "#{integer}.#{fraction.ljust(2, '0')[0, 2]}"
      end

      def self.amount(value : BigDecimal, decimals : Bool = true) : String
        text = decimals ? plain(value) : value.round(0, mode: :ties_away).to_s.split('.').first
        negative = text.starts_with?('-')
        integer, _, fraction = text.lchop('-').partition('.')
        thousands, decimal = case I18n.locale
                             when "en" then {",", "."}
                             when "nl" then {".", ","}
                             else           {" ", ","}
                             end
        grouped = integer.reverse.scan(/\d{1,3}/).map(&.[0]).join(thousands).reverse
        "#{negative ? "-" : ""}#{grouped}#{fraction.empty? ? "" : decimal + fraction}"
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

      def self.company_name : String
        Partiduo::Api::Core.settings(Partiduo::Api::Actor.system).company_name
      rescue Partiduo::Api::NotFound
        ""
      end

      def self.document(title : String) : PDF::A::Document
        document = PDF::A::Document.new(PDF::A::Profile::A_2B)
        document.title = title
        document.author = company_name
        document.creator = "Partiduo #{Partiduo::VERSION}"
        document.producer = "Partiduo #{Partiduo::VERSION}"
        document.lang = I18n.locale
        document
      end

      # --- Livre-journal ------------------------------------------------------------------

      def self.journal(lines : Array(Api::LineView), query : Api::JournalQuery, format : Api::ExportFormat) : Api::FileView
        name = I18n.t("liberal.export.filename.journal")
        if format.csv?
          Api::FileView.new("#{name}.csv", "text/csv; charset=utf-8", journal_csv(lines))
        else
          Api::FileView.new("#{name}.pdf", "application/pdf", journal_pdf(lines, query))
        end
      end

      def self.journal_row(line : Api::LineView) : Array(String)
        [line.number, date(line.date), I18n.t("liberal.kinds.#{line.kind}"), line.party_name, line.label,
         I18n.t(line.heading_key), I18n.t(line.method_key), line.reference, amount(line.amount),
         line.nondeductible_amount.zero? ? "" : amount(line.nondeductible_amount)]
      end

      def self.journal_csv(lines : Array(Api::LineView)) : Bytes
        CSV.build(separator: ';') do |csv|
          csv.row(JOURNAL_COLUMNS.map { |key| protect(I18n.t("liberal.columns.#{key}")) })
          lines.each do |line|
            csv.row([protect(line.number), line.date.to_s("%Y-%m-%d"), line.kind, protect(line.party_name),
                     protect(line.label), line.heading, I18n.t(line.method_key), protect(line.reference),
                     plain(line.amount), plain(line.nondeductible_amount)])
          end
        end.to_slice
      end

      def self.journal_pdf(lines : Array(Api::LineView), query : Api::JournalQuery) : Bytes
        title = I18n.t("liberal.reports.journal")
        subtitle = [] of String
        from, to = query.from, query.to
        subtitle << I18n.t("liberal.reports.period", {"from" => date(from), "to" => date(to)}) if from && to
        document = document(title)
        receipts = lines.select(&.receipt?).sum(BigDecimal.new(0), &.amount)
        expenses = lines.reject(&.receipt?).sum(BigDecimal.new(0), &.amount)
        totals = [
          ["", "", "", "", I18n.t("liberal.reports.total_receipts"), "", "", "", amount(receipts), ""],
          ["", "", "", "", I18n.t("liberal.reports.total_expenses"), "", "", "", amount(expenses), ""],
          ["", "", "", "", I18n.t("liberal.reports.balance"), "", "", "", amount(receipts - expenses), ""],
        ]
        headers = JOURNAL_COLUMNS.map { |key| I18n.t("liberal.columns.#{key}") }
        writer = Writer.new(document, title, headers, JOURNAL_WEIGHTS, [8, 9])
        writer.section(subtitle, lines.map { |line| journal_row(line) }, totals)
        writer.finish
        document.to_slice
      end

      # --- 2035 ---------------------------------------------------------------------------

      FORM_WEIGHTS   = [1.0, 0.7, 0.7, 5.0, 1.4]
      ASSET_WEIGHTS  = [1.0, 2.6, 1.2, 0.9, 0.9, 1.1, 0.6, 1.1, 1.1, 1.1]
      RESULT_WEIGHTS = [1.0, 2.6, 0.9, 1.1, 1.1, 1.1, 1.1, 1.1]
      CHECK_WEIGHTS  = [1.2, 8.0]

      def self.tax_return(view : Api::TaxReturnView) : Api::FileView
        name = I18n.t("liberal.export.filename.tax_return", {"year" => view.year.to_s})
        Api::FileView.new("#{name}.pdf", "application/pdf", tax_return_pdf(view))
      end

      def self.tax_return_pdf(view : Api::TaxReturnView) : Bytes
        title = I18n.t("liberal.reports.tax_return", {"year" => view.year.to_s})
        document = document(title)
        identity = view.identity
        heading = [
          I18n.t("liberal.reports.identity", {"name" => identity.company_name, "siren" => identity.siren}),
          [identity.street_number, identity.street, identity.postcode, identity.city].reject(&.empty?).join(" "),
          I18n.t("liberal.reports.profession", {"profession" => identity.profession}),
          I18n.t("liberal.reports.fingerprint", {"fingerprint" => view.fingerprint[0, 16]}),
        ]
        form_headers = %w[form line box item amount].map { |key| I18n.t("liberal.columns.#{key}") }
        writer = Writer.new(document, title, form_headers, FORM_WEIGHTS, [4])
        %w[2035-A 2035-B].each_with_index do |form, index|
          rows = view.form(form).map do |line|
            [line.form, line.line, line.box, I18n.t(line.item_key), amount(line.amount, decimals: false)]
          end
          writer.section(index.zero? ? heading : [] of String, rows, [] of Array(String), I18n.t("liberal.reports.form", {"form" => form}))
        end

        asset_headers = %w[number label category acquired_on service_on amount rate prior year_amount net_value]
          .map { |key| I18n.t("liberal.columns.#{key}") }
        writer.table(asset_headers, ASSET_WEIGHTS, [5, 6, 7, 8, 9])
        rows = view.assets.map do |row|
          [row.number, row.label, I18n.t("liberal.asset_categories.#{row.category}"), date(row.acquired_on),
           date(row.service_on), amount(row.amount), row.rate.try { |rate| amount(rate) } || "", amount(row.prior),
           amount(row.year_amount), amount(row.net_value)]
        end
        total = ["", I18n.t("liberal.reports.total"), "", "", "", amount(view.assets.sum(BigDecimal.new(0), &.amount)), "",
                 amount(view.assets.sum(BigDecimal.new(0), &.prior)),
                 amount(view.assets.sum(BigDecimal.new(0), &.year_amount)),
                 amount(view.assets.sum(BigDecimal.new(0), &.net_value))]
        writer.section([] of String, rows, [total], I18n.t("liberal.reports.assets"))

        unless view.disposals.empty?
          result_headers = %w[number label date price net_value gain short_term long_term]
            .map { |key| I18n.t("liberal.columns.#{key}") }
          writer.table(result_headers, RESULT_WEIGHTS, [3, 4, 5, 6, 7])
          rows = view.disposals.map do |row|
            [row.number, row.label, date(row.date), amount(row.price), amount(row.net_value), amount(row.gain),
             amount(row.short_term), amount(row.long_term)]
          end
          writer.section([] of String, rows, [] of Array(String), I18n.t("liberal.reports.disposals"))
        end

        unless view.adjustments.empty?
          writer.table(%w[kind label amount].map { |key| I18n.t("liberal.columns.#{key}") }, [2.0, 6.0, 1.4], [2])
          rows = view.adjustments.map { |row| [I18n.t(row.kind_key), row.label, amount(row.amount)] }
          writer.section([] of String, rows, [] of Array(String), I18n.t("liberal.reports.adjustments"))
        end

        writer.table(%w[severity control].map { |key| I18n.t("liberal.columns.#{key}") }, CHECK_WEIGHTS, [] of Int32)
        rows = view.controls.map { |control| [I18n.t("liberal.severities.#{control.severity}"), I18n.t(control.key, control.params)] }
        rows << ["", I18n.t("liberal.reports.no_control")] if rows.empty?
        writer.section([] of String, rows, [] of Array(String), I18n.t("liberal.reports.controls"))
        writer.finish
        document.to_slice
      end

      # Mise en page de tableaux A4 paysage, page après page.
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
        @headers = [] of String
        @right = [] of Int32

        def initialize(@document : PDF::A::Document, @title : String, headers : Array(String), weights : Array(Float64),
                       right : Array(Int32))
          @regular = @document.load_font(FONT_REGULAR.to_slice, "DejaVuSans")
          @bold = @document.load_font(FONT_BOLD.to_slice, "DejaVuSans-Bold")
          table(headers, weights, right)
          new_page(false)
        end

        # Change les colonnes du tableau suivant.
        def table(headers : Array(String), weights : Array(Float64), right : Array(Int32)) : Nil
          @headers = headers
          @right = right
          usable = WIDTH - 2 * MARGIN
          total = weights.sum
          x = MARGIN
          @edges = weights.map do |weight|
            span = usable * weight / total
            edge = {x, x + span}
            x += span
            edge
          end
        end

        # Un titre de section, des lignes d'introduction, un tableau.
        def section(intro : Array(String), rows : Array(Array(String)), totals : Array(Array(String)),
                    caption : String? = nil) : Nil
          intro.each do |line|
            new_page(false) if @y - ROW_HEIGHT < BOTTOM
            text(line, MARGIN, @y, 8.0)
            @y -= 11
          end
          if caption
            new_page(false) if @y - 3 * ROW_HEIGHT < BOTTOM
            @y -= 4
            text(caption, MARGIN, @y, 9.0, true)
            @y -= 13
          end
          header
          rows.each { |row| draw_row(row, false) }
          totals.each { |row| draw_row(row, true) }
          @y -= 8
        end

        def finish : Nil
          count = @pages.size
          @pages.each_with_index do |current, index|
            @page = current
            label = I18n.t("liberal.reports.page", {"page" => (index + 1).to_s, "count" => count.to_s})
            text_right(label, WIDTH - MARGIN, 22.0, 7.0)
            text("Partiduo", MARGIN, 22.0, 7.0)
          end
        end

        private def page : PDF::Page
          @page || raise "page absente"
        end

        private def new_page(with_header : Bool = true) : Nil
          current = @document.page(WIDTH, HEIGHT) { }
          @pages << current
          @page = current
          @y = HEIGHT - MARGIN
          text(Output.company_name, MARGIN, @y - 10, 9.0, true)
          text_right(@title, WIDTH - MARGIN, @y - 10, 11.0, true)
          @y -= 30
          header if with_header
        end

        private def header : Nil
          new_page(false) if @y - 2 * ROW_HEIGHT < BOTTOM
          page.fill_color("#e8eef0")
          page.rectangle(MARGIN, @y - 3, WIDTH - 2 * MARGIN, ROW_HEIGHT + 2)
          page.fill
          @headers.each_with_index { |value, index| cell(value, index, true) }
          @y -= ROW_HEIGHT + 3
        end

        private def draw_row(row : Array(String), bold : Bool) : Nil
          new_page if @y - ROW_HEIGHT < BOTTOM
          row.each_with_index { |value, index| cell(value, index, bold) if index < @edges.size }
          @y -= ROW_HEIGHT
        end

        private def cell(content : String, index : Int32, bold : Bool) : Nil
          left, edge = @edges[index]
          font = bold ? @bold : @regular
          fitted = content
          while !fitted.empty? && font.string_width(fitted, FONT_SIZE) > edge - left - 4
            fitted = fitted[0, fitted.size - 1]
          end
          if @right.includes?(index)
            text_right(fitted, edge - 2, @y, FONT_SIZE, bold)
          else
            text(fitted, left + 2, @y, FONT_SIZE, bold)
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
