# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Invoicing
    # Facturation des bons de livraison (DECISIONS D-INV2-001 à D-INV2-004) :
    # bons émis et non facturés, facture d'un ou de plusieurs bons (facture
    # récapitulative, art. 289-I-3 du CGI), lien bon ↔ facture tenu par
    # `BilledDelivery`, état `invoiced` à l'émission de la facture. Appelé
    # par `Partiduo::Api::Invoicing` et par les brouillons (`Documents`).
    module DeliveryBilling
      alias Api = Partiduo::Api::Invoicing
      alias FieldError = Partiduo::Api::FieldError

      def self.error(field : String, key : String, params = {} of String => String) : FieldError
        Documents.error(field, key, params)
      end

      def self.id_of(value) : Int64
        Documents.id_of(value)
      end

      # Date de livraison d'un bon émis (celle du bon, sinon son émission).
      def self.delivered_on(note : Document) : Time
        note.delivery_date || note.issue_date || Documents.today
      end

      # --- Contrôle des lignes d'une facture ------------------------------------------

      # Bons cités par les lignes (`LineInput#delivery_note_id`) : facture,
      # ou avoir récapitulatif (D-INV3-004) ; bons émis, du même client, de
      # la même devise, ni facturés ni repris par un autre document.
      def self.line_errors(input : Api::DocumentInput, current : Document?) : Array(FieldError)
        errors = [] of FieldError
        cited = {} of Int64 => Int32
        input.lines.each_with_index do |line, index|
          line.delivery_note_id.try { |note_id| cited[note_id] ||= index }
        end
        return errors if cited.empty?
        unless input.kind.in?("invoice", "credit_note")
          errors << error("lines", "document.delivery_notes.invoice_only")
          return errors
        end
        currency = input.currency_code || current.try(&.currency_code) || Configuration.base_currency
        cited.each do |note_id, index|
          code, params = note_error(note_id, input.customer_card_id, currency, current)
          errors << error("lines[#{index}].delivery_note_id", "document.delivery_notes.#{code}", params) if code
        end
        errors
      end

      # Motif du refus d'un bon à facturer, ou `{nil, _}`.
      def self.note_error(note_id : Int64, customer_id : Int64, currency : String,
                          current : Document?) : {String?, Hash(String, String)}
        note = Document.filter(id: note_id).first
        return {"invalid", {} of String => String} if note.nil? || note.kind != "delivery_note" || note.draft?
        params = {"number" => note.number.to_s}
        return {"other_customer", params} if id_of(note.customer_id) != customer_id
        return {"other_currency", params} if note.currency_code != currency
        return {"already_billed", params} unless note.status == "issued"
        holder = BilledDelivery.filter(delivery_note_id: note_id).first
        if holder && (current.nil? || id_of(holder.invoice_id) != id_of(current.id))
          invoice = Document.filter(id: holder.invoice_id).first
          return {"already_billed", params} unless invoice.nil? || invoice.draft?
          return {"in_draft", params}
        end
        {nil, params}
      end

      # --- Lien bon ↔ facture ------------------------------------------------------------

      # Bons facturés par le brouillon `document` : ceux cités par ses lignes
      # et son document source s'il est un bon de livraison ; bons de retour
      # repris (`Returns.sync!`). Le lien est recalculé (un groupe de lignes
      # retiré libère son bon) ; la période de facturation (BG-14) d'une
      # facture ou d'un avoir qui regroupe plusieurs livraisons ou retours va
      # du premier au dernier, qui devient sa date de livraison.
      def self.sync!(document : Document) : Nil
        document_id = id_of(document.id)
        wanted = Line.filter(document_id: document_id).exclude(delivery_note_id: nil).to_a
          .compact_map(&.delivery_note_id.try(&.to_i64)).to_set
        if document.kind == "invoice" && (source_id = document.source_id)
          source = Document.filter(id: source_id).first
          wanted << id_of(source_id) if source && source.kind == "delivery_note"
        end
        wanted.clear unless document.kind.in?("invoice", "credit_note")
        existing = BilledDelivery.filter(invoice_id: document_id).to_a
        existing.each do |row|
          row.delete unless wanted.includes?(id_of(row.delivery_note_id))
        end
        kept = existing.map { |row| id_of(row.delivery_note_id) }.to_set
        wanted.each do |note_id|
          BilledDelivery.create!(invoice_id: document_id, delivery_note_id: note_id) unless kept.includes?(note_id)
        end
        notes = wanted.empty? ? [] of Document : Document.filter(id__in: wanted.to_a).to_a
        returns = Returns.sync!(document)
        if notes.size + returns.size >= 2
          dates = notes.map { |note| delivered_on(note) } + returns.map { |note| Returns.returned_on(note) }
          document.billing_period_start = dates.min
          document.billing_period_end = dates.max
          document.delivery_date = dates.max
        else
          document.billing_period_start = nil
          document.billing_period_end = nil
        end
        document.save!
      end

      # Bons facturés par une facture, du premier livré au dernier.
      def self.refs(document_id : Int64) : Array(Api::DeliveryNoteRefView)
        ids = BilledDelivery.filter(invoice_id: document_id).to_a.map { |row| id_of(row.delivery_note_id) }
        return [] of Api::DeliveryNoteRefView if ids.empty?
        Document.filter(id__in: ids).to_a.sort_by { |note| {delivered_on(note), note.number.to_s} }.map do |note|
          Api::DeliveryNoteRefView.new(id_of(note.id), note.number.to_s, note.issue_date, delivered_on(note),
            note.total_net!, note.total_gross!)
        end
      end

      # Facture (brouillon ou émise) qui reprend un bon de livraison.
      def self.billed_in(note_id : Int64) : Api::LinkView?
        BilledDelivery.filter(delivery_note_id: note_id).first.try do |row|
          Document.filter(id: row.invoice_id).first.try { |invoice| Documents.link(invoice) }
        end
      end

      # Émission de la facture : ses bons passent à l'état « facturé » (tracé
      # dans leur journal).
      def self.mark_invoiced!(invoice : Document, actor : Partiduo::Api::Actor) : Nil
        BilledDelivery.filter(invoice_id: invoice.id).to_a.each do |row|
          note = Documents.find(id_of(row.delivery_note_id), lock: true)
          next unless note.status == "issued"
          note.status = "invoiced"
          note.save!
          Documents.log(id_of(note.id), "invoiced", actor, "", {"invoice" => invoice.number.to_s})
        end
      end

      # --- Facture de plusieurs bons -------------------------------------------------------

      # Contrôle d'une sélection de bons : au moins un, sans doublon ; bons
      # émis non facturés, libres, d'un même client et d'une même devise.
      def self.selection_errors(notes : Array(Document?), ids : Array(Int64)) : Array(FieldError)
        return [error("delivery_note_ids", "delivery_notes.empty")] if ids.empty?
        return [error("delivery_note_ids", "delivery_notes.duplicate")] if ids.uniq.size != ids.size
        errors = [] of FieldError
        found = notes.compact
        if found.size != ids.size || found.any? { |note| note.kind != "delivery_note" || note.draft? }
          return [error("delivery_note_ids", "document.delivery_notes.invalid")]
        end
        if found.map(&.customer_id).uniq!.size > 1
          errors << error("delivery_note_ids", "delivery_notes.several_customers")
        end
        if found.map(&.currency_code).uniq!.size > 1
          errors << error("delivery_note_ids", "delivery_notes.several_currencies")
        end
        return errors unless errors.empty?
        customer_id = id_of(found.first.customer_id)
        found.each do |note|
          code, params = note_error(id_of(note.id), customer_id, note.currency_code!, nil)
          errors << error("delivery_note_ids", "document.delivery_notes.#{code}", params) if code
        end
        errors
      end

      # Saisie de la facture d'un ou de plusieurs bons. Un seul bon : la
      # transformation habituelle (document source, lignes recopiées). Plusieurs
      # : facture récapitulative — pour chaque bon, du premier livré au
      # dernier, un titre « Bon de livraison BL-… du … », ses lignes (qui le
      # citent), un sous-total s'il n'a pas ses propres titres ; client,
      # devise, langue, catégorie d'opération et adresse de livraison du
      # premier ; acomptes ouverts de leurs chaînes déduits.
      def self.group_input(notes : Array(Document)) : Api::DocumentInput
        ordered = notes.sort_by { |note| {delivered_on(note), note.number.to_s} }
        first = ordered.first
        locale = first.locale!
        lines = [] of Api::LineInput
        deposits = [] of Int64
        categories = ordered.map(&.operation_category.to_s).reject(&.empty?).uniq!
        ordered.each do |note|
          note_id = id_of(note.id)
          title = I18n.with_locale(locale) do
            I18n.t("invoicing.delivery_notes.group_title",
              {"number" => note.number.to_s, "date" => Output.format_date(delivered_on(note), locale)})
          end
          lines << Api::LineInput.new(kind: "title", description: title, delivery_note_id: note_id)
          note_lines = Line.filter(document_id: note_id).order(:position).to_a
          note_lines.each { |line| lines << Documents.line_input(line, note_id) }
          unless note_lines.any?(&.kind.in?("title", "subtotal"))
            lines << Api::LineInput.new(kind: "subtotal", delivery_note_id: note_id)
          end
          deposits.concat(Documents.open_deposits(note))
        end
        delivery = Configuration.address_from_json(first.delivery_address).try do |address|
          Partiduo::Api::Cards::AddressInput.new(line1: address.line1, line2: address.line2,
            postcode: address.postcode, city: address.city, country_code: address.country_code)
        end || Partiduo::Api::Cards::AddressInput.new
        Api::DocumentInput.new(
          kind: "invoice", customer_card_id: id_of(first.customer_id), lines: lines,
          currency_code: first.currency_code, operation_category: categories.size == 1 ? categories.first : (categories.empty? ? nil : "mixed"),
          delivery_address: delivery, buyer_reference: first.buyer_reference.presence,
          locale: locale, layout_id: first.layout_id.try { |layout_id| id_of(layout_id) },
          deposit_ids: deposits.uniq,
        ).copy_with(**Channels.inherited(first, "invoice"))
      end

      # --- Bons à facturer ------------------------------------------------------------

      # Bons émis et non facturés, du plus ancien livré au plus récent.
      def self.to_invoice(query : Api::ToInvoiceQuery) : Array(Api::ToInvoiceView)
        records = Document.filter(kind: "delivery_note", status: "issued")
        records = records.filter(customer_id: query.customer_card_id) if query.customer_card_id
        records = records.filter(delivery_date__gte: query.from) if query.from
        records = records.filter(delivery_date__lte: query.to) if query.to
        notes = records.order(:delivery_date, :number)[0...query.limit.clamp(1, 2000)].to_a
        return [] of Api::ToInvoiceView if notes.empty?
        ids = notes.map { |note| id_of(note.id) }
        drafts = BilledDelivery.filter(delivery_note_id__in: ids).to_a.to_h do |row|
          {id_of(row.delivery_note_id), id_of(row.invoice_id)}
        end
        rhythms = CreditControl.rhythms(notes.map { |note| id_of(note.customer_id) }.uniq!)
        notes.map do |note|
          customer_id = id_of(note.customer_id)
          Api::ToInvoiceView.new(
            id: id_of(note.id), number: note.number.to_s, customer_card_id: customer_id,
            customer_name: Documents.customer(note).name, issue_date: note.issue_date || Documents.today,
            delivery_date: delivered_on(note), currency_code: note.currency_code!, total_net: note.total_net!,
            total_gross: note.total_gross!, draft_invoice_id: drafts[id_of(note.id)]?,
            billing_rhythm: rhythms[customer_id]? || "per_delivery",
          )
        end
      end
    end
  end
end
