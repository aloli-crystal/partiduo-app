# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    # Contrat du module Comptabilité — écritures issues de la Facturation
    # (ADR-006 D2, D3). Les abonnés de `invoice.issued`, `credit_note.issued`
    # et `payment.recorded` passent les écritures d'office ; ce qui n'a pas pu
    # l'être (Comptabilité activée après coup, exercice absent, compte
    # manquant…) reste dans l'historique à comptabiliser, lu dans le journal
    # des événements du socle.
    module Accounting
      # Événement de la Facturation sans écriture : `event` (`invoice.issued`,
      # `credit_note.issued`, `payment.recorded`), référence de l'écriture
      # (`invoice:42`…), numéro du document, date (émission ou règlement),
      # montant toutes taxes comprises, fiche du client ; `errors` : ce qui
      # empêche aujourd'hui de le comptabiliser (vide : prêt), calculé en
      # rejouant l'historique entier sans rien enregistrer.
      record BillingEventView,
        event_id : Int64,
        event : String,
        source : String,
        number : String,
        date : Time?,
        amount : BigDecimal,
        customer_card_id : Int64?,
        published_at : Time,
        errors : Array(FieldError) do
        def postable? : Bool
          errors.empty?
        end
      end

      # Événement comptabilisé et ses écritures.
      record BillingPostedView, event_id : Int64, source : String, entry_ids : Array(Int64)

      # Issue de `post_invoicing_history` : ce qui est comptabilisé, ce qui
      # reste proposé (avec ses erreurs).
      record BillingHistoryView, posted : Array(BillingPostedView), remaining : Array(BillingEventView)

      # Historique des factures, avoirs et règlements de la Facturation qui
      # n'ont pas d'écriture, dans l'ordre de publication. C'est la
      # proposition faite à l'activation tardive de la Comptabilité
      # (ADR-006 D2).
      def self.invoicing_history(actor : Actor) : Array(BillingEventView)
        Guard.authorize!(actor, "accounting.entry.post", module_code: MODULE_CODE)
        events = Partiduo::Accounting::Billing.pending
        return [] of BillingEventView if events.empty?
        views = [] of BillingEventView
        # Essai à blanc : tout est rejoué dans l'ordre (un acompte avant sa
        # facture finale), puis annulé.
        Transaction.run do
          views = Partiduo::Accounting::Billing.replay(Actor.system, events).map { |outcome| billing_view(outcome) }
          Result(Nil).failure(FieldError.base("accounting.errors.billing.dry_run"))
        end
        views
      end

      # Comptabilise l'historique proposé (tout, ou les événements `event_ids`),
      # dans l'ordre de publication, avec l'acteur pour auteur. Chaque
      # événement est passé dans son point de sauvegarde : un échec laisse
      # l'événement proposé sans empêcher les suivants.
      def self.post_invoicing_history(actor : Actor, event_ids : Array(Int64)? = nil) : Result(BillingHistoryView)
        Guard.authorize!(actor, "accounting.entry.post", module_code: MODULE_CODE)
        Transaction.run do
          outcomes = Partiduo::Accounting::Billing.replay(actor, Partiduo::Accounting::Billing.pending(event_ids))
          posted = outcomes.select(&.errors.empty?).map do |outcome|
            BillingPostedView.new(outcome.event.id, outcome.source, outcome.entry_ids)
          end
          remaining = outcomes.reject(&.errors.empty?).map { |outcome| billing_view(outcome) }
          Result(BillingHistoryView).success(BillingHistoryView.new(posted, remaining))
        end
      end

      # Nombre d'événements de l'historique à comptabiliser, sans essai à
      # blanc (tableau de bord, activation tardive de la Comptabilité).
      def self.invoicing_history_count(actor : Actor) : Int32
        Guard.authorize!(actor, "accounting.entry.post", module_code: MODULE_CODE)
        Partiduo::Accounting::Billing.pending.size
      end

      # Écarte un événement de l'historique à comptabiliser : il n'est plus
      # proposé (pièce déjà saisie à la main, écriture passée autrement…).
      # Réversible par `restore_invoicing_event` (D-2F-010).
      def self.dismiss_invoicing_event(actor : Actor, event_id : Int64, reason : String = "") : Result(Nil)
        Guard.authorize!(actor, "accounting.entry.post", module_code: MODULE_CODE)
        Transaction.run do
          event = Partiduo::Events.journal(Partiduo::Accounting::Billing::EVENTS, [event_id]).first?
          raise NotFound.new("modules_event_log", event_id) if event.nil?
          if Partiduo::Accounting::BillingDismissal.filter(event_id: event_id).exists?
            next Result(Nil).failure(FieldError.base("accounting.errors.billing.already_dismissed"))
          end
          if Partiduo::Accounting::Billing.posted?(Partiduo::Accounting::Billing.source_of(event.name, event.payload))
            next Result(Nil).failure(FieldError.base("accounting.errors.billing.already_posted"))
          end
          if reason.size > 500
            next Result(Nil).failure(FieldError.new("reason", "accounting.errors.billing.reason_too_long", {"max" => "500"}))
          end
          Partiduo::Accounting::BillingDismissal.create!(event_id: event_id, reason: reason.strip,
            created_by_id: actor.user_id)
          Result(Nil).success(nil)
        end
      end

      # Rend à l'historique un événement écarté.
      def self.restore_invoicing_event(actor : Actor, event_id : Int64) : Result(Nil)
        Guard.authorize!(actor, "accounting.entry.post", module_code: MODULE_CODE)
        Transaction.run do
          deleted = Partiduo::Accounting::BillingDismissal.filter(event_id: event_id).delete
          next Result(Nil).failure(FieldError.base("accounting.errors.billing.not_dismissed")) if deleted.zero?
          Result(Nil).success(nil)
        end
      end

      # Événements écartés, dans l'ordre de publication (`errors` vide).
      def self.dismissed_invoicing_events(actor : Actor) : Array(BillingEventView)
        Guard.authorize!(actor, "accounting.entry.post", module_code: MODULE_CODE)
        ids = Partiduo::Accounting::BillingDismissal.all.map(&.event_id!.to_i64)
        return [] of BillingEventView if ids.empty?
        Partiduo::Events.journal(Partiduo::Accounting::Billing::EVENTS, ids).map do |event|
          billing_view(Partiduo::Accounting::Billing::Outcome.new(event,
            Partiduo::Accounting::Billing.source_of(event.name, event.payload), [] of Int64, [] of FieldError))
        end
      end

      private def self.billing_view(outcome : Partiduo::Accounting::Billing::Outcome) : BillingEventView
        event = outcome.event
        payload = event.payload
        date_text = event.name == "payment.recorded" ? payload["paid_on"]? : payload["issue_date"]?
        amount_text = event.name == "payment.recorded" ? payload["amount"]? : payload["total_gross"]?
        BillingEventView.new(
          event_id: event.id, event: event.name, source: outcome.source, number: payload["number"]?.to_s,
          date: date_text.try { |text| Time.parse_utc(text, "%Y-%m-%d") rescue nil },
          amount: amount_text.try { |text| BigDecimal.new(text) rescue nil } || BigDecimal.new(0),
          customer_card_id: payload["customer_card_id"]?.try(&.to_i64?), published_at: event.created_at,
          errors: outcome.errors,
        )
      end
    end
  end
end
