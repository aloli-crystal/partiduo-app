# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Invoicing
    # Paiements rejetés (DECISIONS D-INV3-007 à D-INV3-011) : chèque
    # impayé, prélèvement rejeté, virement retourné.
    #
    # Le rejet est un mouvement inverse tracé : le règlement n'est jamais
    # effacé, il reste désigné par son rejet (`PaymentRejection`, en ajout
    # seul) et ne compte plus dans `paid_amount` ; la facture redevient due
    # (statut recalculé), l'encours HT du client remonte d'autant. Une
    # relance est proposée aussitôt (mécanisme des relances), les frais
    # bancaires peuvent être refacturés (brouillon d'une facture de frais).
    # `payment.rejected` est publié en dernier : la Comptabilité contre-passe
    # l'encaissement (délettrage, `payment.unmatched`) et passe les frais.
    module PaymentRejections
      alias Api = Partiduo::Api::Invoicing
      alias FieldError = Partiduo::Api::FieldError

      ZERO = BigDecimal.new(0)

      def self.error(field : String, key : String, params = {} of String => String) : FieldError
        Documents.error(field, key, params)
      end

      def self.errors(input : Api::PaymentRejectionInput, payment : Payment, document : Document) : Array(FieldError)
        if PaymentRejection.filter(payment_id: payment.id).exists?
          return [error(FieldError::BASE, "payment_rejection.already_rejected")]
        end
        if document.draft? || !Payments::PAYABLE_KINDS.includes?(document.kind)
          return [error(FieldError::BASE, "payment_rejection.document.invalid")]
        end
        date_errors(input, payment) + reason_errors(input) + fees_errors(input)
      end

      private def self.date_errors(input : Api::PaymentRejectionInput, payment : Payment) : Array(FieldError)
        rejected_on = Documents.day(input.rejected_on)
        if rejected_on < payment.paid_on!
          [error("rejected_on", "payment_rejection.date.before_payment", {"date" => payment.paid_on!.to_s("%Y-%m-%d")})]
        elsif rejected_on > Documents.today
          [error("rejected_on", "payment_rejection.date.future")]
        else
          [] of FieldError
        end
      end

      private def self.reason_errors(input : Api::PaymentRejectionInput) : Array(FieldError)
        errors = [] of FieldError
        errors << error("reason", "payment_rejection.reason.invalid") unless Api::REJECTION_REASONS.includes?(input.reason)
        text = input.reason_text.to_s.strip
        if input.reason == "other" && text.empty?
          errors << error("reason_text", "payment_rejection.reason_text.required")
        elsif text.size > 500
          errors << error("reason_text", "payment_rejection.reason_text.too_long", {"max" => "500"})
        end
        errors
      end

      # Frais : positifs, au centime ; refacturés, il en faut et un taux de
      # TVA actif.
      private def self.fees_errors(input : Api::PaymentRejectionInput) : Array(FieldError)
        errors = [] of FieldError
        if input.fees < 0
          errors << error("fees", "payment_rejection.fees.negative")
        elsif Calculator.scale(input.fees) > Calculator::CENT
          errors << error("fees", "payment_rejection.fees.scale")
        end
        return errors unless input.rebill_fees
        errors << error("fees", "payment_rejection.fees.required") unless input.fees > 0
        if rate_id = input.fees_vat_rate_id
          rate = Configuration.rate(rate_id)
          errors << error("fees_vat_rate_id", "payment_rejection.fees_vat_rate.invalid") if rate.nil? || !rate.enabled
        else
          errors << error("fees_vat_rate_id", "payment_rejection.fees_vat_rate.required")
        end
        errors
      end

      # Enregistre le rejet (document verrouillé par l'appelant). Le document
      # n'est plus enregistré après la publication : les abonnés (délettrage,
      # relettrage) mettent à jour ses règlements.
      def self.reject!(input : Api::PaymentRejectionInput, payment : Payment, document : Document,
                       actor : Partiduo::Api::Actor) : PaymentRejection
        document_id = Documents.id_of(document.id)
        amount = payment.amount!
        rejected_on = Documents.day(input.rejected_on)
        document.paid_amount = Math.max(document.paid_amount! - amount, ZERO)
        Payments.refresh_status(document)
        fees_invoice = fees_invoice!(input, payment, document, actor) if input.rebill_fees
        reminder = Reminders.propose_after_rejection!(document)
        rejection = PaymentRejection.create!(
          payment_id: payment.id, document_id: document_id, rejected_on: rejected_on, reason: input.reason,
          reason_text: input.reason_text.to_s.strip, amount: amount, fees: input.fees, fees_rebilled: input.rebill_fees,
          fees_invoice_id: fees_invoice.try(&.id), reminder_id: reminder.try(&.id), recorded_by_id: actor.user_id,
          created_at: Time.utc,
        )
        if reminder
          reminder.payment_rejection_id = rejection.id
          reminder.save!
        end
        Documents.log(document_id, "payment_rejected", actor, "", {
          "payment_id" => payment.id.to_s, "amount" => amount.to_s, "rejected_on" => rejected_on.to_s("%Y-%m-%d"),
          "reason" => input.reason, "fees" => input.fees.to_s,
          "fees_invoice" => fees_invoice.try(&.id).to_s, "reminder" => reminder.try(&.level).to_s,
        })
        Partiduo::Events.publish("payment.rejected", {
          "payment_id"       => payment.id.to_s,
          "rejection_id"     => rejection.id.to_s,
          "invoice_id"       => document_id.to_s,
          "number"           => document.number.to_s,
          "customer_card_id" => document.customer_id.to_s,
          "amount"           => amount.to_s,
          "paid_on"          => payment.paid_on!.to_s("%Y-%m-%d"),
          "rejected_on"      => rejected_on.to_s("%Y-%m-%d"),
          "method"           => payment.method!,
          "source"           => payment.source!,
          "matching_id"      => payment.matching_id.to_s,
          "fees"             => input.fees.to_s,
          "reason"           => input.reason,
          "currency"         => document.currency_code!,
        }, actor_user_id: actor.user_id)
        rejection
      end

      # Brouillon de la facture des frais refacturés (D-INV3-010) : une
      # facture à part, une ligne libre au taux choisi (en principe hors
      # champ, catégorie O, qui ne se mêle à aucune autre catégorie sur une
      # même facture : règles BR-O de l'EN 16931).
      private def self.fees_invoice!(input : Api::PaymentRejectionInput, payment : Payment, document : Document,
                                     actor : Partiduo::Api::Actor) : Document
        locale = document.locale!
        description = I18n.with_locale(locale) do
          I18n.t("invoicing.payment_rejections.fees_line", {
            "number" => document.number.to_s,
            "date"   => Output.format_date(payment.paid_on!, locale),
            "reason" => I18n.t("invoicing.rejection_reasons.#{input.reason}"),
          })
        end
        fees_input = Api::DocumentInput.new(
          kind: "invoice", customer_card_id: Documents.id_of(document.customer_id),
          lines: [Api::LineInput.new(kind: "free", description: description, quantity: BigDecimal.new(1),
            unit_code: "C62", unit_price: input.fees, vat_rate_id: input.fees_vat_rate_id)],
          currency_code: document.currency_code, operation_category: "services", locale: locale,
          layout_id: document.layout_id.try { |value| Documents.id_of(value) },
        )
        lines, errors = Documents.check(fees_input)
        raise Partiduo::Events::Refused.new(errors) unless errors.empty?
        invoice = Documents.save_draft!(fees_input, lines, actor)
        Documents.log(Documents.id_of(invoice.id), "created", actor, "",
          {"payment_rejection_of" => document.number.to_s})
        invoice
      end

      def self.view(rejection : PaymentRejection, payment : Payment? = nil, document : Document? = nil) : Api::PaymentRejectionView
        payment ||= Payment.filter(id: rejection.payment_id).first!
        document ||= Documents.find(Documents.id_of(rejection.document_id))
        customer_id = Documents.id_of(document.customer_id)
        monthly = CreditControl.rhythms([customer_id])[customer_id]? == "monthly"
        Api::PaymentRejectionView.new(
          id: Documents.id_of(rejection.id), payment_id: Documents.id_of(payment.id),
          document_id: Documents.id_of(document.id), document_number: document.number.to_s,
          customer_card_id: customer_id, customer_name: Documents.customer(document).name,
          currency_code: document.currency_code!, paid_on: payment.paid_on!, method: payment.method!,
          payment_source: payment.source!, amount: rejection.amount!, rejected_on: rejection.rejected_on!,
          reason: rejection.reason!, reason_text: rejection.reason_text.to_s, fees: rejection.fees!,
          fees_rebilled: rejection.fees_rebilled!, fees_invoice_id: rejection.fees_invoice_id.try(&.to_i64),
          reminder_id: rejection.reminder_id.try(&.to_i64), recorded_by_id: rejection.recorded_by_id.try(&.to_i64),
          created_at: rejection.created_at!,
          balance: document.status == "cancelled" ? ZERO : Payments.balance(document),
          end_of_month: monthly || document.payment_terms == "end_of_month",
        )
      end

      # Rejets enregistrés, du plus récent au plus ancien ; `open_only` : ceux
      # dont la facture reste due (« À traiter »).
      def self.list(open_only : Bool, customer_id : Int64?) : Array(Api::PaymentRejectionView)
        query = PaymentRejection.all
        if customer_id
          query = query.filter(document_id__in: Document.filter(customer_id: customer_id).map { |document| Documents.id_of(document.id) })
        end
        views = query.order("-rejected_on", "-id").to_a.map { |rejection| view(rejection) }
        open_only ? views.select(&.open?) : views
      end
    end
  end
end
