# SPDX-License-Identifier: AGPL-3.0-or-later

require "json"

module Partiduo
  module Invoicing
    # Brouillons, vues et transformations des documents (ADR-006 D5). Appelé
    # par `Partiduo::Api::Invoicing` seulement.
    module Documents
      alias Api = Partiduo::Api::Invoicing
      alias FieldError = Partiduo::Api::FieldError

      MAX_LINES = 500

      # Ligne complétée depuis la fiche article et le taux de TVA.
      record ResolvedLine,
        kind : String,
        item_card_id : Int64?,
        description : String,
        quantity : BigDecimal,
        unit_code : String,
        unit_price : BigDecimal,
        discount_kind : String,
        discount_value : BigDecimal,
        rate : Partiduo::Api::Vat::RateView?,
        delivery_note_id : Int64? = nil,
        return_note_id : Int64? = nil do
        def data : Calculator::LineData
          Calculator::LineData.new(
            kind: kind, quantity: quantity, unit_price: unit_price, discount_kind: discount_kind,
            discount_value: discount_value, vat_rate_id: rate.try(&.id), vat_percent: rate.try(&.rate) || BigDecimal.new(0),
            vat_category: rate.try(&.category) || "", exemption_code: rate.try(&.exemption_code) || "",
            exemption_reason: rate.try(&.exemption_reason) || "", item_card_id: item_card_id,
          )
        end
      end

      def self.error(field : String, key : String, params = {} of String => String) : FieldError
        FieldError.new(field, "invoicing.errors.#{key}", params)
      end

      def self.id_of(value) : Int64
        value.as(Int).to_i64
      end

      # Date du jour dans le fuseau de l'instance, et non en UTC : une facture
      # émise à 1 h, heure de Paris, porte la date du jour (D-2F-012).
      def self.today : Time
        Partiduo::Config.today
      end

      def self.find(id : Int64, lock : Bool = false) : Document
        query = Document.filter(id: id)
        query = query.lock if lock
        query.first || raise Partiduo::Api::NotFound.new("invoicing_document", id)
      end

      # --- Contrôle d'une saisie --------------------------------------------------

      # `source_id` : document d'origine d'une transformation (bon de retour
      # tiré d'un bon de livraison ou d'une facture : quantités contrôlées).
      def self.check(input : Api::DocumentInput, current : Document? = nil,
                     source_id : Int64? = nil) : {Array(ResolvedLine), Array(FieldError)}
        errors = kind_errors(input, current) + customer_errors(input) + header_errors(input)
        errors.concat(discount_errors("global_discount", input.global_discount_kind, input.global_discount_value))
        errors.concat(credit_errors(input, current))
        errors.concat(deposit_errors(input, current))
        errors.concat(Channels.input_errors(input))
        errors.concat(PaymentTerms.errors(input))
        errors.concat(DeliveryBilling.line_errors(input, current))
        errors.concat(Returns.line_errors(input, current))
        errors.concat(Returns.input_errors(input, current, source_id))
        lines = resolve_lines(input, errors)
        if errors.empty?
          totals = Calculator.compute(lines.map(&.data), input.global_discount_kind, input.global_discount_value)
          if totals.discount_total > totals.lines_total
            errors << error("global_discount_value", "document.global_discount.exceeds")
          end
        end
        {lines, errors}
      end

      private def self.kind_errors(input : Api::DocumentInput, current : Document?) : Array(FieldError)
        if current && current.kind != input.kind
          [error("kind", "document.kind.immutable")]
        elsif !Api::KINDS.includes?(input.kind)
          [error("kind", "document.kind.invalid")]
        else
          [] of FieldError
        end
      end

      private def self.customer_errors(input : Api::DocumentInput) : Array(FieldError)
        customer = Configuration.card(input.customer_card_id)
        code = if customer.nil?
                 "not_found"
               elsif customer.kind != "customer"
                 "not_customer"
               elsif !customer.enabled
                 "disabled"
               end
        code ? [error("customer_card_id", "document.customer.#{code}")] : [] of FieldError
      end

      private def self.header_errors(input : Api::DocumentInput) : Array(FieldError)
        errors = currency_errors(input.currency_code) + date_errors(input)
        if (category = input.operation_category.presence) && !Api::OPERATION_CATEGORIES.includes?(category)
          errors << error("operation_category", "document.operation_category.invalid")
        end
        if (locale = input.locale) && !Partiduo::LOCALES.includes?(locale)
          errors << error("locale", "document.locale.invalid")
        end
        if (layout_id = input.layout_id) && !Layout.filter(id: layout_id).exists?
          errors << error("layout_id", "document.layout.not_found")
        end
        {"buyer_reference" => input.buyer_reference, "order_reference" => input.order_reference}.each do |field, value|
          errors << error(field, "document.reference.too_long", {"max" => "100"}) if value && value.size > 100
        end
        errors
      end

      private def self.date_errors(input : Api::DocumentInput) : Array(FieldError)
        errors = [] of FieldError
        if (issue = input.issue_date) && (due = input.due_date) && due < issue
          errors << error("due_date", "document.due_date.before_issue")
        end
        if input.validity_date && input.kind != "quote"
          errors << error("validity_date", "document.validity_date.quote_only")
        end
        errors
      end

      private def self.currency_errors(code : String?) : Array(FieldError)
        return [] of FieldError unless code
        decimals = Configuration.currency_decimals(code)
        if decimals.nil?
          [error("currency_code", "document.currency.unknown", {"value" => code})]
        elsif decimals != Calculator::CENT
          [error("currency_code", "document.currency.decimals", {"value" => code})]
        else
          [] of FieldError
        end
      end

      private def self.resolve_lines(input : Api::DocumentInput, errors : Array(FieldError)) : Array(ResolvedLine)
        lines = [] of ResolvedLine
        if input.lines.size > MAX_LINES
          errors << error("lines", "document.lines.too_many", {"max" => MAX_LINES.to_s})
          return lines
        end
        input.lines.each_with_index do |line, index|
          resolved, line_errors = resolve_line(line, index)
          errors.concat(line_errors)
          lines << resolved if resolved
        end
        lines
      end

      def self.discount_errors(prefix : String, kind : String, value : BigDecimal) : Array(FieldError)
        errors = [] of FieldError
        if !Api::DISCOUNT_KINDS.includes?(kind)
          errors << error("#{prefix}_kind", "discount.kind")
        elsif value < 0
          errors << error("#{prefix}_value", "discount.negative")
        elsif kind == "percent" && (value > 100 || Calculator.scale(value) > 4)
          errors << error("#{prefix}_value", "discount.percent")
        elsif kind == "amount" && Calculator.scale(value) > Calculator::CENT
          errors << error("#{prefix}_value", "discount.amount_scale")
        end
        errors
      end

      private def self.credit_errors(input : Api::DocumentInput, current : Document?) : Array(FieldError)
        errors = [] of FieldError
        credited_id = input.credited_document_id
        if input.kind != "credit_note"
          errors << error("credited_document_id", "document.credited.credit_note_only") if credited_id
          return errors
        end
        if credited_id.nil?
          errors << error("credited_document_id", "document.credited.required")
          return errors
        end
        credited = Document.filter(id: credited_id).first
        if credited.nil? || !credited.kind.in?("invoice", "deposit_invoice") || credited.draft?
          errors << error("credited_document_id", "document.credited.invalid")
        elsif id_of(credited.customer_id) != input.customer_card_id
          errors << error("credited_document_id", "document.credited.other_customer")
        elsif deducted_deposit?(id_of(credited.id))
          errors << error("credited_document_id", "document.credited.deposit_deducted")
        end
        errors
      end

      # Acompte déduit d'une facture émise : il ne se crédite plus, c'est la
      # facture finale qui se corrige par avoir (D-2F-004).
      def self.deducted_deposit?(deposit_id : Int64) : Bool
        DepositDeduction.filter(deposit_id: deposit_id).any? do |deduction|
          Document.filter(id: deduction.invoice_id).exclude(number: nil).exists?
        end
      end

      private def self.deposit_errors(input : Api::DocumentInput, current : Document?) : Array(FieldError)
        errors = [] of FieldError
        return errors if input.deposit_ids.empty?
        if input.kind != "invoice"
          errors << error("deposit_ids", "document.deposits.invoice_only")
          return errors
        end
        if input.deposit_ids.uniq.size != input.deposit_ids.size
          errors << error("deposit_ids", "document.deposits.duplicate")
        end
        input.deposit_ids.each_with_index do |deposit_id, index|
          code = deposit_error(deposit_id, input.customer_card_id, current)
          errors << error("deposit_ids[#{index}]", "document.deposits.#{code}") if code
        end
        errors
      end

      # Motif du refus d'un acompte à déduire, ou `nil`.
      private def self.deposit_error(deposit_id : Int64, customer_id : Int64, current : Document?) : String?
        deposit = Document.filter(id: deposit_id).first
        if deposit.nil? || deposit.kind != "deposit_invoice" || deposit.draft?
          "invalid"
        elsif id_of(deposit.customer_id) != customer_id
          "other_customer"
        elsif deposit.status == "cancelled"
          "cancelled"
        elsif deposit.credited_amount! > 0
          # Acompte partiellement crédité : sa déduction ne vaudrait plus son
          # TTC, et ni l'écriture de la facture finale (D-INT-004) ni les
          # exports ne sauraient l'extourner exactement (D-2F-004).
          "credited"
        else
          other = DepositDeduction.filter(deposit_id: deposit_id).first
          "already_deducted" if other && (current.nil? || id_of(other.invoice_id) != id_of(current.id))
        end
      end

      private def self.resolve_line(line : Api::LineInput, index : Int32) : {ResolvedLine?, Array(FieldError)}
        path = "lines[#{index}]"
        return {nil, [error("#{path}.kind", "line.kind")]} unless Api::LINE_KINDS.includes?(line.kind)
        line.kind.in?("item", "free") ? priced_line(line, path) : text_line(line, path)
      end

      # Note, titre, sous-total : ni quantité, ni prix, ni taux.
      private def self.text_line(line : Api::LineInput, path : String) : {ResolvedLine?, Array(FieldError)}
        zero = BigDecimal.new(0)
        description = line.description.try(&.strip) || ""
        errors = [] of FieldError
        if line.kind != "subtotal" && description.empty?
          errors << error("#{path}.description", "line.description.blank")
        end
        {ResolvedLine.new(line.kind, nil, description, zero, "", zero, "none", zero, nil, line.delivery_note_id,
          line.return_note_id), errors}
      end

      private def self.priced_line(line : Api::LineInput, path : String) : {ResolvedLine?, Array(FieldError)}
        card, errors = line_item(line, path)
        description = line_description(line, card, path, errors)
        errors.concat(quantity_errors(line.quantity, path))
        unit_code = line.unit_code.presence || card.try(&.unit_code).presence || Partiduo::Cards::Units::DEFAULT
        errors << error("#{path}.unit_code", "line.unit_code") unless Partiduo::Api::Cards::UNITS.includes?(unit_code)
        unit_price = line.unit_price || card.try(&.sale_price)
        errors.concat(price_errors(unit_price, path))
        errors.concat(discount_errors("#{path}.discount", line.discount_kind, line.discount_value))
        rate, rate_errors = line_rate(line.vat_rate_id || card.try(&.vat_rate_id), path)
        errors.concat(rate_errors)
        resolved = ResolvedLine.new(line.kind, card.try(&.id), description, line.quantity, unit_code,
          unit_price || BigDecimal.new(0), line.discount_kind, line.discount_value, rate, line.delivery_note_id,
          line.return_note_id)
        if errors.empty? && discount_exceeds?(Calculator.line(resolved.data))
          errors << error("#{path}.discount_value", "line.discount.exceeds")
        end
        {resolved, errors}
      end

      # Désignation saisie, sinon (non saisie) le nom de l'article.
      private def self.line_description(line : Api::LineInput, card : Partiduo::Api::Cards::CardView?, path : String,
                                        errors : Array(FieldError)) : String
        description = line.description.try(&.strip) || card.try(&.name) || ""
        field = "#{path}.description"
        errors << error(field, "line.description.blank") if description.empty? && errors.empty?
        errors << error(field, "line.description.too_long", {"max" => "2000"}) if description.size > 2000
        description
      end

      # Article d'une ligne `item` (fiche de nature `item`, active) ; une ligne
      # libre n'en cite pas.
      private def self.line_item(line : Api::LineInput, path : String) : {Partiduo::Api::Cards::CardView?, Array(FieldError)}
        field = "#{path}.item_card_id"
        if line.kind == "free"
          return {nil, line.item_card_id ? [error(field, "line.item.free_line")] : [] of FieldError}
        end
        card_id = line.item_card_id
        return {nil, [error(field, "line.item.required")]} unless card_id
        card = Configuration.card(card_id)
        if card.nil? || !card.item?
          {nil, [error(field, "line.item.invalid")]}
        elsif !card.enabled
          {nil, [error(field, "line.item.disabled")]}
        else
          {card, [] of FieldError}
        end
      end

      private def self.quantity_errors(quantity : BigDecimal, path : String) : Array(FieldError)
        if quantity.zero?
          [error("#{path}.quantity", "line.quantity.zero")]
        elsif Calculator.scale(quantity) > 4
          [error("#{path}.quantity", "line.quantity.scale")]
        else
          [] of FieldError
        end
      end

      private def self.price_errors(price : BigDecimal?, path : String) : Array(FieldError)
        code = if price.nil?
                 "required"
               elsif price < 0
                 "negative"
               elsif Calculator.scale(price) > 4
                 "scale"
               end
        code ? [error("#{path}.unit_price", "line.unit_price.#{code}")] : [] of FieldError
      end

      private def self.line_rate(rate_id : Int64?, path : String) : {Partiduo::Api::Vat::RateView?, Array(FieldError)}
        field = "#{path}.vat_rate_id"
        return {nil, [error(field, "line.vat_rate.required")]} unless rate_id
        rate = Configuration.rate(rate_id)
        if rate.nil?
          {nil, [error(field, "line.vat_rate.not_found")]}
        elsif !rate.enabled
          {rate, [error(field, "line.vat_rate.disabled")]}
        else
          {rate, [] of FieldError}
        end
      end

      # Remise plus forte que le brut, ou de signe contraire.
      private def self.discount_exceeds?(result : Calculator::LineResult) : Bool
        result.discount.abs > result.gross.abs || (result.gross.sign * result.discount.sign) < 0
      end

      # --- Enregistrement du brouillon ---------------------------------------------

      def self.save_draft!(input : Api::DocumentInput, lines : Array(ResolvedLine), actor : Partiduo::Api::Actor,
                           document : Document? = nil, source_id : Int64? = nil) : Document
        settings = Configuration.settings
        customer = Configuration.card(input.customer_card_id) || raise Partiduo::Api::NotFound.new("card", input.customer_card_id)
        document ||= Document.new(kind: input.kind, series: Numbering.series_for(input.kind),
          created_by_id: actor.user_id, source_id: source_id)
        previous_customer_id = document.customer_id.try { |value| id_of(value) }
        document.customer_id = input.customer_card_id
        Channels.apply(document, input, customer, previous_customer_id)
        document.currency_code = input.currency_code || Configuration.base_currency
        document.locale = input.locale || Configuration.company.default_locale
        document.layout_id = input.layout_id
        document.issue_date = input.issue_date.try { |date| day(date) }
        document.delivery_date = input.delivery_date.try { |date| day(date) }
        document.due_date = input.due_date.try { |date| day(date) }
        document.validity_date = input.validity_date.try { |date| day(date) }
        document.operation_category = input.operation_category || ""
        document.buyer_reference = input.buyer_reference.to_s.strip
        document.order_reference = input.order_reference.to_s.strip
        document.notes = input.notes.to_s
        document.global_discount_kind = input.global_discount_kind
        document.global_discount_value = input.global_discount_value
        document.credited_id = input.credited_document_id
        document.vat_on_debits = settings.vat_on_debits
        document.payment_terms = input.payment_terms.presence || ""
        document.payment_terms_days = input.payment_terms_days
        document.delivery_address = delivery_address(input, customer).try { |value| Configuration.address_json(value) }
        document.return_reason = input.kind == "return_note" ? input.return_reason.presence || "" : ""

        totals = Calculator.compute(lines.map(&.data), input.global_discount_kind, input.global_discount_value)
        store_totals(document, totals)
        document.save!
        document_id = id_of(document.id)

        Line.filter(document_id: document_id).delete
        lines.each_with_index do |line, index|
          result = totals.lines[index]
          Line.create!(
            document_id: document_id, position: index + 1, kind: line.kind, item_id: line.item_card_id,
            description: line.description, quantity: line.quantity, unit_code: line.unit_code,
            unit_price: line.unit_price, discount_kind: line.discount_kind, discount_value: line.discount_value,
            discount_amount: result.discount, vat_rate_id: line.rate.try(&.id),
            vat_percent: line.rate.try(&.rate) || BigDecimal.new(0), vat_category: line.rate.try(&.category) || "",
            net_amount: result.net, delivery_note_id: line.delivery_note_id, return_note_id: line.return_note_id,
          )
        end

        DepositDeduction.filter(invoice_id: document_id).delete
        input.deposit_ids.each do |deposit_id|
          deposit = find(deposit_id)
          DepositDeduction.create!(invoice_id: document_id, deposit_id: deposit_id, amount: deposit.total_gross!)
        end
        # Bons de livraison facturés, bons de retour repris et période de
        # facturation (D-INV2-002, D-INV3-003).
        DeliveryBilling.sync!(document)
        document
      end

      # Adresse de livraison : celle donnée (vide : aucune), sinon la première
      # adresse de livraison de la fiche.
      private def self.delivery_address(input : Api::DocumentInput, customer) : Api::AddressView?
        if given = input.delivery_address
          return if given.line1.to_s.empty? && given.city.to_s.empty?
          Api::AddressView.new(given.line1.to_s, given.line2.to_s, given.postcode.to_s, given.city.to_s,
            given.country_code.presence || Configuration.company.country_code)
        elsif default = customer.default_delivery_address
          Api::AddressView.new(default.line1, default.line2, default.postcode, default.city, default.country_code)
        end
      end

      def self.store_totals(document : Document, totals : Calculator::Totals) : Nil
        document.lines_total = totals.lines_total
        document.discount_total = totals.discount_total
        document.total_net = totals.total_net
        document.total_vat = totals.total_vat
        document.total_gross = totals.total_gross
      end

      def self.day(date : Time) : Time
        Time.utc(date.year, date.month, date.day)
      end

      # --- Lecture ---------------------------------------------------------------

      def self.line_data(document_id : Int64) : {Array(Line), Array(Calculator::LineData)}
        lines = Line.filter(document_id: document_id).order(:position).to_a
        rates = {} of Int64 => Partiduo::Api::Vat::RateView?
        data = lines.map do |line|
          rate = line.vat_rate_id.try { |rate_id| rates[id_of(rate_id)] ||= Configuration.rate(id_of(rate_id)) }
          Calculator::LineData.new(
            kind: line.kind!, quantity: line.quantity!, unit_price: line.unit_price!,
            discount_kind: line.discount_kind!, discount_value: line.discount_value!,
            vat_rate_id: line.vat_rate_id.try { |rate_id| id_of(rate_id) }, vat_percent: line.vat_percent!,
            vat_category: line.vat_category.to_s, exemption_code: rate.try(&.exemption_code) || "",
            exemption_reason: rate.try(&.exemption_reason) || "",
            item_card_id: line.item_id.try { |item_id| id_of(item_id) },
          )
        end
        {lines, data}
      end

      def self.totals(document : Document) : Calculator::Totals
        _, data = line_data(id_of(document.id))
        Calculator.compute(data, document.global_discount_kind!, document.global_discount_value!)
      end

      def self.link(document : Document) : Api::LinkView
        Api::LinkView.new(id_of(document.id), document.kind!, document.number, document.status!)
      end

      def self.effective_status(document : Document, amount_due : BigDecimal, on : Time = today) : String
        status = document.status!
        if document.kind == "quote" && status == "sent" && (validity = document.validity_date) && validity < on
          "expired"
        elsif document.kind.in?("invoice", "deposit_invoice") && status.in?("issued", "sent", "partially_paid") &&
              (due = document.due_date) && due < on && amount_due > 0
          "overdue"
        else
          status
        end
      end

      def self.seller(document : Document) : Api::PartyView
        if json = document.seller
          Configuration.party_from_json(json)
        else
          Configuration.seller_party
        end
      end

      def self.customer(document : Document) : Api::PartyView
        if json = document.customer_snapshot
          Configuration.party_from_json(json)
        elsif card = Configuration.card(id_of(document.customer_id))
          Configuration.customer_party(card)
        else
          raise Partiduo::Api::NotFound.new("card", document.customer_id)
        end
      end

      def self.deductions(document_id : Int64) : Array(Api::DeductionView)
        DepositDeduction.filter(invoice_id: document_id).order(:id).map do |deduction|
          deposit = find(id_of(deduction.deposit_id))
          Api::DeductionView.new(id_of(deposit.id), deposit.number.to_s, deduction.amount!)
        end
      end

      def self.vat_breakdown(totals : Calculator::Totals) : Array(Api::VatBreakdownView)
        totals.groups.map do |group|
          Api::VatBreakdownView.new(group.category, group.percent, group.exemption_code, group.exemption_reason,
            group.lines_total, group.allowance, group.base, group.vat)
        end
      end

      def self.mentions_context(document : Document, seller : Api::PartyView, customer : Api::PartyView,
                                breakdown : Array(Api::VatBreakdownView), deductions : Array(Api::DeductionView),
                                operation_category : String, due_date : Time?, delivery_date : Time?,
                                issue_date : Time?, structured_reference : String) : Mentions::Context
        credited = document.credited_id.try { |credited_id| find(id_of(credited_id)) }
        Mentions::Context.new(
          kind: document.kind!, regime: Configuration.regime, seller: seller, customer: customer,
          number: document.number, issue_date: issue_date, delivery_date: delivery_date, due_date: due_date,
          validity_date: document.validity_date, operation_category: operation_category,
          vat_on_debits: document.vat_on_debits!, delivery_address: Configuration.address_from_json(document.delivery_address),
          vat_breakdown: breakdown, credited_number: credited.try(&.number), credited_date: credited.try(&.issue_date),
          deductions: deductions, structured_reference: structured_reference, settings: Configuration.settings,
          currency_code: document.currency_code!, payment_terms: document.payment_terms.to_s,
          payment_terms_days: PaymentTerms.days(document),
          billing_period_start: document.billing_period_start, billing_period_end: document.billing_period_end,
          delivery_note_numbers: document.kind.in?("invoice", "credit_note") ? DeliveryBilling.refs(id_of(document.id)).map(&.number) : [] of String,
          return_note_numbers: document.kind.in?("invoice", "credit_note") ? Returns.refs(id_of(document.id)).map(&.number) : [] of String,
          return_reason: document.return_reason.to_s,
        )
      end

      def self.stored_mentions(json : JSON::Any?) : Array(Api::MentionView)?
        return unless json && (array = json.as_a?)
        array.map do |item|
          params = item["params"].as_h.transform_values(&.as_s)
          Api::MentionView.new(item["code"].as_s, item["key"].as_s, params)
        end
      end

      def self.mentions_json(mentions : Array(Api::MentionView)) : JSON::Any
        JSON.parse(mentions.map { |mention| {"code" => mention.code, "key" => mention.key, "params" => mention.params} }.to_json)
      end

      def self.view(document : Document) : Api::DocumentView
        document_id = id_of(document.id)
        lines, data = line_data(document_id)
        totals = Calculator.compute(data, document.global_discount_kind!, document.global_discount_value!)
        seller = seller(document)
        customer = customer(document)
        deductions = deductions(document_id)
        breakdown = vat_breakdown(totals)
        prepaid = document.draft? ? deductions.sum(BigDecimal.new(0), &.amount) : document.prepaid_amount!
        totals_view = Api::TotalsView.new(
          lines_total: totals.lines_total, discount_total: totals.discount_total, total_net: totals.total_net,
          total_vat: totals.total_vat, total_gross: totals.total_gross, prepaid: prepaid,
          paid: document.paid_amount!, credited: document.credited_amount!,
        )
        mentions = stored_mentions(document.mentions) || begin
          context = mentions_context(document, seller, customer, breakdown, deductions,
            document.operation_category.presence || Configuration.settings.default_operation_category,
            document.due_date, document.delivery_date || document.issue_date, document.issue_date, "")
          I18n.with_locale(document.locale!) { Mentions.build(context) }
        end

        line_views = lines.each_with_index.map do |(line, index)|
          result = totals.lines[index]
          Api::LineView.new(
            position: line.position!.to_i32, kind: line.kind!, item_card_id: line.item_id.try { |item_id| id_of(item_id) },
            description: line.description.to_s, quantity: line.quantity!, unit_code: line.unit_code.to_s,
            unit_price: line.unit_price!, discount_kind: line.discount_kind!, discount_value: line.discount_value!,
            discount_amount: result.discount, gross_amount: result.gross,
            vat_rate_id: line.vat_rate_id.try { |rate_id| id_of(rate_id) }, vat_percent: line.vat_percent!,
            vat_category: line.vat_category.to_s, net_amount: result.net,
            delivery_note_id: line.delivery_note_id.try(&.to_i64), return_note_id: line.return_note_id.try(&.to_i64),
          )
        end.to_a

        source = document.source_id.try { |source_id| link(find(id_of(source_id))) }
        credited = document.credited_id.try { |credited_id| link(find(id_of(credited_id))) }
        derived = Document.filter(source_id: document_id).order(:id).map { |child| link(child) }
        credit_notes = Document.filter(credited_id: document_id).order(:id).map { |child| link(child) }

        Api::DocumentView.new(
          id: document_id, kind: document.kind!, status: document.status!,
          effective_status: effective_status(document, totals_view.amount_due), series: document.series!,
          number: document.number, customer_card_id: id_of(document.customer_id), customer: customer, seller: seller,
          source: source, derived: derived, credited: credited, credit_notes: credit_notes, locale: document.locale!,
          currency_code: document.currency_code!, issue_date: document.issue_date,
          delivery_date: document.delivery_date, due_date: document.due_date, validity_date: document.validity_date,
          operation_category: document.operation_category.to_s, vat_on_debits: document.vat_on_debits!,
          buyer_reference: document.buyer_reference.to_s, order_reference: document.order_reference.to_s,
          notes: document.notes.to_s, global_discount_kind: document.global_discount_kind!,
          global_discount_value: document.global_discount_value!,
          delivery_address: Configuration.address_from_json(document.delivery_address),
          structured_reference: document.structured_reference.to_s, lines: line_views, vat_breakdown: breakdown,
          totals: totals_view, deductions: deductions, mentions: mentions,
          layout_id: document.layout_id.try { |layout_id| id_of(layout_id) }, issued_at: document.issued_at,
          issued_by_id: document.issued_by_id.try(&.to_i64), fingerprint: document.fingerprint.to_s,
          pdf_attachment_id: document.pdf_id.try { |pdf_id| id_of(pdf_id) }, sent_at: document.sent_at,
          created_at: document.created_at!, updated_at: document.updated_at!,
          issue_channel: document.issue_channel.to_s, b2c: document.b2c!,
          payment_terms: document.payment_terms.to_s, payment_terms_days: document.payment_terms_days.try(&.to_i32),
          billing_period_start: document.billing_period_start, billing_period_end: document.billing_period_end,
          delivery_notes: document.kind.in?("invoice", "credit_note") ? DeliveryBilling.refs(document_id) : [] of Api::DeliveryNoteRefView,
          billed_in: case document.kind
          when "delivery_note" then DeliveryBilling.billed_in(document_id)
          when "return_note"   then Returns.returned_in(document_id)
          end,
          return_reason: document.return_reason.to_s,
          return_notes: document.kind.in?("invoice", "credit_note") ? Returns.refs(document_id) : [] of Api::DeliveryNoteRefView,
        )
      end

      # --- Transformation --------------------------------------------------------

      def self.transform_input(source : Document, input : Api::TransformInput) : {Api::DocumentInput?, Array(FieldError)}
        document_input, errors = copied_input(source, input)
        if document_input && input.kind == "return_note"
          document_input = return_input(document_input, id_of(source.id))
        end
        {document_input, errors}
      end

      private def self.copied_input(source : Document, input : Api::TransformInput) : {Api::DocumentInput?, Array(FieldError)}
        errors = transform_errors(source, input)
        return {nil, errors} unless errors.empty?
        source_id = id_of(source.id)
        lines, data = line_data(source_id)
        deposit = input.kind == "deposit_invoice"
        line_inputs = if deposit
                        percent = input.deposit_percent
                        if percent.nil? || percent <= 0 || percent > 100 || Calculator.scale(percent) > 2
                          return {nil, [error("deposit_percent", "transform.deposit_percent")]}
                        end
                        deposit_lines(source, data, percent)
                      else
                        copied_lines(source, input, lines)
                      end
        # Adresse de livraison du document d'origine, ou aucune (adresse vide)
        # s'il n'en avait pas : la fiche ne la réimpose pas.
        delivery = Configuration.address_from_json(source.delivery_address).try do |address|
          Partiduo::Api::Cards::AddressInput.new(line1: address.line1, line2: address.line2, postcode: address.postcode,
            city: address.city, country_code: address.country_code)
        end || Partiduo::Api::Cards::AddressInput.new
        document_input = Api::DocumentInput.new(
          kind: input.kind, customer_card_id: id_of(source.customer_id), lines: line_inputs,
          currency_code: source.currency_code, operation_category: source.operation_category.presence,
          delivery_address: delivery, buyer_reference: source.buyer_reference, order_reference: order_reference(source),
          notes: source.notes, global_discount_kind: deposit ? "none" : source.global_discount_kind!,
          global_discount_value: deposit ? BigDecimal.new(0) : source.global_discount_value!,
          locale: source.locale, layout_id: source.layout_id.try { |layout_id| id_of(layout_id) },
          deposit_ids: input.kind == "invoice" ? open_deposits(source) : [] of Int64,
          credited_document_id: input.kind == "credit_note" ? source_id : nil,
          payment_terms: source.payment_terms.presence, payment_terms_days: source.payment_terms_days.try(&.to_i32),
          delivery_date: inherited_delivery_date(source),
        ).copy_with(**Channels.inherited(source, input.kind))
        {document_input, errors}
      end

      # Bon de retour tiré d'un bon de livraison ou d'une facture
      # (D-INV3-001) : reliquat de l'origine (ce qui n'est pas déjà
      # rapporté), sans conditions de paiement ; la date du retour est celle
      # de son émission, à défaut d'être saisie.
      private def self.return_input(input : Api::DocumentInput, source_id : Int64) : Api::DocumentInput
        input.copy_with(lines: Returns.remaining_lines(source_id, input.lines), payment_terms: nil,
          payment_terms_days: nil, delivery_date: nil)
      end

      # Lignes recopiées ; celles de la facture d'un bon de livraison citent
      # le bon (D-INV2-002).
      private def self.copied_lines(source : Document, input : Api::TransformInput, lines : Array(Line)) : Array(Api::LineInput)
        note_id = source.kind == "delivery_note" && input.kind == "invoice" ? id_of(source.id) : nil
        lines.map { |line| line_input(line, note_id) }
      end

      # Facture d'un bon de livraison : date de livraison du bon (BT-72).
      private def self.inherited_delivery_date(source : Document) : Time?
        source.kind == "delivery_note" ? (source.delivery_date || source.issue_date) : nil
      end

      private def self.transform_errors(source : Document, input : Api::TransformInput) : Array(FieldError)
        allowed = Api::TRANSFORMATIONS[source.kind!]? || [] of String
        if source.draft?
          [error(FieldError::BASE, "transform.source_draft")]
        elsif !allowed.includes?(input.kind)
          [error("kind", "transform.not_allowed", {"from" => source.kind!, "to" => input.kind})]
        elsif (status = effective_status(source, BigDecimal.new(0))).in?("refused", "expired", "cancelled")
          [error(FieldError::BASE, "transform.source_status", {"status" => status})]
        elsif source.kind == "delivery_note" && input.kind == "invoice" &&
              (code = DeliveryBilling.note_error(id_of(source.id), id_of(source.customer_id), source.currency_code!, nil)[0])
          [error(FieldError::BASE, "document.delivery_notes.#{code}", {"number" => source.number.to_s})]
        else
          [] of FieldError
        end
      end

      # Ligne recopiée telle quelle (désignation, prix, taux figés) ;
      # `delivery_note_id` : bon de livraison que la ligne d'une facture cite.
      # Les citations de la ligne d'origine ne sont pas recopiées.
      def self.line_input(line : Line, delivery_note_id : Int64? = nil) : Api::LineInput
        Api::LineInput.new(
          kind: line.kind!, item_card_id: line.item_id.try { |item_id| id_of(item_id) },
          description: line.description.to_s, quantity: line.quantity!, unit_code: line.unit_code.presence,
          unit_price: line.kind.in?("item", "free") ? line.unit_price! : nil, discount_kind: line.discount_kind!,
          discount_value: line.discount_value!, vat_rate_id: line.vat_rate_id.try { |rate_id| id_of(rate_id) },
          delivery_note_id: delivery_note_id,
        )
      end

      # Référence de commande reprise : celle du document source, sinon le
      # numéro de la commande transformée.
      private def self.order_reference(source : Document) : String
        reference = source.order_reference.to_s
        return reference unless reference.empty?
        source.kind == "order" ? source.number.to_s : ""
      end

      # Une ligne par groupe de TVA du document source : pourcentage de sa
      # base, arrondi au centime, au premier taux du socle du groupe.
      private def self.deposit_lines(source : Document, data : Array(Calculator::LineData),
                                     percent : BigDecimal) : Array(Api::LineInput)
        totals = Calculator.compute(data, source.global_discount_kind!, source.global_discount_value!)
        totals.groups.compact_map do |group|
          index = data.index { |line| line.priced? && {line.vat_category, Calculator.plain(line.vat_percent), line.exemption_code} == group.key }
          next unless index
          amount = Calculator.round(group.base * percent / 100)
          next if amount.zero?
          description = I18n.with_locale(source.locale!) do
            I18n.t("invoicing.deposit.line", {"percent" => Calculator.plain(percent), "number" => source.number.to_s})
          end
          Api::LineInput.new(kind: "free", description: description, quantity: BigDecimal.new(1), unit_code: "C62",
            unit_price: amount, vat_rate_id: data[index].vat_rate_id)
        end
      end

      # Factures d'acompte émises depuis la chaîne du document (lui-même et ses
      # ascendants), pas encore déduites, ni annulées ni créditées.
      def self.open_deposits(source : Document) : Array(Int64)
        chain = [] of Int64
        current = source
        while current
          chain << id_of(current.id)
          current = current.source_id.try { |parent| find(id_of(parent)) }
        end
        Document.filter(kind: "deposit_invoice", source_id__in: chain).exclude(number: nil).order(:id).compact_map do |deposit|
          deposit_id = id_of(deposit.id)
          next if deposit.status == "cancelled" || deposit.credited_amount! > 0
          next if DepositDeduction.filter(deposit_id: deposit_id).exists?
          deposit_id
        end
      end

      # Journal des opérations (ajout seul, déclencheur en base).
      def self.log(document_id : Int64, action : String, actor : Partiduo::Api::Actor, fingerprint : String = "",
                   details : Hash(String, String) = {} of String => String) : Nil
        DocumentEvent.create!(document_id: document_id, action: action, user_id: actor.user_id,
          fingerprint: fingerprint, details: JSON.parse(details.to_json), created_at: Time.utc)
      end
    end
  end
end
