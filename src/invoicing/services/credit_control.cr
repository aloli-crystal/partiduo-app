# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Invoicing
    # Réglage client de la Facturation (rythme de facturation, encours
    # maximum) et encours d'un client, HORS TAXES (DECISIONS D-INV2-005,
    # D-INV2-009) :
    #
    # * encours HT = bons de livraison émis non facturés (HT) − bons de
    #   retour émis non repris (HT, D-INV3-006) + part HT
    #   restant due des factures et factures d'acompte émises non annulées
    #   (HT × reste dû ÷ TTC ; reste dû = TTC − acomptes déduits −
    #   règlements − avoirs : un règlement partiel ou un avoir réduit la part
    #   HT au prorata) ;
    # * dans la devise du dossier : un document en devise étrangère est
    #   converti au cours du socle à sa date (comme le FEC, D-2F-009), et
    #   compté à son montant nominal s'il n'y en a pas (`unconverted`).
    #
    # Un devis, une commande ou un brouillon n'entrent pas dans l'encours ;
    # une commande, un bon de livraison et une facture sont contrôlés à
    # l'émission (`check`).
    module CreditControl
      alias Api = Partiduo::Api::Invoicing
      alias FieldError = Partiduo::Api::FieldError

      ZERO = BigDecimal.new(0)

      def self.id_of(value) : Int64
        Documents.id_of(value)
      end

      # --- Réglage client --------------------------------------------------------------

      def self.row(card_id : Int64) : CustomerBilling?
        CustomerBilling.filter(card_id: card_id).first
      end

      # Rythme de facturation de chaque client cité (défaut : `per_delivery`).
      def self.rhythms(card_ids : Array(Int64)) : Hash(Int64, String)
        return {} of Int64 => String if card_ids.empty?
        CustomerBilling.filter(card_id__in: card_ids).to_a.to_h do |setting|
          {setting.card_id!.to_i64, setting.billing_rhythm.presence || "per_delivery"}
        end
      end

      def self.errors(input : Api::CustomerBillingInput, card : Partiduo::Api::Cards::CardView?) : Array(FieldError)
        errors = [] of FieldError
        if card.nil? || card.kind != "customer"
          errors << Documents.error("customer_card_id", "document.customer.not_customer")
        end
        unless Api::BILLING_RHYTHMS.includes?(input.billing_rhythm)
          errors << Documents.error("billing_rhythm", "customer_billing.rhythm")
        end
        if limit = input.credit_limit
          if limit < 0 || Calculator.scale(limit) > Calculator::CENT || limit >= BigDecimal.new("1000000000000000")
            errors << Documents.error("credit_limit", "customer_billing.credit_limit")
          end
        end
        errors
      end

      def self.save!(card_id : Int64, input : Api::CustomerBillingInput) : Nil
        setting = CustomerBilling.filter(card_id: card_id).lock.first || CustomerBilling.new(card_id: card_id)
        setting.billing_rhythm = input.billing_rhythm
        setting.credit_limit = input.credit_limit
        setting.save!
      end

      # --- Encours ---------------------------------------------------------------------

      # Montant converti dans la devise du dossier ; `{montant, converti ?}`.
      def self.to_base(amount : BigDecimal, currency : String, on : Time?, base : String) : {BigDecimal, Bool}
        return {amount, true} if currency == base
        rate = begin
          Partiduo::Api::Core.rate_on(Partiduo::Api::Actor.system, currency, on || Documents.today)
        rescue Partiduo::Api::NotFound
          nil
        end
        return {amount, false} if rate.nil? || rate <= 0
        {(amount / rate).round(2, mode: :ties_away), true}
      end

      def self.view(card : Partiduo::Api::Cards::CardView) : Api::CustomerBillingView
        setting = row(card.id)
        base = Configuration.base_currency
        unconverted = 0
        unbilled = Document.filter(customer_id: card.id, kind: "delivery_note", status: "issued").to_a
        net = gross = receivable = ZERO
        unbilled.each do |note|
          converted_net, ok = to_base(note.total_net!, note.currency_code!, note.issue_date, base)
          converted_gross, _ = to_base(note.total_gross!, note.currency_code!, note.issue_date, base)
          unconverted += 1 unless ok
          net += converted_net
          gross += converted_gross
        end
        returns = Document.filter(customer_id: card.id, kind: "return_note", status: "issued").to_a
        returned = ZERO
        returns.each do |note|
          converted, ok = to_base(note.total_net!, note.currency_code!, note.issue_date, base)
          unconverted += 1 unless ok
          returned += converted
        end
        open_invoices(card.id).each do |invoice|
          remaining = remaining_net(invoice)
          next unless remaining > 0
          converted, ok = to_base(remaining, invoice.currency_code!, invoice.issue_date, base)
          unconverted += 1 unless ok
          receivable += converted
        end
        Api::CustomerBillingView.new(
          customer_card_id: card.id, customer_name: card.name,
          billing_rhythm: setting.try(&.billing_rhythm.presence) || "per_delivery",
          credit_limit: setting.try(&.credit_limit), currency_code: base, unbilled_count: unbilled.size,
          unbilled_net: net, unbilled_gross: gross, receivable_net: receivable, unconverted: unconverted,
          returns_count: returns.size, returns_net: returned,
        )
      end

      # Part HT restant due d'une facture émise : HT × reste dû ÷ TTC,
      # arrondie au centime.
      def self.remaining_net(invoice : Document) : BigDecimal
        gross = invoice.total_gross!
        return ZERO unless gross > 0
        due = gross - invoice.prepaid_amount! - invoice.paid_amount! - invoice.credited_amount!
        return ZERO unless due > 0
        Calculator.round(invoice.total_net! * due / gross)
      end

      private def self.open_invoices(card_id : Int64)
        Document.filter(customer_id: card_id, kind__in: %w[invoice deposit_invoice])
          .exclude(number: nil).exclude(status: "cancelled").to_a
      end

      # Clients dont l'encours atteint `percent` % de leur plafond.
      def self.alerts(percent : Int32) : Array(Api::CustomerBillingView)
        CustomerBilling.all.exclude(credit_limit: nil).to_a.compact_map do |setting|
          card = Configuration.card(setting.card_id!.to_i64) || next
          view = view(card)
          view if (view.percent_used || 0) >= percent || (view.credit_limit.try(&.zero?) && view.exposure > 0)
        end.sort_by! { |view| -(view.percent_used || Int32::MAX) }
      end

      # --- Contrôle d'un document --------------------------------------------------------

      # Contrôle de l'encours pour un brouillon (ou un document à émettre) ;
      # `nil` sans plafond, ou pour une nature qui n'est pas contrôlée
      # (facture d'acompte, avoir). Le devis est vérifié sans être bloqué.
      def self.check(document : Document) : Api::CreditCheckView?
        kind = document.kind!
        return unless kind == "quote" || Api::CREDIT_CONTROLLED_KINDS.includes?(kind)
        card = Configuration.card(id_of(document.customer_id)) || return
        limit = row(card.id).try(&.credit_limit) || return
        current = view(card)
        base = current.currency_code
        on = document.issue_date || Documents.today
        amount, _ = to_base(document.total_net!, document.currency_code!, on, base)
        if kind == "invoice"
          document_id = id_of(document.id)
          # Acomptes déduits (leur HT) : déjà facturés, donc dans l'encours.
          DepositDeduction.filter(invoice_id: document_id).to_a.each do |deduction|
            deposit = Document.filter(id: deduction.deposit_id).first || next
            amount -= to_base(deposit.total_net!, deposit.currency_code!, deposit.issue_date, base)[0]
          end
          # Bons repris : déjà dans l'encours (non facturés).
          BilledDelivery.filter(invoice_id: document_id).to_a.each do |billed|
            note = Document.filter(id: billed.delivery_note_id).first
            next unless note && note.status == "issued"
            amount -= to_base(note.total_net!, note.currency_code!, note.issue_date, base)[0]
          end
          # Bons de retour déduits : déjà retranchés de l'encours (D-INV3-006).
          BilledReturn.filter(document_id: document_id).to_a.each do |billed|
            note = Document.filter(id: billed.return_note_id).first
            next unless note && note.status == "issued"
            amount += to_base(note.total_net!, note.currency_code!, note.issue_date, base)[0]
          end
        end
        Api::CreditCheckView.new(
          customer_card_id: card.id, customer_name: card.name, currency_code: base, exposure: current.exposure,
          amount: amount, credit_limit: limit, controlled: kind != "quote",
        )
      end

      # Refus de l'émission au-delà du plafond, ou dérogation acceptée
      # (`{nil, motif}`) : motif obligatoire, permission
      # `invoicing.credit_limit.override`.
      def self.issue_decision(check : Api::CreditCheckView?, reason : String?,
                              actor : Partiduo::Api::Actor) : {FieldError?, String?}
        return {nil, nil} unless check && check.controlled && check.exceeded?
        motive = reason.try(&.strip).presence
        if motive.nil?
          {Documents.error(FieldError::BASE, "credit_limit.exceeded", check.params), nil}
        elsif !actor.can?(Api::CREDIT_OVERRIDE)
          {Documents.error(FieldError::BASE, "credit_limit.override_denied", check.params), nil}
        elsif motive.size > 500
          {Documents.error("credit_override_reason", "credit_limit.reason_too_long", {"max" => "500"}), nil}
        else
          {nil, motive}
        end
      end
    end
  end
end
