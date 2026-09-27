# SPDX-License-Identifier: AGPL-3.0-or-later

require "digest/sha256"
require "json"

module Partiduo
  module Invoicing
    # Émission d'un document (ADR-006 D5) : contrôles, numéro attribué par la
    # table de compteurs, identités et mentions figées, empreinte, PDF/A-3
    # (Factur-X pour les documents fiscaux), trace, événement. Le tout dans la
    # transaction de la commande : un échec n'attribue aucun numéro.
    module Issuing
      alias Api = Partiduo::Api::Invoicing
      alias FieldError = Partiduo::Api::FieldError

      # Statut d'un document à l'émission.
      ISSUED_STATUS = {
        "quote"           => "sent",
        "order"           => "confirmed",
        "delivery_note"   => "issued",
        "invoice"         => "issued",
        "deposit_invoice" => "issued",
        "credit_note"     => "issued",
      }

      def self.error(field : String, key : String, params = {} of String => String) : FieldError
        Documents.error(field, key, params)
      end

      def self.issue!(document : Document, input : Api::IssueInput,
                      actor : Partiduo::Api::Actor) : Partiduo::Api::Result(Api::DocumentView)
        result = Partiduo::Api::Result(Api::DocumentView)
        return result.failure(error(FieldError::BASE, "issue.already_issued")) unless document.draft?
        document_id = Documents.id_of(document.id)
        # Le brouillon est recontrôlé tel qu'il est enregistré (fiches, taux).
        _, data = Documents.line_data(document_id)
        totals = Calculator.compute(data, document.global_discount_kind!, document.global_discount_value!)
        issue_date = Documents.day(input.issue_date || document.issue_date || Documents.today)
        deductions = Documents.deductions(document_id)
        card = Configuration.card(Documents.id_of(document.customer_id))
        errors = issue_errors(document, data, totals, deductions, issue_date)
        if card.nil? || card.kind != "customer"
          errors << error("customer_card_id", "document.customer.not_found")
        end
        return result.failure(errors) unless errors.empty? && card

        allocation = Numbering.allocate!(document.series!, issue_date)
        if allocation.is_a?(Time)
          return result.failure(error("issue_date", "issue.before_last", {"date" => allocation.to_s("%Y-%m-%d")}))
        end
        seller = Configuration.seller_party
        customer = Configuration.customer_party(card)
        assign(document, allocation, issue_date, totals, deductions, seller, customer)
        context = Documents.mentions_context(document, seller, customer, Documents.vat_breakdown(totals), deductions,
          document.operation_category.to_s, document.due_date, document.delivery_date, issue_date,
          document.structured_reference.to_s)
        document.mentions = Documents.mentions_json(Mentions.build(context))
        document.fingerprint = Fingerprint.compute(document, Documents.line_data(document_id)[0], deductions)
        document.issued_at = Time.utc
        document.issued_by_id = actor.user_id
        pdf_sha256 = store_output(document)
        document.save!

        Documents.log(document_id, "issued", actor, document.fingerprint.to_s,
          {"number" => allocation.number, "pdf_sha256" => pdf_sha256})
        after_issue(document, totals, actor)
        Partiduo::Api::Result(Api::DocumentView).success(Documents.view(document))
      end

      private def self.issue_errors(document : Document, data : Array(Calculator::LineData), totals : Calculator::Totals,
                                    deductions : Array(Api::DeductionView), issue_date : Time) : Array(FieldError)
        errors = [] of FieldError
        # Pas de date d'émission future : le numéro attribué est définitif et
        # la chronologie de la série (`Numbering.allocate!`) bloquerait toute
        # émission antérieure à cette date (D-2F-002).
        if issue_date > (today = Documents.today)
          errors << error("issue_date", "issue.future", {"date" => today.to_s("%Y-%m-%d")})
        end
        errors << error("lines", "issue.no_line") if data.none?(&.priced?)
        if Api::FISCAL_KINDS.includes?(document.kind) && totals.total_gross <= 0
          errors << error("lines", "issue.total_not_positive")
        end
        if totals.discount_total > totals.lines_total
          errors << error("global_discount_value", "document.global_discount.exceeds")
        end
        errors << error(FieldError::BASE, "issue.company_incomplete") if Configuration.company.company_name.empty?
        if deductions.sum(BigDecimal.new(0), &.amount) > totals.total_gross
          errors << error("deposit_ids", "document.deposits.exceed_total")
        end
        errors.concat(deduction_errors(deductions))
        errors.concat(credit_note_errors(document, totals.total_gross, issue_date)) if document.kind == "credit_note"
        if (due = document.due_date) && due < issue_date
          errors << error("due_date", "document.due_date.before_issue")
        end
        errors
      end

      # Acompte annulé ou crédité par avoir depuis l'enregistrement du
      # brouillon : il ne se déduit plus (D-TST-003, D-2F-004). Relu sous
      # verrou : un avoir émis en même temps attend la fin de l'émission.
      private def self.deduction_errors(deductions : Array(Api::DeductionView)) : Array(FieldError)
        errors = [] of FieldError
        deductions.each_with_index do |deduction, index|
          deposit = Documents.find(deduction.deposit_id, lock: true)
          if deposit.status == "cancelled"
            errors << error("deposit_ids[#{index}]", "document.deposits.cancelled")
          elsif deposit.credited_amount! > 0
            errors << error("deposit_ids[#{index}]", "document.deposits.credited")
          end
        end
        errors
      end

      # Numéro, dates par défaut (échéance, validité, livraison), catégorie
      # d'opération, identités figées, totaux, état émis.
      private def self.assign(document : Document, allocation : Numbering::Allocation, issue_date : Time,
                              totals : Calculator::Totals, deductions : Array(Api::DeductionView),
                              seller : Api::PartyView, customer : Api::PartyView) : Nil
        settings = Configuration.settings
        kind = document.kind!
        document.number = allocation.number
        document.year = allocation.year
        document.sequence = allocation.sequence
        document.issue_date = issue_date
        document.delivery_date ||= issue_date
        if document.due_date.nil? && kind.in?("invoice", "deposit_invoice")
          document.due_date = issue_date + settings.payment_terms_days.days
        end
        if document.validity_date.nil? && kind == "quote"
          document.validity_date = issue_date + settings.quote_validity_days.days
        end
        document.operation_category = document.operation_category.presence || settings.default_operation_category
        document.vat_on_debits = settings.vat_on_debits
        if Configuration.regime == "be" && kind.in?("invoice", "deposit_invoice")
          document.structured_reference = Numbering.structured_reference(allocation.series, allocation.year,
            allocation.sequence)
        end
        document.seller = Configuration.party_json(seller)
        document.customer_snapshot = Configuration.party_json(customer)
        Documents.store_totals(document, totals)
        document.prepaid_amount = deductions.sum(BigDecimal.new(0), &.amount)
        document.status = ISSUED_STATUS[kind]
      end

      # PDF/A-3 (et XML Factur-X) produit, contrôlé et conservé comme pièce
      # jointe du socle ; renvoie son empreinte.
      private def self.store_output(document : Document) : String
        view = Documents.view(document)
        output = Output.render(view, layout_for(document))
        document.facturx_xml = output.xml.to_s
        stored = Partiduo::Api::Core.store_attachment(Partiduo::Api::Actor.system,
          Partiduo::Api::Core::AttachmentInput.new(Output.filename(view), "application/pdf", IO::Memory.new(output.pdf)))
        raise "PDF refusé par le stockage : #{stored.error_keys.join(", ")}" if stored.failure?
        attachment = stored.value!
        document.pdf_id = attachment.id
        attachment.sha256
      end

      def self.layout_for(document : Document) : Api::LayoutView?
        layout = if layout_id = document.layout_id
                   Layout.filter(id: layout_id).first
                 else
                   Layout.filter(is_default: true).first
                 end
        layout.try { |row| Layouts.view(row) }
      end

      private def self.credit_note_errors(document : Document, total : BigDecimal, issue_date : Time) : Array(FieldError)
        errors = [] of FieldError
        credited = Documents.find(Documents.id_of(document.credited_id || raise "avoir sans facture"), lock: true)
        remaining = credited.total_gross! - credited.credited_amount!
        if total > remaining
          errors << error("lines", "issue.credit_exceeds", {"remaining" => remaining.to_s})
        end
        if (date = credited.issue_date) && issue_date < date
          errors << error("issue_date", "issue.credit_before_invoice")
        end
        if Documents.deducted_deposit?(Documents.id_of(credited.id))
          errors << error("credited_document_id", "document.credited.deposit_deducted")
        end
        errors
      end

      # Effets de l'émission : devis source accepté, facture créditée, événement.
      private def self.after_issue(document : Document, totals : Calculator::Totals, actor : Partiduo::Api::Actor) : Nil
        document_id = Documents.id_of(document.id)
        case document.kind
        when "credit_note"
          credited = Documents.find(Documents.id_of(document.credited_id || raise "avoir sans facture"), lock: true)
          credited.credited_amount = credited.credited_amount! + document.total_gross!
          Payments.refresh_status(credited)
          Documents.log(Documents.id_of(credited.id), "credited", actor, "",
            {"credit_note" => document.number.to_s, "amount" => document.total_gross!.to_s})
          Partiduo::Events.publish("credit_note.issued", payload(document, totals).merge({
            "credit_note_id" => document_id.to_s,
            "invoice_id"     => credited.id.to_s,
            "invoice_number" => credited.number.to_s,
          }), actor_user_id: actor.user_id)
        when "delivery_note"
          # Sortie de stock (module Stock, lot 6, D-STK-004).
          Partiduo::Events.publish("delivery_note.issued", {
            "delivery_note_id" => document_id.to_s,
            "number"           => document.number.to_s,
            "issue_date"       => document.issue_date.try(&.to_s("%Y-%m-%d")) || "",
          }, actor_user_id: actor.user_id)
        when "invoice", "deposit_invoice"
          # `deposit_sources` : factures d'acompte déduites (`invoice:<id>`),
          # pour que l'écriture de la facture finale extourne leurs ventes
          # (D-INT-004).
          Partiduo::Events.publish("invoice.issued", payload(document, totals).merge({
            "invoice_id"      => document_id.to_s,
            "deposit_sources" => Documents.deductions(document_id).map { |row| "invoice:#{row.deposit_id}" }.join(","),
          }), actor_user_id: actor.user_id)
        end
      end

      private def self.sales_json(totals : Calculator::Totals) : String
        totals.shares.map do |share|
          {"item_card_id" => share.item_card_id, "vat_rate_id" => share.vat_rate_id, "amount" => share.amount.to_s}
        end.to_json
      end

      # Charge utile des événements `invoice.issued` et `credit_note.issued` :
      # de quoi passer l'écriture sans rappeler la Facturation (ADR-006 D3).
      # `sales` : parts du HT par (article, taux du socle), remise globale
      # déduite ; `vat` : TVA par taux du socle.
      def self.payload(document : Document, totals : Calculator::Totals) : Hash(String, String)
        vat_by_rate = {} of Int64? => BigDecimal
        totals.shares.each { |share| vat_by_rate[share.vat_rate_id] = BigDecimal.new(0) }
        # TVA de chaque groupe ventilée sur les taux du socle qui le composent.
        totals.groups.each do |group|
          weights = {} of Int64? => BigDecimal
          totals.shares.each do |share|
            rate = share.vat_rate_id.try { |rate_id| Configuration.rate(rate_id) }
            next unless rate && {rate.category, Calculator.plain(rate.rate), rate.exemption_code} == group.key
            weights[share.vat_rate_id] = weights.fetch(share.vat_rate_id, BigDecimal.new(0)) + share.amount
          end
          Calculator.allocate(group.vat, weights).each { |rate_id, amount| vat_by_rate[rate_id] += amount }
        end
        {
          "source"           => "#{document.kind == "credit_note" ? "credit_note" : "invoice"}:#{document.id}",
          "kind"             => document.kind!,
          "number"           => document.number.to_s,
          "type_code"        => Api::TYPE_CODES[document.kind!]? || "",
          "issue_date"       => document.issue_date.try(&.to_s("%Y-%m-%d")) || "",
          "due_date"         => document.due_date.try(&.to_s("%Y-%m-%d")) || "",
          "customer_card_id" => document.customer_id.to_s,
          "currency"         => document.currency_code!,
          "total_net"        => totals.total_net.to_s,
          "total_vat"        => totals.total_vat.to_s,
          "total_gross"      => totals.total_gross.to_s,
          "prepaid"          => document.prepaid_amount!.to_s,
          "sales"            => sales_json(totals),
          "vat"              => vat_by_rate.map { |rate_id, amount| {"vat_rate_id" => rate_id, "amount" => amount.to_s} }.to_json,
        }
      end
    end

    # Empreinte d'un document émis : SHA-256 de son contenu canonique (JSON à
    # clés triées) — numéro, dates, parties, lignes, totaux, acomptes,
    # mentions. Recalculable à tout moment (`verify`).
    module Fingerprint
      def self.canonical(document : Document, lines : Array(Line), deductions : Array(Partiduo::Api::Invoicing::DeductionView)) : String
        date = ->(value : Time?) { value.try(&.to_s("%Y-%m-%d")) || "" }
        content = {
          "kind"                 => JSON::Any.new(document.kind!),
          "number"               => JSON::Any.new(document.number.to_s),
          "issue_date"           => JSON::Any.new(date.call(document.issue_date)),
          "delivery_date"        => JSON::Any.new(date.call(document.delivery_date)),
          "due_date"             => JSON::Any.new(date.call(document.due_date)),
          "validity_date"        => JSON::Any.new(date.call(document.validity_date)),
          "currency"             => JSON::Any.new(document.currency_code!),
          "operation_category"   => JSON::Any.new(document.operation_category.to_s),
          "vat_on_debits"        => JSON::Any.new(document.vat_on_debits!),
          "seller"               => document.seller || JSON::Any.new(nil),
          "customer"             => document.customer_snapshot || JSON::Any.new(nil),
          "delivery_address"     => document.delivery_address || JSON::Any.new(nil),
          "structured_reference" => JSON::Any.new(document.structured_reference.to_s),
          "credited_id"          => JSON::Any.new(document.credited_id.to_s),
          "global_discount"      => JSON::Any.new("#{document.global_discount_kind}:#{Calculator.plain(document.global_discount_value!)}"),
          "totals"               => JSON::Any.new([document.lines_total!, document.discount_total!, document.total_net!,
                                     document.total_vat!, document.total_gross!, document.prepaid_amount!]
            .map { |amount| JSON::Any.new(Calculator.plain(amount)) }),
          "lines" => JSON::Any.new(lines.map do |line|
            JSON::Any.new([line.position.to_s, line.kind.to_s, line.item_id.to_s, line.description.to_s,
                           Calculator.plain(line.quantity!), line.unit_code.to_s, Calculator.plain(line.unit_price!),
                           line.discount_kind.to_s, Calculator.plain(line.discount_value!), line.vat_rate_id.to_s,
                           Calculator.plain(line.vat_percent!), line.vat_category.to_s, Calculator.plain(line.net_amount!)]
              .map { |value| JSON::Any.new(value) })
          end),
          "deductions" => JSON::Any.new(deductions.map do |deduction|
            JSON::Any.new("#{deduction.deposit_number}:#{Calculator.plain(deduction.amount)}")
          end),
          "mentions" => document.mentions || JSON::Any.new(nil),
        }
        sorted(JSON::Any.new(content)).to_json
      end

      def self.compute(document : Document, lines : Array(Line), deductions : Array(Partiduo::Api::Invoicing::DeductionView)) : String
        Digest::SHA256.hexdigest(canonical(document, lines, deductions))
      end

      def self.verify(document : Document) : Bool
        return false if document.draft?
        document_id = Documents.id_of(document.id)
        lines = Line.filter(document_id: document_id).order(:position).to_a
        compute(document, lines, Documents.deductions(document_id)) == document.fingerprint
      end

      private def self.sorted(value : JSON::Any) : JSON::Any
        if hash = value.as_h?
          JSON::Any.new(hash.keys.sort!.to_h { |key| {key, sorted(hash[key])} })
        elsif array = value.as_a?
          JSON::Any.new(array.map { |item| sorted(item) })
        else
          value
        end
      end
    end
  end
end
