# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Invoicing
    # Retours de marchandises (DECISIONS D-INV3-001 à D-INV3-006) : bon de
    # retour (`return_note`), symétrique du bon de livraison — marchandise
    # rapportée par le client, avec ou sans document d'origine (bon de
    # livraison ou facture, `source_id`), quantités au plus égales à celles
    # de l'origine.
    #
    # Un bon de retour émis et non repris :
    #
    # * vient en déduction de l'encours HT du client et de ce qui reste à
    #   facturer (« Bons à facturer ») ;
    # * se déduit d'une facture (groupe « Bon de retour BR-… du … », lignes
    #   en quantités négatives, sous-total), seul ou dans la facture
    #   récapitulative du mois ; si les retours l'emportent sur les
    #   livraisons, la pièce est un *avoir récapitulatif* (jamais de facture
    #   de montant négatif) ;
    # * ou se transforme en avoir (un ou plusieurs bons d'un même client).
    #
    # Le lien bon ↔ document est tenu par `BilledReturn` (un bon n'est repris
    # qu'une fois) ; le bon passe à l'état `invoiced` (« repris ») à
    # l'émission du document qui le reprend. Le stock n'est mouvementé qu'à
    # l'émission du bon (`return_note.issued`), jamais par le document qui le
    # reprend (D-INV3-005).
    module Returns
      alias Api = Partiduo::Api::Invoicing
      alias FieldError = Partiduo::Api::FieldError

      ZERO = BigDecimal.new(0)

      def self.error(field : String, key : String, params = {} of String => String) : FieldError
        Documents.error(field, key, params)
      end

      def self.id_of(value) : Int64
        Documents.id_of(value)
      end

      # Date du retour (celle du bon, sinon son émission).
      def self.returned_on(note : Document) : Time
        note.delivery_date || note.issue_date || Documents.today
      end

      # --- Saisie d'un bon de retour ------------------------------------------------------

      # Motif (bon de retour seulement), quantités positives, et, si le bon a
      # une origine, quantités au plus égales à celles livrées ou facturées.
      def self.input_errors(input : Api::DocumentInput, current : Document?, source_id : Int64?) : Array(FieldError)
        errors = [] of FieldError
        reason = input.return_reason.presence
        if input.kind != "return_note"
          errors << error("return_reason", "document.return_reason.return_note_only") if reason
          return errors
        end
        if reason && !Api::RETURN_REASONS.includes?(reason)
          errors << error("return_reason", "document.return_reason.invalid")
        end
        input.lines.each_with_index do |line, index|
          if line.kind.in?("item", "free") && line.quantity < 0
            errors << error("lines[#{index}].quantity", "return_note.quantity_negative")
          end
        end
        origin_id = source_id || current.try(&.source_id).try { |value| id_of(value) }
        if origin_id && errors.empty?
          current_lines = input.lines.map { |line| {line.kind, line.item_card_id, line.description.to_s.strip, line.quantity} }
          errors.concat(origin_errors(origin_id, current_lines, current.try { |document| id_of(document.id) }))
        end
        errors
      end

      # Clé de rapprochement d'une ligne avec celles de l'origine : l'article,
      # sinon la désignation d'une ligne libre.
      private def self.key_of(kind : String, item_card_id : Int64?, description : String) : String?
        return unless kind.in?("item", "free")
        item_card_id ? "item:#{item_card_id}" : "free:#{description.strip.downcase}"
      end

      # Quantités de l'origine par clé (lignes chiffrées).
      private def self.origin_quantities(origin_id : Int64) : Hash(String, {BigDecimal, String})
        quantities = {} of String => {BigDecimal, String}
        Line.filter(document_id: origin_id).order(:position).each do |line|
          key = key_of(line.kind!, line.item_id.try { |value| id_of(value) }, line.description.to_s) || next
          quantity, description = quantities[key]? || {ZERO, line.description.to_s.lines.first? || ""}
          quantities[key] = {quantity + line.quantity!, description}
        end
        quantities
      end

      # Quantités déjà rapportées par les autres bons de retour émis de la
      # même origine.
      private def self.returned_quantities(origin_id : Int64, exclude_id : Int64?) : Hash(String, BigDecimal)
        returned = {} of String => BigDecimal
        notes = Document.filter(kind: "return_note", source_id: origin_id).exclude(number: nil).to_a
        notes.each do |note|
          next if exclude_id && id_of(note.id) == exclude_id
          Line.filter(document_id: note.id).each do |line|
            key = key_of(line.kind!, line.item_id.try { |value| id_of(value) }, line.description.to_s) || next
            returned[key] = returned.fetch(key, ZERO) + line.quantity!
          end
        end
        returned
      end

      # Lignes d'un bon de retour tiré de l'origine : quantités diminuées de
      # ce que les bons de retour émis de la même origine ont déjà rapporté ;
      # une ligne entièrement rapportée disparaît (D-INV3-001).
      def self.remaining_lines(origin_id : Int64, lines : Array(Api::LineInput)) : Array(Api::LineInput)
        returned = returned_quantities(origin_id, nil)
        lines.compact_map do |line|
          key = key_of(line.kind, line.item_card_id, line.description.to_s) || next line
          already = returned[key]? || next line
          take = Math.min(already, line.quantity)
          returned[key] = already - take
          left = line.quantity - take
          line.copy_with(quantity: left) if left > 0
        end
      end

      # Lignes rapportées au-delà de ce que l'origine a livré ou facturé
      # (retours déjà émis de la même origine compris).
      def self.origin_errors(origin_id : Int64, lines : Array({String, Int64?, String, BigDecimal}),
                             exclude_id : Int64?) : Array(FieldError)
        origin = Document.filter(id: origin_id).first
        return [error("source", "document.return_note.origin_invalid")] if origin.nil? || origin.draft?
        delivered = origin_quantities(origin_id)
        returned = returned_quantities(origin_id, exclude_id)
        wanted = {} of String => {BigDecimal, Int32, String}
        lines.each_with_index do |(kind, item_card_id, description, quantity), index|
          key = key_of(kind, item_card_id, description) || next
          total, first, text = wanted[key]? || {ZERO, index, description.lines.first? || ""}
          wanted[key] = {total + quantity, first, text}
        end
        errors = [] of FieldError
        wanted.each do |key, (quantity, index, text)|
          available, label = delivered[key]? || {ZERO, text}
          already = returned.fetch(key, ZERO)
          next if quantity + already <= available
          errors << error("lines[#{index}].quantity", "return_note.exceeds_origin", {
            "description" => label, "origin" => origin.number.to_s,
            "delivered" => Calculator.plain(available), "returned" => Calculator.plain(already),
          })
        end
        errors
      end

      # Contrôles de l'émission d'un bon de retour : motif obligatoire,
      # quantités au regard de l'origine relues au moment de l'émission.
      def self.issue_errors(document : Document) : Array(FieldError)
        errors = [] of FieldError
        errors << error("return_reason", "issue.return_reason_required") if document.return_reason.to_s.empty?
        if origin_id = document.source_id.try { |value| id_of(value) }
          Documents.find(origin_id, lock: true)
          lines = Line.filter(document_id: document.id).order(:position).to_a.map do |line|
            {line.kind!, line.item_id.try { |value| id_of(value) }, line.description.to_s, line.quantity!}
          end
          errors.concat(origin_errors(origin_id, lines, id_of(document.id)))
        end
        errors
      end

      # --- Lignes d'une facture ou d'un avoir qui citent un bon de retour -----------------

      # Bons cités par les lignes (`LineInput#return_note_id`) : facture ou
      # avoir seulement ; bons émis, du même client, de la même devise, non
      # repris par un autre document.
      def self.line_errors(input : Api::DocumentInput, current : Document?) : Array(FieldError)
        errors = [] of FieldError
        cited = {} of Int64 => Int32
        input.lines.each_with_index do |line, index|
          line.return_note_id.try { |note_id| cited[note_id] ||= index }
        end
        return errors if cited.empty?
        unless input.kind.in?("invoice", "credit_note")
          errors << error("lines", "document.return_notes.invoice_or_credit_only")
          return errors
        end
        currency = input.currency_code || current.try(&.currency_code) || Configuration.base_currency
        cited.each do |note_id, index|
          code, params = note_error(note_id, input.customer_card_id, currency, current)
          errors << error("lines[#{index}].return_note_id", "document.return_notes.#{code}", params) if code
        end
        errors
      end

      # Motif du refus d'un bon de retour à reprendre, ou `{nil, _}`.
      def self.note_error(note_id : Int64, customer_id : Int64, currency : String,
                          current : Document?) : {String?, Hash(String, String)}
        note = Document.filter(id: note_id).first
        return {"invalid", {} of String => String} if note.nil? || note.kind != "return_note" || note.draft?
        params = {"number" => note.number.to_s}
        return {"other_customer", params} if id_of(note.customer_id) != customer_id
        return {"other_currency", params} if note.currency_code != currency
        return {"already_settled", params} unless note.status == "issued"
        holder = BilledReturn.filter(return_note_id: note_id).first
        if holder && (current.nil? || id_of(holder.document_id) != id_of(current.id))
          document = Document.filter(id: holder.document_id).first
          return {"already_settled", params} unless document.nil? || document.draft?
          return {"in_draft", params}
        end
        {nil, params}
      end

      # Bons de retour repris par le brouillon `document` (ceux que citent ses
      # lignes) : le lien est recalculé ; renvoie les bons repris.
      def self.sync!(document : Document) : Array(Document)
        document_id = id_of(document.id)
        wanted = Line.filter(document_id: document_id).exclude(return_note_id: nil).to_a
          .compact_map(&.return_note_id.try(&.to_i64)).to_set
        wanted.clear unless document.kind.in?("invoice", "credit_note")
        existing = BilledReturn.filter(document_id: document_id).to_a
        existing.each do |row|
          row.delete unless wanted.includes?(id_of(row.return_note_id))
        end
        kept = existing.map { |row| id_of(row.return_note_id) }.to_set
        wanted.each do |note_id|
          BilledReturn.create!(document_id: document_id, return_note_id: note_id) unless kept.includes?(note_id)
        end
        wanted.empty? ? [] of Document : Document.filter(id__in: wanted.to_a).to_a
      end

      # Bons de retour repris par un document, du premier rapporté au dernier.
      def self.refs(document_id : Int64) : Array(Api::DeliveryNoteRefView)
        ids = BilledReturn.filter(document_id: document_id).to_a.map { |row| id_of(row.return_note_id) }
        return [] of Api::DeliveryNoteRefView if ids.empty?
        Document.filter(id__in: ids).to_a.sort_by { |note| {returned_on(note), note.number.to_s} }.map do |note|
          Api::DeliveryNoteRefView.new(id_of(note.id), note.number.to_s, note.issue_date, returned_on(note),
            note.total_net!, note.total_gross!)
        end
      end

      # Document (brouillon ou émis) qui reprend un bon de retour.
      def self.returned_in(note_id : Int64) : Api::LinkView?
        BilledReturn.filter(return_note_id: note_id).first.try do |row|
          Document.filter(id: row.document_id).first.try { |document| Documents.link(document) }
        end
      end

      # Émission du document qui les reprend : ses bons de retour passent à
      # l'état « repris » (tracé dans leur journal).
      def self.mark_settled!(document : Document, actor : Partiduo::Api::Actor) : Nil
        BilledReturn.filter(document_id: document.id).to_a.each do |row|
          note = Documents.find(id_of(row.return_note_id), lock: true)
          next unless note.status == "issued"
          note.status = "invoiced"
          note.save!
          Documents.log(id_of(note.id), "invoiced", actor, "", {"invoice" => document.number.to_s, "kind" => document.kind!})
        end
      end

      # --- Sélection de bons (livraisons et retours) -----------------------------------------

      # Contrôle d'une sélection mêlant bons de livraison et bons de retour :
      # au moins un, sans doublon ; bons émis, libres, d'un même client et
      # d'une même devise.
      def self.selection_errors(notes : Array(Document?), ids : Array(Int64)) : Array(FieldError)
        return [error("delivery_note_ids", "delivery_notes.empty")] if ids.empty?
        return [error("delivery_note_ids", "delivery_notes.duplicate")] if ids.uniq.size != ids.size
        found = notes.compact
        if found.size != ids.size || found.any? { |note| !note.kind.in?("delivery_note", "return_note") || note.draft? }
          return [error("delivery_note_ids", "document.delivery_notes.invalid")]
        end
        errors = [] of FieldError
        errors << error("delivery_note_ids", "delivery_notes.several_customers") if found.map(&.customer_id).uniq!.size > 1
        errors << error("delivery_note_ids", "delivery_notes.several_currencies") if found.map(&.currency_code).uniq!.size > 1
        return errors unless errors.empty?
        customer_id = id_of(found.first.customer_id)
        found.each do |note|
          if note.kind == "return_note"
            code, params = note_error(id_of(note.id), customer_id, note.currency_code!, nil)
            errors << error("delivery_note_ids", "document.return_notes.#{code}", params) if code
          else
            code, params = DeliveryBilling.note_error(id_of(note.id), customer_id, note.currency_code!, nil)
            errors << error("delivery_note_ids", "document.delivery_notes.#{code}", params) if code
          end
        end
        errors
      end

      # Groupe de lignes d'un bon : titre (« Bon de livraison BL-… du … »,
      # « Bon de retour BR-… du … »), ses lignes — quantités multipliées par
      # `sign` — qui le citent, sous-total s'il n'a pas ses propres titres.
      def self.group_lines(note : Document, sign : Int32, locale : String, titled : Bool = true) : Array(Api::LineInput)
        note_id = id_of(note.id)
        returned = note.kind == "return_note"
        cite = ->(line : Api::LineInput) do
          returned ? line.copy_with(return_note_id: note_id) : line.copy_with(delivery_note_id: note_id)
        end
        lines = [] of Api::LineInput
        date = returned ? returned_on(note) : DeliveryBilling.delivered_on(note)
        if titled
          title = I18n.with_locale(locale) do
            I18n.t("invoicing.#{returned ? "return_notes" : "delivery_notes"}.group_title",
              {"number" => note.number.to_s, "date" => Output.format_date(date, locale)})
          end
          lines << cite.call(Api::LineInput.new(kind: "title", description: title))
        end
        note_lines = Line.filter(document_id: note_id).order(:position).to_a
        note_lines.each do |line|
          input = Documents.line_input(line)
          input = input.copy_with(quantity: input.quantity * sign) if line.kind.in?("item", "free")
          lines << cite.call(input)
        end
        if titled && !note_lines.any?(&.kind.in?("title", "subtotal"))
          lines << cite.call(Api::LineInput.new(kind: "subtotal"))
        end
        lines
      end

      # Facture ou avoir de bons de livraison et de retour d'un même client
      # (facture récapitulative, D-INV3-003 et D-INV3-004) : chaque bon, du
      # premier livré ou rapporté au dernier, en un groupe de lignes.
      #
      # * livraisons > retours (TTC) : *facture*, retours en quantités
      #   négatives, acomptes ouverts des chaînes des bons de livraison
      #   déduits ;
      # * sinon : *avoir récapitulatif*, retours en quantités positives,
      #   livraisons en quantités négatives, sur la facture que désigne
      #   `credited_invoice` (refus `return_notes.no_invoice_to_credit` s'il
      #   n'y en a pas).
      #
      # Sans bon de retour : `DeliveryBilling.group_input`.
      def self.summary_input(notes : Array(Document)) : {Api::DocumentInput?, Array(FieldError)}
        returns = notes.select(&.kind.==("return_note"))
        return {DeliveryBilling.group_input(notes), [] of FieldError} if returns.empty?
        deliveries = notes - returns
        net = deliveries.sum(ZERO, &.total_gross!) - returns.sum(ZERO, &.total_gross!)
        ordered = notes.sort_by do |note|
          {note.kind == "return_note" ? returned_on(note) : DeliveryBilling.delivered_on(note), note.number.to_s}
        end
        first = ordered.first
        locale = first.locale!
        credit = net <= 0
        lines = [] of Api::LineInput
        ordered.each do |note|
          sign = (note.kind == "return_note") == credit ? 1 : -1
          lines.concat(group_lines(note, sign, locale, titled: ordered.size > 1))
        end
        categories = ordered.map(&.operation_category.to_s).reject(&.empty?).uniq!
        input = Api::DocumentInput.new(
          kind: credit ? "credit_note" : "invoice", customer_card_id: id_of(first.customer_id), lines: lines,
          currency_code: first.currency_code,
          operation_category: categories.size == 1 ? categories.first : (categories.empty? ? nil : "mixed"),
          delivery_address: address_input(first), buyer_reference: first.buyer_reference.presence, locale: locale,
          layout_id: first.layout_id.try { |layout_id| id_of(layout_id) },
          deposit_ids: credit ? [] of Int64 : deliveries.flat_map { |note| Documents.open_deposits(note) }.uniq!,
        )
        if credit
          credited = credited_invoice(returns, id_of(first.customer_id), first.currency_code!, -net)
          return {nil, [error("delivery_note_ids", "return_notes.no_invoice_to_credit")]} unless credited
          input = input.copy_with(credited_document_id: id_of(credited.id)).copy_with(**Channels.inherited(credited, "credit_note"))
        else
          input = input.copy_with(**Channels.inherited(first, "invoice"))
        end
        {input, [] of FieldError}
      end

      # Avoir d'un ou de plusieurs bons de retour d'un même client (hors
      # facturation mensuelle, D-INV3-005) : un bon, ses lignes ; plusieurs,
      # un groupe par bon. La facture créditée est `credited_id` s'il est
      # donné, sinon celle que désigne `credited_invoice`.
      def self.credit_input(notes : Array(Document), credited_id : Int64?) : {Api::DocumentInput?, Array(FieldError)}
        ordered = notes.sort_by { |note| {returned_on(note), note.number.to_s} }
        first = ordered.first
        locale = first.locale!
        total = ordered.sum(ZERO, &.total_gross!)
        credited = if credited_id
                     Document.filter(id: credited_id).first
                   else
                     credited_invoice(ordered, id_of(first.customer_id), first.currency_code!, total)
                   end
        return {nil, [error("credited_document_id", "return_notes.no_invoice_to_credit")]} unless credited
        lines = ordered.flat_map { |note| group_lines(note, 1, locale, titled: ordered.size > 1) }
        categories = ordered.map(&.operation_category.to_s).reject(&.empty?).uniq!
        input = Api::DocumentInput.new(
          kind: "credit_note", customer_card_id: id_of(first.customer_id), lines: lines,
          currency_code: first.currency_code,
          operation_category: categories.size == 1 ? categories.first : (categories.empty? ? nil : "mixed"),
          delivery_address: address_input(first), buyer_reference: first.buyer_reference.presence, locale: locale,
          layout_id: first.layout_id.try { |layout_id| id_of(layout_id) }, credited_document_id: id_of(credited.id),
          delivery_date: ordered.size == 1 ? returned_on(first) : nil,
        ).copy_with(**Channels.inherited(credited, "credit_note"))
        {input, [] of FieldError}
      end

      private def self.address_input(note : Document) : Partiduo::Api::Cards::AddressInput
        Configuration.address_from_json(note.delivery_address).try do |address|
          Partiduo::Api::Cards::AddressInput.new(line1: address.line1, line2: address.line2,
            postcode: address.postcode, city: address.city, country_code: address.country_code)
        end || Partiduo::Api::Cards::AddressInput.new
      end

      # Facture à créditer pour des retours de `amount` TTC : la plus récente
      # des factures d'origine des bons (la facture citée, ou celle qui a
      # facturé le bon de livraison cité) qui peut encore être créditée de ce
      # montant, sinon la plus récente facture émise du client, dans la même
      # devise, qui le peut ; `nil` s'il n'y en a pas.
      def self.credited_invoice(notes : Array(Document), customer_id : Int64, currency : String,
                                amount : BigDecimal) : Document?
        creditable = ->(invoice : Document) do
          invoice.kind == "invoice" && !invoice.draft? && invoice.status != "cancelled" &&
          id_of(invoice.customer_id) == customer_id && invoice.currency_code == currency &&
          invoice.total_gross! - invoice.credited_amount! >= amount
        end
        origins = notes.compact_map { |note| origin_invoice(note) }.uniq!(&.id)
        origins.sort_by { |invoice| {invoice.issue_date || Documents.today, id_of(invoice.id)} }.reverse!
        origins.find(&creditable) ||
          Document.filter(kind: "invoice", customer_id: customer_id, currency_code: currency).exclude(number: nil)
            .exclude(status: "cancelled").order("-issue_date", "-id").to_a.find(&creditable)
      end

      # Facture d'origine d'un bon de retour : la facture citée, ou la
      # facture émise qui a repris le bon de livraison cité.
      def self.origin_invoice(note : Document) : Document?
        source = note.source_id.try { |value| Document.filter(id: value).first } || return
        case source.kind
        when "invoice"
          source unless source.draft?
        when "delivery_note"
          BilledDelivery.filter(delivery_note_id: source.id).first.try do |row|
            Document.filter(id: row.invoice_id).exclude(number: nil).first
          end
        end
      end

      # --- Bons à reprendre ------------------------------------------------------------------

      # Bons de retour émis et non repris (« Bons à facturer »), montants
      # négatifs : ils réduisent ce qui reste à facturer.
      def self.to_invoice(query : Api::ToInvoiceQuery) : Array(Api::ToInvoiceView)
        records = Document.filter(kind: "return_note", status: "issued")
        records = records.filter(customer_id: query.customer_card_id) if query.customer_card_id
        records = records.filter(delivery_date__gte: query.from) if query.from
        records = records.filter(delivery_date__lte: query.to) if query.to
        notes = records.order(:delivery_date, :number)[0...query.limit.clamp(1, 2000)].to_a
        return [] of Api::ToInvoiceView if notes.empty?
        ids = notes.map { |note| id_of(note.id) }
        drafts = BilledReturn.filter(return_note_id__in: ids).to_a.to_h do |row|
          {id_of(row.return_note_id), id_of(row.document_id)}
        end
        rhythms = CreditControl.rhythms(notes.map { |note| id_of(note.customer_id) }.uniq!)
        notes.map do |note|
          customer_id = id_of(note.customer_id)
          Api::ToInvoiceView.new(
            id: id_of(note.id), number: note.number.to_s, customer_card_id: customer_id,
            customer_name: Documents.customer(note).name, issue_date: note.issue_date || Documents.today,
            delivery_date: returned_on(note), currency_code: note.currency_code!, total_net: -note.total_net!,
            total_gross: -note.total_gross!, draft_invoice_id: drafts[id_of(note.id)]?,
            billing_rhythm: rhythms[customer_id]? || "per_delivery", kind: "return_note",
            origin: note.source_id.try { |value| Document.filter(id: value).first.try { |doc| Documents.link(doc) } },
          )
        end
      end
    end
  end
end
