# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Invoicing
    # Règlements (ADR-006 D3, D5). *Une seule source de vérité* : Comptabilité
    # active, l'encaissement est saisi ou importé en banque puis lettré, et la
    # Facturation l'apprend par `payment.matched` (et le délettrage par
    # `payment.unmatched`) ; Comptabilité inactive, la
    # Facturation l'enregistre elle-même et publie `payment.recorded`.
    #
    # Solde d'une facture = TTC − acomptes déduits − règlements − avoirs.
    module Payments
      alias Api = Partiduo::Api::Invoicing
      alias FieldError = Partiduo::Api::FieldError

      PAYABLE_KINDS = %w[invoice deposit_invoice]

      def self.balance(document : Document) : BigDecimal
        document.total_gross! - document.prepaid_amount! - document.paid_amount! - document.credited_amount!
      end

      def self.view(payment : Payment, document : Document) : Api::PaymentView
        rejection = PaymentRejection.filter(payment_id: payment.id).first.try do |row|
          PaymentRejections.view(row, payment, document)
        end
        Api::PaymentView.new(
          id: Documents.id_of(payment.id), document_id: Documents.id_of(document.id),
          document_number: document.number.to_s, paid_on: payment.paid_on!, amount: payment.amount!,
          method: payment.method!, reference: payment.reference.to_s, source: payment.source!,
          matching_id: payment.matching_id.to_s, recorded_by_id: payment.recorded_by_id.try(&.to_i64),
          created_at: payment.created_at!, rejection: rejection,
        )
      end

      # Statut d'une facture ou d'une facture d'acompte après un règlement ou
      # un avoir (enregistre le document).
      def self.refresh_status(document : Document) : Nil
        return unless PAYABLE_KINDS.includes?(document.kind)
        gross = document.total_gross!
        status = if document.credited_amount! >= gross
                   "cancelled"
                 elsif balance(document) <= 0
                   "paid"
                 elsif document.paid_amount! > 0
                   "partially_paid"
                 elsif document.sent_at
                   "sent"
                 else
                   "issued"
                 end
        document.status = status
        document.save!
      end

      def self.errors(input : Api::PaymentInput, document : Document?) : Array(FieldError)
        errors = [] of FieldError
        if Partiduo::Modules.active?("ACCOUNTING")
          errors << Documents.error(FieldError::BASE, "payment.accounting_active")
          return errors
        end
        if document.nil? || !PAYABLE_KINDS.includes?(document.kind) || document.draft?
          errors << Documents.error("document_id", "payment.document.invalid")
          return errors
        end
        if document.status == "cancelled"
          errors << Documents.error("document_id", "payment.document.cancelled")
        end
        if input.amount <= 0
          errors << Documents.error("amount", "payment.amount.not_positive")
        elsif Calculator.scale(input.amount) > Calculator::CENT
          errors << Documents.error("amount", "payment.amount.scale")
        elsif input.amount > balance(document)
          errors << Documents.error("amount", "payment.amount.exceeds", {"balance" => balance(document).to_s})
        end
        errors << Documents.error("method", "payment.method") unless Api::PAYMENT_METHODS.includes?(input.method)
        if (reference = input.reference) && reference.size > 100
          errors << Documents.error("reference", "payment.reference.too_long", {"max" => "100"})
        end
        errors
      end

      def self.record!(input : Api::PaymentInput, document : Document, actor : Partiduo::Api::Actor) : Api::PaymentView
        payment = Payment.create!(
          document_id: Documents.id_of(document.id), paid_on: Documents.day(input.paid_on), amount: input.amount,
          method: input.method, reference: input.reference.to_s.strip, source: "manual",
          recorded_by_id: actor.user_id,
        )
        document.paid_amount = document.paid_amount! + input.amount
        refresh_status(document)
        Documents.log(Documents.id_of(document.id), "payment", actor, "",
          {"amount" => input.amount.to_s, "source" => "manual"})
        Partiduo::Events.publish("payment.recorded", {
          "payment_id"       => payment.id.to_s,
          "invoice_id"       => document.id.to_s,
          "number"           => document.number.to_s,
          "customer_card_id" => document.customer_id.to_s,
          "amount"           => input.amount.to_s,
          "paid_on"          => Documents.day(input.paid_on).to_s("%Y-%m-%d"),
          "method"           => input.method,
        }, actor_user_id: actor.user_id)
        view(payment, document)
      end

      # Abonné de `payment.matched` (Comptabilité, lettrage). Clés lues :
      # `matching_id` ; `sources` (`invoice:42,…`, référence posée sur
      # l'écriture de vente) ; facultatives : `amounts` (`invoice:42=100.00;…`,
      # montant lettré par document) et `matched_on` (`AAAA-MM-JJ`). Sans
      # montant, le lettrage solde la facture. Idempotent : un même lettrage
      # n'est compté qu'une fois par document.
      def self.on_matched(event : Partiduo::Events::Event) : Nil
        matching_id = event["matching_id"]
        amounts = matched_amounts(event["amounts"]?.to_s)
        paid_on = event["matched_on"]?.try { |text| Time.parse_utc(text, "%Y-%m-%d") rescue nil } || Documents.today
        event["sources"]?.to_s.split(',').each do |source|
          kind, _, id = source.strip.partition(':')
          document_id = id.to_i64?
          next unless kind == "invoice" && document_id
          document = Document.filter(id: document_id).lock.first
          next if document.nil? || document.draft? || !PAYABLE_KINDS.includes?(document.kind)
          next if Payment.filter(document_id: document_id, matching_id: matching_id).exists?
          matched!(document, Math.min(amounts[source.strip]? || balance(document), balance(document)), paid_on,
            matching_id, event.actor_user_id)
        end
      end

      # Abonné de `payment.unmatched` (Comptabilité, délettrage ou extourne
      # d'une écriture lettrée). Clés lues : `matching_id`, `sources`. Les
      # lignes de chaque facture citée redeviennent ouvertes en Comptabilité :
      # ses règlements venus du lettrage (`source` = `matching`) sont retirés
      # — ceux de ce lettrage et ceux des lettrages qu'il avait absorbés, car
      # une ligne n'appartient qu'à un lettrage à la fois — puis son statut
      # est recalculé. Les règlements saisis (`manual`) ne bougent pas. La
      # trace reste dans le journal des opérations (`payment_removed`).
      # Idempotent (D-2F-003).
      def self.on_unmatched(event : Partiduo::Events::Event) : Nil
        matching_id = event["matching_id"]
        event["sources"]?.to_s.split(',').each do |source|
          kind, _, id = source.strip.partition(':')
          document_id = id.to_i64?
          next unless kind == "invoice" && document_id
          document = Document.filter(id: document_id).lock.first
          next if document.nil? || document.draft? || !PAYABLE_KINDS.includes?(document.kind)
          # Un règlement rejeté (D-INV3-008) est déjà retranché et reste tracé.
          rejected = PaymentRejection.filter(document_id: document_id).to_a.map { |row| Documents.id_of(row.payment_id) }
          removed = Payment.filter(document_id: document_id, source: "matching").order(:id).to_a
            .reject { |payment| rejected.includes?(Documents.id_of(payment.id)) }
          next if removed.empty?
          amount = removed.sum(BigDecimal.new(0), &.amount!)
          Payment.filter(id__in: removed.map { |payment| Documents.id_of(payment.id) }).delete
          document.paid_amount = Math.max(document.paid_amount! - amount, BigDecimal.new(0))
          refresh_status(document)
          DocumentEvent.create!(document_id: document_id, action: "payment_removed", user_id: event.actor_user_id,
            details: JSON.parse({"amount" => amount.to_s, "source" => "matching", "matching_id" => matching_id,
                                 "matchings" => removed.map(&.matching_id.to_s).uniq!.join(",")}.to_json),
            created_at: Time.utc)
        end
      end

      # `invoice:42=100.00;invoice:43=12.50` → montants par source.
      private def self.matched_amounts(text : String) : Hash(String, BigDecimal)
        amounts = {} of String => BigDecimal
        text.split(/[;,]/).each do |pair|
          source, _, amount = pair.partition('=')
          amounts[source.strip] = BigDecimal.new(amount.strip) unless amount.strip.empty?
        end
        amounts
      end

      private def self.matched!(document : Document, amount : BigDecimal, paid_on : Time, matching_id : String,
                                user_id : Int64?) : Nil
        return unless amount > 0
        document_id = Documents.id_of(document.id)
        Payment.create!(document_id: document_id, paid_on: paid_on, amount: amount, method: "transfer",
          source: "matching", matching_id: matching_id, recorded_by_id: user_id)
        document.paid_amount = document.paid_amount! + amount
        refresh_status(document)
        DocumentEvent.create!(document_id: document_id, action: "payment", user_id: user_id,
          details: JSON.parse({"amount" => amount.to_s, "source" => "matching", "matching_id" => matching_id}.to_json),
          created_at: Time.utc)
      end
    end
  end
end
