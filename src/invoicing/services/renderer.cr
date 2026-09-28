# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Invoicing
    # Mise en page A4 d'un document : en-tête (logo, vendeur, titre, numéro,
    # dates), client et livraison, lignes (titres, sous-totaux, remises),
    # récapitulatif de TVA, totaux, mentions obligatoires, pied de page
    # numéroté. Le modèle (`Api::LayoutView`) ne règle que le logo, les
    # couleurs et les textes d'en-tête et de pied : les mentions viennent
    # toujours de `Mentions` et sont imprimées en entier.
    class Renderer
      alias Api = Partiduo::Api::Invoicing

      WIDTH  = 595.28
      HEIGHT = 841.89
      MARGIN =   42.0
      BOTTOM =   60.0
      RIGHT  = WIDTH - MARGIN

      # Colonnes du tableau des lignes : bord droit de chaque colonne chiffrée.
      COL_DESCRIPTION   = MARGIN + 4
      COL_QUANTITY      = 300.0
      COL_UNIT          = 306.0
      COL_PRICE         = 402.0
      COL_DISCOUNT      = 450.0
      COL_VAT           = 488.0
      COL_TOTAL         = RIGHT - 4
      DESCRIPTION_WIDTH = 240.0

      @regular : PDF::Fonts::TrueTypeFont
      @bold : PDF::Fonts::TrueTypeFont
      @page : PDF::Page
      @pages = [] of PDF::Page
      @y : Float64 = HEIGHT - MARGIN

      def initialize(@document : PDF::Document, @view : Api::DocumentView, @layout : Api::LayoutView?,
                     @copy : Bool = false)
        @regular = @document.load_font(Output::FONT_REGULAR.to_slice, "DejaVuSans")
        @bold = @document.load_font(Output::FONT_BOLD.to_slice, "DejaVuSans-Bold")
        @page = new_page
      end

      def locale : String
        @view.locale
      end

      def primary : String
        @layout.try(&.primary_color) || "#1f5f73"
      end

      def ink : String
        @layout.try(&.text_color) || "#1a1a1a"
      end

      def draw : Nil
        header
        parties
        lines_table
        summary
        mentions
        footers
      end

      private def t(key : String, params = {} of String => String) : String
        I18n.t(key, params)
      end

      private def money(value : BigDecimal) : String
        Output.format_amount(value, locale, @view.currency_code)
      end

      private def number(value : BigDecimal) : String
        Output.format_amount(value, locale)
      end

      private def new_page : PDF::Page
        page = @document.page(WIDTH, HEIGHT) { }
        @pages << page
        @y = HEIGHT - MARGIN
        page
      end

      private def ensure_space(height : Float64) : Nil
        return if @y - height >= BOTTOM
        @page = new_page
      end

      private def text(value : String, x : Float64, y : Float64, size : Float64 = 9.0, bold : Bool = false,
                       color : String? = nil) : Nil
        return if value.empty?
        @page.fill_color(color || ink)
        @page.font(bold ? @bold : @regular, size: size)
        @page.text(value, at: {x, y})
      end

      private def text_right(value : String, right : Float64, y : Float64, size : Float64 = 9.0, bold : Bool = false,
                             color : String? = nil) : Nil
        width = (bold ? @bold : @regular).string_width(value, size)
        text(value, right - width, y, size, bold, color)
      end

      private def wrap(value : String, width : Float64, size : Float64, bold : Bool = false) : Array(String)
        font = bold ? @bold : @regular
        lines = [] of String
        value.split('\n').each do |paragraph|
          current = ""
          paragraph.split(' ').each do |word|
            candidate = current.empty? ? word : "#{current} #{word}"
            if font.string_width(candidate, size) <= width || current.empty?
              current = candidate
            else
              lines << current
              current = word
            end
          end
          lines << current
        end
        lines
      end

      private def rule(y : Float64, color : String = "#c8d0d4", width : Float64 = 0.5) : Nil
        @page.stroke_color(color)
        @page.line_width(width)
        @page.move_to(MARGIN, y)
        @page.line_to(RIGHT, y)
        @page.stroke
      end

      private def band(y : Float64, height : Float64, color : String) : Nil
        @page.fill_color(color)
        @page.rectangle(MARGIN, y, RIGHT - MARGIN, height)
        @page.fill
      end

      # --- En-tête ---------------------------------------------------------------

      private def header : Nil
        top = @y
        left = MARGIN
        if logo = logo_image
          ratio = Math.min(120.0 / logo.width, 48.0 / logo.height)
          width = logo.width * ratio
          height = logo.height * ratio
          @page.image(logo, at: {MARGIN, top - height}, width: width, height: height)
          top -= height + 8
        end
        seller = @view.seller
        y = top - 12
        text(seller.name, left, y, 12.0, bold: true, color: primary)
        (seller.address_lines + [seller.email, seller.phone].reject(&.empty?)).each do |line|
          y -= 11
          text(line, left, y, 8.5)
        end

        right_y = @y - 16
        text_right(t(@view.kind_key).upcase, RIGHT, right_y, 17.0, bold: true, color: primary)
        right_y -= 16
        label = @view.number ? "#{t("invoicing.pdf.number")} #{@view.number}" : t("invoicing.pdf.draft")
        text_right(label, RIGHT, right_y, 10.5, bold: true)
        dates = [] of {String, Time?}
        dates << {"invoicing.pdf.issue_date", @view.issue_date}
        dates << {"invoicing.pdf.due_date", @view.due_date} if @view.kind.in?("invoice", "deposit_invoice")
        dates << {"invoicing.pdf.validity_date", @view.validity_date} if @view.kind == "quote"
        dates.each do |(key, date)|
          next unless date
          right_y -= 12
          text_right("#{t(key)} : #{Output.format_date(date, locale)}", RIGHT, right_y, 8.5)
        end
        if origin = @view.origin_mention
          right_y -= 12
          text_right(origin.message, RIGHT, right_y, 8.0, color: "#555555")
        end
        @y = Math.min(y, right_y) - 16

        if header_text = @layout.try(&.header_text).presence
          wrap(header_text, RIGHT - MARGIN, 8.0).each do |line|
            text(line, MARGIN, @y, 8.0, color: "#555555")
            @y -= 10
          end
          @y -= 4
        end
      end

      private def logo_image : PDF::Images::Base?
        attachment_id = @layout.try(&.logo_attachment_id)
        return unless attachment_id
        bytes = Partiduo::Api::Core.attachment_content(Partiduo::Api::Actor.system, attachment_id)
        PDF::Images::Image.load(bytes)
      rescue
        nil
      end

      # --- Client et livraison -------------------------------------------------

      private def parties : Nil
        customer = @view.customer
        box_x = 310.0
        y = @y
        text(t("invoicing.pdf.customer"), box_x, y, 7.5, bold: true, color: primary)
        y -= 13
        text(customer.name, box_x, y, 10.5, bold: true)
        customer.address_lines.each do |line|
          y -= 11
          text(line, box_x, y, 9.0)
        end
        unless customer.code.empty?
          y -= 11
          text("#{t("invoicing.pdf.customer_code")} : #{customer.code}", box_x, y, 8.0, color: "#555555")
        end

        left_y = @y
        if address = @view.delivery_address
          if Mentions.differs?(address, customer)
            text(t("invoicing.pdf.delivery_address"), MARGIN, left_y, 7.5, bold: true, color: primary)
            address_rows = address.lines
            address_rows.each do |row|
              left_y -= 11
              text(row, MARGIN, left_y, 9.0)
            end
            left_y -= 6
          end
        end
        {"invoicing.pdf.buyer_reference" => @view.buyer_reference,
         "invoicing.pdf.order_reference" => @view.order_reference}.each do |key, value|
          next if value.empty?
          left_y -= 11
          text("#{t(key)} : #{value}", MARGIN, left_y, 8.5)
        end
        @y = Math.min(y, left_y) - 20
      end

      # --- Lignes ------------------------------------------------------------------

      private def table_header : Nil
        ensure_space(40)
        band(@y - 5, 17, primary)
        white = "#ffffff"
        text(t("invoicing.pdf.columns.description"), COL_DESCRIPTION, @y, 8.0, bold: true, color: white)
        text_right(t("invoicing.pdf.columns.quantity"), COL_QUANTITY, @y, 8.0, bold: true, color: white)
        text(t("invoicing.pdf.columns.unit"), COL_UNIT, @y, 8.0, bold: true, color: white)
        text_right(t("invoicing.pdf.columns.unit_price"), COL_PRICE, @y, 8.0, bold: true, color: white)
        text_right(t("invoicing.pdf.columns.discount"), COL_DISCOUNT, @y, 8.0, bold: true, color: white)
        text_right(t("invoicing.pdf.columns.vat"), COL_VAT, @y, 8.0, bold: true, color: white)
        text_right(t("invoicing.pdf.columns.total"), COL_TOTAL, @y, 8.0, bold: true, color: white)
        @y -= 20
      end

      private def lines_table : Nil
        table_header
        rows = @view.lines
        rows.each do |line|
          case line.kind
          when "title"
            rows = wrap(line.description, RIGHT - MARGIN - 8, 9.5, bold: true)
            reserve(rows.size * 12 + 6)
            rows.each do |row|
              text(row, COL_DESCRIPTION, @y, 9.5, bold: true, color: primary)
              @y -= 12
            end
            @y -= 2
          when "note"
            rows = wrap(line.description, RIGHT - MARGIN - 8, 8.5)
            reserve(rows.size * 11 + 4)
            rows.each do |row|
              text(row, COL_DESCRIPTION, @y, 8.5, color: "#444444")
              @y -= 11
            end
            @y -= 2
          when "subtotal"
            reserve(16)
            label = line.description.presence || t("invoicing.pdf.subtotal")
            text_right(label, COL_VAT, @y, 8.5, bold: true)
            text_right(number(line.net_amount), COL_TOTAL, @y, 8.5, bold: true)
            @y -= 4
            rule(@y + 1, "#8a9aa0")
            @y -= 12
          else
            priced_row(line)
          end
        end
        rule(@y + 6, primary, 0.8)
        @y -= 8
      end

      private def reserve(height : Float64) : Nil
        return if @y - height >= BOTTOM
        @page = new_page
        table_header
      end

      private def priced_row(line : Api::LineView) : Nil
        rows = wrap(line.description, DESCRIPTION_WIDTH, 9.0)
        reserve(rows.size * 11 + 5)
        top = @y
        rows.each_with_index do |row, index|
          text(row, COL_DESCRIPTION, top - index * 11, 9.0)
        end
        text_right(Output.format_quantity(line.quantity, locale), COL_QUANTITY, top, 9.0)
        text(unit_label(line.unit_code), COL_UNIT, top, 8.0)
        text_right(number(line.unit_price), COL_PRICE, top, 9.0)
        discount = case line.discount_kind
                   when "percent" then Output.format_percent(line.discount_value, locale)
                   when "amount"  then number(line.discount_amount)
                   else                ""
                   end
        text_right(discount, COL_DISCOUNT, top, 8.5)
        text_right(Output.format_percent(line.vat_percent, locale), COL_VAT, top, 8.5)
        text_right(number(line.net_amount), COL_TOTAL, top, 9.0)
        @y = top - rows.size * 11 - 5
      end

      private def unit_label(code : String) : String
        key = "cards.units.#{code.downcase}"
        label = I18n.t(key)
        label == key || label.includes?("missing") ? code : label
      end

      # --- Récapitulatif et totaux -------------------------------------------------

      private def summary : Nil
        totals = @view.totals
        rows = [] of {String, String, Bool}
        if totals.discount_total > 0
          rows << {t("invoicing.pdf.lines_total"), money(totals.lines_total), false}
          rows << {t("invoicing.pdf.global_discount"), "-#{money(totals.discount_total)}", false}
        end
        rows << {t("invoicing.pdf.total_net"), money(totals.total_net), false}
        rows << {t("invoicing.pdf.total_vat"), money(totals.total_vat), false}
        rows << {t("invoicing.pdf.total_gross"), money(totals.total_gross), true}
        if totals.prepaid > 0
          rows << {t("invoicing.pdf.prepaid"), "-#{money(totals.prepaid)}", false}
          rows << {t("invoicing.pdf.payable"), money(totals.payable), true}
        end
        needed = Math.max(rows.size * 14, (@view.vat_breakdown.size + 1) * 12) + 20
        ensure_space(needed)

        # Récapitulatif de TVA, à gauche.
        y = @y
        text(t("invoicing.pdf.vat_summary.rate"), MARGIN, y, 7.5, bold: true, color: primary)
        text_right(t("invoicing.pdf.vat_summary.base"), MARGIN + 170, y, 7.5, bold: true, color: primary)
        text_right(t("invoicing.pdf.vat_summary.vat"), MARGIN + 240, y, 7.5, bold: true, color: primary)
        @view.vat_breakdown.each do |group|
          y -= 12
          label = "#{group.category} #{Output.format_percent(group.percent, locale)}"
          text(label, MARGIN, y, 8.5)
          text_right(number(group.base), MARGIN + 170, y, 8.5)
          text_right(number(group.vat), MARGIN + 240, y, 8.5)
        end

        # Totaux, à droite.
        right_y = @y
        rows.each do |(label, value, strong)|
          if strong
            band(right_y - 4, 15, "#eef3f5")
          end
          text(label, 330.0, right_y, strong ? 9.5 : 9.0, bold: strong)
          text_right(value, COL_TOTAL, right_y, strong ? 9.5 : 9.0, bold: strong)
          right_y -= 15
        end
        @y = Math.min(y, right_y) - 18
      end

      # --- Mentions ----------------------------------------------------------------

      private def mentions : Nil
        paragraphs = @view.mentions.map { |mention| Output.mention_text(mention, @view) }
        paragraphs << @view.notes unless @view.notes.empty?
        return if paragraphs.empty?
        ensure_space(30)
        text(t("invoicing.pdf.mentions"), MARGIN, @y, 7.5, bold: true, color: primary)
        @y -= 11
        paragraphs.each do |paragraph|
          rows = wrap(paragraph, RIGHT - MARGIN, 7.5)
          ensure_space(rows.size * 9.5)
          rows.each do |row|
            text(row, MARGIN, @y, 7.5)
            @y -= 9.5
          end
        end
      end

      # --- Pieds de page -------------------------------------------------------------

      # Bandeau de la copie PDF (ADR-004 D9), en haut de chaque page.
      private def copy_banner : Nil
        y = HEIGHT - 20
        wrap(t("invoicing.pdf_copy.banner"), RIGHT - MARGIN, 8.5, bold: true).first(2).each do |row|
          text(row, MARGIN, y, 8.5, bold: true, color: "#b42318")
          y -= 10
        end
      end

      private def footers : Nil
        footer = @layout.try(&.footer_text).presence
        seller = @view.seller
        legal = [seller.name, seller.legal_form, seller.rcs, seller.vat_number].reject(&.empty?).join(" — ")
        total = @pages.size
        @pages.each_with_index do |page, index|
          @page = page
          copy_banner if @copy
          rule(BOTTOM - 12, "#c8d0d4")
          y = BOTTOM - 24
          text(legal, MARGIN, y, 7.0, color: "#555555")
          text_right(t("invoicing.pdf.page", {"page" => (index + 1).to_s, "pages" => total.to_s}), RIGHT, y, 7.0,
            color: "#555555")
          if footer
            wrap(footer, RIGHT - MARGIN - 60, 7.0).first(2).each do |row|
              y -= 9
              text(row, MARGIN, y, 7.0, color: "#555555")
            end
          end
        end
      end
    end
  end
end
