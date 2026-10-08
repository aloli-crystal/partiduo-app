# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    # Contrat du module Facturation (ADR-006 D4 à D6). Chaque commande et
    # requête lève `ModuleDisabled` si le module `INVOICING` est inactif.
    # Aucun appel au module Comptabilité : les échanges passent par les
    # événements `invoice.issued`, `credit_note.issued`, `payment.recorded`
    # (publiés) et `payment.matched` (reçu).
    module Invoicing
      MODULE = "INVOICING"

      READ     = "invoicing.invoice.read"
      WRITE    = "invoicing.invoice.write"
      ISSUE    = "invoicing.invoice.issue"
      SEND     = "invoicing.invoice.send"
      CREDIT   = "invoicing.credit_note.issue"
      PAY      = "invoicing.payment.record"
      REMIND   = "invoicing.reminder.send"
      TEMPLATE = "invoicing.template.manage"
      SETTINGS = "invoicing.settings.manage"
      EXPORT   = "invoicing.export.read"

      alias Documents = Partiduo::Invoicing::Documents

      # Transports de courriel, pour la configuration de la distribution et
      # les specs (`MemoryTransport`).
      alias MailTransport = Partiduo::Invoicing::Mail::Transport
      alias MemoryTransport = Partiduo::Invoicing::Mail::MemoryTransport
      alias SmtpTransport = Partiduo::Invoicing::Mail::SmtpTransport
      alias MailMessage = Partiduo::Invoicing::Mail::Message

      # Transport des courriels (défaut : `PARTIDUO_SMTP_URL`, sinon aucun).
      def self.mail_transport : MailTransport
        Partiduo::Invoicing::Mail.transport
      end

      def self.mail_transport=(transport : MailTransport?) : MailTransport?
        Partiduo::Invoicing::Mail.transport = transport
      end

      private def self.authorize!(actor : Actor, permission : String?) : Nil
        Guard.authorize!(actor, permission, module_code: MODULE)
      end

      # --- Paramètres --------------------------------------------------------------

      def self.settings(actor : Actor) : SettingsView
        authorize!(actor, READ)
        Partiduo::Invoicing::Configuration.settings
      end

      def self.check_settings(actor : Actor, input : SettingsInput) : Result(Nil)
        authorize!(actor, SETTINGS)
        errors = Partiduo::Invoicing::Configuration.errors(input)
        errors.empty? ? Result(Nil).success(nil) : Result(Nil).failure(errors)
      end

      def self.update_settings(actor : Actor, input : SettingsInput) : Result(SettingsView)
        authorize!(actor, SETTINGS)
        errors = Partiduo::Invoicing::Configuration.errors(input)
        return Result(SettingsView).failure(errors) unless errors.empty?
        Transaction.run do
          Result(SettingsView).success(Partiduo::Invoicing::Configuration.save!(input))
        end
      end

      # --- Modèles de mise en page ------------------------------------------------

      def self.layouts(actor : Actor) : Array(LayoutView)
        authorize!(actor, READ)
        Partiduo::Invoicing::Layout.all.order(:name).map { |layout| Partiduo::Invoicing::Layouts.view(layout) }
      end

      def self.layout(actor : Actor, id : Int64) : LayoutView
        authorize!(actor, READ)
        Partiduo::Invoicing::Layouts.view(find_layout(id))
      end

      def self.create_layout(actor : Actor, input : LayoutInput) : Result(LayoutView)
        authorize!(actor, TEMPLATE)
        errors = Partiduo::Invoicing::Layouts.errors(input)
        return Result(LayoutView).failure(errors) unless errors.empty?
        Transaction.run { Result(LayoutView).success(Partiduo::Invoicing::Layouts.save!(input)) }
      end

      def self.update_layout(actor : Actor, id : Int64, input : LayoutInput) : Result(LayoutView)
        authorize!(actor, TEMPLATE)
        layout = find_layout(id)
        errors = Partiduo::Invoicing::Layouts.errors(input, id)
        return Result(LayoutView).failure(errors) unless errors.empty?
        Transaction.run { Result(LayoutView).success(Partiduo::Invoicing::Layouts.save!(input, layout)) }
      end

      # Supprime un modèle qu'aucun document ne cite.
      def self.delete_layout(actor : Actor, id : Int64) : Result(Nil)
        authorize!(actor, TEMPLATE)
        find_layout(id)
        Transaction.run do
          if Partiduo::Invoicing::Document.filter(layout_id: id).exists?
            next Result(Nil).failure(Documents.error(FieldError::BASE, "layout.in_use"))
          end
          Partiduo::Invoicing::Layout.filter(id: id).delete
          Result(Nil).success(nil)
        end
      end

      private def self.find_layout(id : Int64) : Partiduo::Invoicing::Layout
        Partiduo::Invoicing::Layout.filter(id: id).first || raise NotFound.new("invoicing_layout", id)
      end

      # --- Documents : lecture ---------------------------------------------------

      def self.documents(actor : Actor, query : DocumentQuery = DocumentQuery.new) : Array(DocumentView)
        authorize!(actor, READ)
        limit = query.limit.clamp(1, 500)
        offset = query.offset.clamp(0, nil)
        document_query(query).order(:kind, :id)[offset...(offset + limit)].to_a.map { |document| Documents.view(document) }
      end

      def self.count_documents(actor : Actor, query : DocumentQuery = DocumentQuery.new) : Int64
        authorize!(actor, READ)
        document_query(query).count.to_i64
      end

      # Synthèse du tableau de bord au jour `on` (défaut : date du jour de
      # l'instance), agrégée par PostgreSQL sur les totaux enregistrés
      # (D-2F-005).
      def self.summary(actor : Actor, on : Time? = nil) : SummaryView
        authorize!(actor, READ)
        Partiduo::Invoicing::Summary.build(on || Partiduo::Config.today)
      end

      def self.document(actor : Actor, id : Int64) : DocumentView
        authorize!(actor, READ)
        Documents.view(Documents.find(id))
      end

      def self.document_by_number(actor : Actor, number : String) : DocumentView?
        authorize!(actor, READ)
        Partiduo::Invoicing::Document.filter(number: number.strip.upcase).first.try { |document| Documents.view(document) }
      end

      # Trace des opérations (qui, quand, empreinte).
      def self.document_events(actor : Actor, id : Int64) : Array(EventView)
        authorize!(actor, READ)
        Documents.find(id)
        Partiduo::Invoicing::DocumentEvent.filter(document_id: id).order(:id).map do |event|
          details = event.details.try(&.as_h?).try(&.transform_values(&.to_s)) || {} of String => String
          EventView.new(event.action!, event.user_id.try(&.to_i64), event.fingerprint.to_s, details, event.created_at!)
        end
      end

      # L'empreinte enregistrée à l'émission correspond-elle au contenu ?
      def self.verify_fingerprint(actor : Actor, id : Int64) : Bool
        authorize!(actor, READ)
        Partiduo::Invoicing::Fingerprint.verify(Documents.find(id))
      end

      # PDF du document : celui conservé à l'émission, ou, pour un brouillon,
      # un aperçu calculé (non conservé, sans XML Factur-X).
      def self.document_pdf(actor : Actor, id : Int64) : FileView
        authorize!(actor, READ)
        document = Documents.find(id)
        view = Documents.view(document)
        content = if pdf_id = document.pdf_id
                    Core.attachment_content(Actor.system, Documents.id_of(pdf_id))
                  else
                    Partiduo::Invoicing::Output.render(view, Partiduo::Invoicing::Issuing.layout_for(document)).pdf
                  end
        FileView.new(Partiduo::Invoicing::Output.filename(view), "application/pdf", content)
      end

      # XML CII Factur-X d'un document fiscal émis.
      def self.facturx_xml(actor : Actor, id : Int64) : FileView
        authorize!(actor, READ)
        document = Documents.find(id)
        xml = document.facturx_xml.to_s
        raise NotFound.new("facturx_xml", id) if xml.empty?
        FileView.new("#{document.number}-#{Partiduo::Invoicing::Output::XML_NAME}", "text/xml", xml.to_slice)
      end

      private def self.document_query(query : DocumentQuery)
        records = Partiduo::Invoicing::Document.all
        records = records.filter(kind: query.kind) if query.kind
        records = records.filter(status: query.status) if query.status
        records = records.filter(issue_channel: query.issue_channel) if query.issue_channel
        records = records.filter(customer_id: query.customer_card_id) if query.customer_card_id
        records = records.filter(issue_date__gte: query.from) if query.from
        records = records.filter(issue_date__lte: query.to) if query.to
        if search = query.search.presence
          records = records.filter(number__icontains: search.strip)
        end
        records
      end

      # --- Documents : brouillons ------------------------------------------------

      # Requête de contrôle : mêmes règles que la création, totaux calculés
      # (retour instantané de l'interface).
      def self.check_document(actor : Actor, input : DocumentInput, id : Int64? = nil) : Result(TotalsView)
        authorize!(actor, WRITE)
        current = id.try { |document_id| Documents.find(document_id) }
        lines, errors = Documents.check(input, current)
        return Result(TotalsView).failure(errors) unless errors.empty?
        totals = Partiduo::Invoicing::Calculator.compute(lines.map(&.data), input.global_discount_kind,
          input.global_discount_value)
        prepaid = input.deposit_ids.sum(BigDecimal.new(0)) { |deposit_id| Documents.find(deposit_id).total_gross! }
        zero = BigDecimal.new(0)
        Result(TotalsView).success(TotalsView.new(totals.lines_total, totals.discount_total, totals.total_net,
          totals.total_vat, totals.total_gross, prepaid, zero, zero))
      end

      def self.create_document(actor : Actor, input : DocumentInput) : Result(DocumentView)
        authorize!(actor, WRITE)
        Transaction.run do
          lines, errors = Documents.check(input)
          next Result(DocumentView).failure(errors) unless errors.empty?
          document = Documents.save_draft!(input, lines, actor)
          Documents.log(Documents.id_of(document.id), "created", actor)
          Result(DocumentView).success(Documents.view(document))
        end
      end

      def self.update_document(actor : Actor, id : Int64, input : DocumentInput) : Result(DocumentView)
        authorize!(actor, WRITE)
        Transaction.run do
          document = Documents.find(id, lock: true)
          next Result(DocumentView).failure(Documents.error(FieldError::BASE, "document.issued")) unless document.draft?
          lines, errors = Documents.check(input, document)
          next Result(DocumentView).failure(errors) unless errors.empty?
          Documents.save_draft!(input, lines, actor, document)
          Documents.log(id, "updated", actor)
          Result(DocumentView).success(Documents.view(document))
        end
      end

      # Supprime un brouillon ; un document émis ne se supprime jamais.
      def self.delete_draft(actor : Actor, id : Int64) : Result(Nil)
        authorize!(actor, WRITE)
        Transaction.run do
          document = Documents.find(id, lock: true)
          next Result(Nil).failure(Documents.error(FieldError::BASE, "document.issued")) unless document.draft?
          if Partiduo::Invoicing::Document.filter(credited_id: id).exists? ||
             Partiduo::Invoicing::DepositDeduction.filter(deposit_id: id).exists?
            next Result(Nil).failure(Documents.error(FieldError::BASE, "document.in_use"))
          end
          Partiduo::Invoicing::DepositDeduction.filter(invoice_id: id).delete
          # Bons repris libérés (D-INV2-002, D-INV3-003).
          Partiduo::Invoicing::BilledDelivery.filter(invoice_id: id).delete
          Partiduo::Invoicing::BilledReturn.filter(document_id: id).delete
          Partiduo::Invoicing::Line.filter(document_id: id).delete
          # Journal en ajout seul, sauf les traces d'un brouillon (déclencheur).
          Partiduo::Invoicing::DocumentEvent.filter(document_id: id).delete
          Partiduo::Invoicing::Document.filter(id: id).delete
          Result(Nil).success(nil)
        end
      end

      # Transforme un document émis en document suivant (devis → commande →
      # bon de livraison → facture → avoir ; commande → facture d'acompte ;
      # bon de livraison ou facture → bon de retour, quantités au plus égales
      # à celles de l'origine, D-INV3-001) :
      # nouveau brouillon aux lignes recopiées, lien conservé. Un devis envoyé
      # devient accepté ; une facture tirée d'une commande déduit ses
      # factures d'acompte émises.
      def self.transform(actor : Actor, id : Int64, input : TransformInput) : Result(DocumentView)
        authorize!(actor, WRITE)
        Transaction.run do
          source = Documents.find(id, lock: true)
          document_input, errors = Documents.transform_input(source, input)
          next Result(DocumentView).failure(errors) unless errors.empty? && document_input
          lines, errors = Documents.check(document_input, nil, id)
          next Result(DocumentView).failure(errors) unless errors.empty?
          document = Documents.save_draft!(document_input, lines, actor, source_id: id)
          if source.kind == "quote" && source.status == "sent"
            source.status = "accepted"
            source.save!
          end
          Documents.log(id, "transformed", actor, "", {"into" => document.id.to_s, "kind" => input.kind})
          Documents.log(Documents.id_of(document.id), "created", actor, "", {"from" => source.number.to_s})
          Result(DocumentView).success(Documents.view(document))
        end
      end

      # Émet le document : numéro attribué (table de compteurs), identités et
      # mentions figées, empreinte, PDF/A-3 (Factur-X pour les documents
      # fiscaux), `invoice.issued` ou `credit_note.issued`. Un avoir exige
      # `invoicing.credit_note.issue`, les autres `invoicing.invoice.issue`.
      # Une commande, un bon de livraison ou une facture qui ferait dépasser
      # l'encours maximum HT du client est refusé (`credit_limit.exceeded`),
      # sauf dérogation : `IssueInput#credit_override_reason` et permission
      # `invoicing.credit_limit.override` (`credit_limit.override_denied`
      # sinon), tracée (`credit_override`). La facture de bons de livraison
      # les fait passer à l'état `invoiced`.
      def self.issue(actor : Actor, id : Int64, input : IssueInput = IssueInput.new) : Result(DocumentView)
        authorize!(actor, nil)
        kind = Documents.find(id).kind
        authorize!(actor, kind == "credit_note" ? CREDIT : ISSUE)
        Transaction.run do
          Partiduo::Invoicing::Issuing.issue!(Documents.find(id, lock: true), input, actor)
        end
      end

      # Décision du client sur un devis envoyé : `accepted` ou `refused`.
      # Publie `quote.decided` dans la transaction (ADR-009 D5) : `quote_id`,
      # `decision`, `customer_card_id`, `number`.
      def self.decide_quote(actor : Actor, id : Int64, decision : String) : Result(DocumentView)
        authorize!(actor, WRITE)
        Transaction.run do
          document = Documents.find(id, lock: true)
          if document.kind != "quote" || document.status != "sent"
            next Result(DocumentView).failure(Documents.error(FieldError::BASE, "quote.not_sent"))
          end
          unless QUOTE_DECISIONS.includes?(decision)
            next Result(DocumentView).failure(Documents.error("decision", "quote.decision"))
          end
          document.status = decision
          document.save!
          Documents.log(id, decision, actor)
          Partiduo::Events.publish("quote.decided", {
            "quote_id"         => id.to_s,
            "decision"         => decision,
            "customer_card_id" => document.customer_id.to_s,
            "number"           => document.number.to_s,
          }, actor_user_id: actor.user_id)
          Result(DocumentView).success(Documents.view(document))
        end
      end

      # --- Canal d'émission (ADR-004 D9) --------------------------------------------

      # Canal proposé pour un client : plateforme agréée pour un professionnel
      # établi dans le pays du dossier, courriel ou papier sinon ; marquage
      # B2C d'un particulier. Ne dépend d'aucune extension.
      def self.propose_channel(actor : Actor, customer_card_id : Int64) : ChannelProposalView
        authorize!(actor, READ)
        card = Partiduo::Invoicing::Configuration.card(customer_card_id) ||
               raise NotFound.new("card", customer_card_id)
        Partiduo::Invoicing::Channels.propose(card)
      end

      # Change le canal d'émission (et, si donné, le marquage B2C) d'une
      # facture, d'une facture d'acompte ou d'un avoir, brouillon ou émis,
      # tant qu'il n'est pas envoyé (`channel.already_sent`). Tracé.
      def self.set_issue_channel(actor : Actor, id : Int64, input : ChannelInput) : Result(DocumentView)
        authorize!(actor, WRITE)
        Transaction.run do
          Partiduo::Invoicing::Channels.change!(Documents.find(id, lock: true), input, actor)
        end
      end

      # Marque envoyé un document émis remis hors du courriel de la
      # Facturation (papier imprimé, dépôt à la main sur un portail) : date
      # d'envoi posée, facture à l'état « envoyée », canal figé. Sans effet
      # sur un document déjà envoyé. Tracé. N'envoie pas la copie PDF : elle
      # suit le dépôt sur la plateforme (`invoice.platform_deposited`).
      def self.mark_sent(actor : Actor, id : Int64) : Result(DocumentView)
        authorize!(actor, SEND)
        Transaction.run do
          Partiduo::Invoicing::Channels.mark_sent!(Documents.find(id, lock: true), actor)
        end
      end

      # --- Copie PDF (ADR-004 D9) ----------------------------------------------------

      # Copie PDF d'une facture émise au canal `platform` : mise en page du
      # document, bandeau « Copie — l'original est la facture électronique
      # transmise par la plateforme agréée », sans XML Factur-X. Calculée à
      # la demande, jamais conservée comme original.
      def self.document_pdf_copy(actor : Actor, id : Int64) : FileView
        authorize!(actor, READ)
        document = Documents.find(id)
        raise NotFound.new("pdf_copy", id) unless Partiduo::Invoicing::PdfCopy.eligible?(document)
        Partiduo::Invoicing::PdfCopy.file(document)
      end

      # Copie PDF prévue pour ce document ? (option du dossier active à la
      # date du jour, client qui l'accepte et a une adresse électronique,
      # facture émise au canal `platform`.)
      def self.pdf_copy_due?(actor : Actor, id : Int64) : Bool
        authorize!(actor, READ)
        Partiduo::Invoicing::PdfCopy.due?(Documents.find(id))
      end

      # État de la copie PDF d'un document (prévue, dépôt, dernier envoi,
      # dernier échec) : « copie PDF envoyée le… » de l'écran.
      def self.pdf_copy_status(actor : Actor, id : Int64) : PdfCopyStatusView
        authorize!(actor, READ)
        Partiduo::Invoicing::PdfCopy.status(Documents.find(id))
      end

      # Envoie (ou renvoie) la copie PDF par courriel, à la demande, même
      # hors de la période de l'option ; tracée comme les autres envois,
      # sans changer l'état du document. Elle part d'elle-même après le
      # dépôt réussi sur la plateforme (événement `invoice.platform_deposited`
      # publié par l'extension qui transmet, D-CPY-001).
      def self.send_pdf_copy(actor : Actor, id : Int64, input : SendInput? = nil) : Result(EmailLogView)
        authorize!(actor, SEND)
        # Hors transaction : un échec du transport reste tracé.
        document = Documents.find(id)
        Partiduo::Invoicing::PdfCopy.send!(document, actor, input, force: true) ||
          Result(EmailLogView).failure(Documents.error(FieldError::BASE, "pdf_copy.not_platform"))
      end

      # --- Règlements ------------------------------------------------------------

      # Enregistre un règlement (total ou partiel) et publie
      # `payment.recorded`. Refusé quand la Comptabilité est active : le
      # règlement vient alors du lettrage (`payment.matched`).
      def self.record_payment(actor : Actor, input : PaymentInput) : Result(PaymentView)
        authorize!(actor, PAY)
        Transaction.run do
          document = Partiduo::Invoicing::Document.filter(id: input.document_id).lock.first
          errors = Partiduo::Invoicing::Payments.errors(input, document)
          next Result(PaymentView).failure(errors) unless errors.empty? && document
          Result(PaymentView).success(Partiduo::Invoicing::Payments.record!(input, document, actor))
        end
      end

      # Enregistre le rejet d'un règlement (chèque impayé, prélèvement
      # rejeté, virement retourné ; D-INV3-007) : le règlement reste, désigné
      # par le rejet, et ne compte plus ; la facture redevient due ; relance
      # proposée ; frais refacturés sur demande (brouillon d'une facture de
      # frais) ; `payment.rejected` publié (Comptabilité active : la
      # contre-passation de l'encaissement et les frais sont passés par son
      # abonné). Permission `invoicing.payment.record`, Comptabilité active
      # ou non. Refus : `payment_rejection.already_rejected`, `.document.invalid`,
      # `.date.before_payment`, `.date.future`, `.reason.invalid`,
      # `.reason_text.required`, `.reason_text.too_long`, `.fees.negative`,
      # `.fees.scale`, `.fees.required`, `.fees_vat_rate.required`,
      # `.fees_vat_rate.invalid`.
      def self.reject_payment(actor : Actor, payment_id : Int64, input : PaymentRejectionInput) : Result(PaymentRejectionView)
        authorize!(actor, PAY)
        Transaction.run do
          payment = Partiduo::Invoicing::Payment.filter(id: payment_id).first || raise NotFound.new("invoicing_payment", payment_id)
          document = Documents.find(Documents.id_of(payment.document_id), lock: true)
          errors = Partiduo::Invoicing::PaymentRejections.errors(input, payment, document)
          next Result(PaymentRejectionView).failure(errors) unless errors.empty?
          rejection = Partiduo::Invoicing::PaymentRejections.reject!(input, payment, document, actor)
          Result(PaymentRejectionView).success(Partiduo::Invoicing::PaymentRejections.view(rejection))
        rescue ex : Partiduo::Events::Refused
          Result(PaymentRejectionView).failure(ex.errors)
        end
      end

      # Rejets de paiement, du plus récent au plus ancien ; `open_only` :
      # ceux dont la facture reste due (« À traiter ») ; `customer_card_id` :
      # ceux d'un client.
      def self.payment_rejections(actor : Actor, open_only : Bool = false,
                                  customer_card_id : Int64? = nil) : Array(PaymentRejectionView)
        authorize!(actor, READ)
        Partiduo::Invoicing::PaymentRejections.list(open_only, customer_card_id)
      end

      def self.payments(actor : Actor, document_id : Int64) : Array(PaymentView)
        authorize!(actor, READ)
        document = Documents.find(document_id)
        Partiduo::Invoicing::Payment.filter(document_id: document_id).order(:paid_on, :id).map do |payment|
          Partiduo::Invoicing::Payments.view(payment, document)
        end
      end

      # --- Relances --------------------------------------------------------------

      # Propose les relances dues au jour `on` (« À traiter ») ; rien n'est
      # envoyé.
      def self.propose_reminders(actor : Actor, on : Time = Partiduo::Config.today) : Array(ReminderView)
        authorize!(actor, REMIND)
        result = Transaction.run do
          Result(Array(ReminderView)).success(Partiduo::Invoicing::Reminders.propose!(on))
        end
        result.value!
      end

      def self.reminders(actor : Actor, status : String? = "proposed") : Array(ReminderView)
        authorize!(actor, READ)
        query = Partiduo::Invoicing::Reminder.all
        query = query.filter(status: status) if status
        query.order(:proposed_on, :id).map { |reminder| Partiduo::Invoicing::Reminders.view(reminder) }
      end

      # Une relance réservée (`sending`) depuis plus longtemps que ce délai
      # est tenue pour abandonnée (processus interrompu pendant l'envoi) et
      # peut être reprise.
      REMINDER_SENDING_TIMEOUT = 15.minutes

      # Envoie une relance proposée, après validation de l'utilisateur ;
      # `input` à `nil` : adresse du client et textes par défaut.
      #
      # En trois temps (D-2F-008) : la relance est d'abord *réservée*
      # (`SELECT … FOR UPDATE`, statut `sending`) dans une transaction
      # validée aussitôt, le courriel part ensuite hors de toute transaction,
      # puis l'envoi est confirmé (`sent`) ou la réservation rendue
      # (`proposed`). Deux validations simultanées n'envoient donc qu'un
      # courriel : la seconde reçoit `reminder.in_progress`.
      def self.send_reminder(actor : Actor, id : Int64, input : SendInput? = nil) : Result(ReminderView)
        authorize!(actor, REMIND)
        reserved = reserve_reminder(actor, id)
        return Result(ReminderView).failure(reserved.errors) if reserved.failure?

        outcome = begin
          reminder = Partiduo::Invoicing::Reminder.filter(id: id).first!
          document = Documents.find(Documents.id_of(reminder.document_id))
          subject, body = Partiduo::Invoicing::Reminders.message(reminder, document)
          send_input = input || SendInput.new(to: [] of String)
          send_input = send_input.copy_with(subject: send_input.subject || subject, body: send_input.body || body)
          deliver(actor, document, send_input, id)
        rescue ex
          release_reminder(id)
          raise ex
        end
        if outcome.failure?
          release_reminder(id)
          return Result(ReminderView).failure(outcome.errors)
        end
        Transaction.run do
          locked = Partiduo::Invoicing::Reminder.filter(id: id).lock.first!
          locked.status = "sent"
          locked.sent_at = Time.utc
          locked.handled_by_id = actor.user_id
          locked.save!
          document = Documents.find(Documents.id_of(locked.document_id))
          Documents.log(Documents.id_of(document.id), "reminder", actor, "", {"level" => locked.level.to_s})
          Result(ReminderView).success(Partiduo::Invoicing::Reminders.view(locked, document))
        end
      end

      # Réserve une relance proposée (ou abandonnée en cours d'envoi) :
      # statut `sending`, transaction validée aussitôt.
      private def self.reserve_reminder(actor : Actor, id : Int64) : Result(Nil)
        Transaction.run do
          reminder = Partiduo::Invoicing::Reminder.filter(id: id).lock.first || raise NotFound.new("invoicing_reminder", id)
          stale = reminder.status == "sending" &&
                  (reminder.updated_at || Time.utc) < Time.utc - REMINDER_SENDING_TIMEOUT
          unless reminder.status == "proposed" || stale
            key = reminder.status == "sending" ? "reminder.in_progress" : "reminder.not_proposed"
            next Result(Nil).failure(Documents.error(FieldError::BASE, key))
          end
          reminder.status = "sending"
          reminder.handled_by_id = actor.user_id
          reminder.save!
          Result(Nil).success(nil)
        end
      end

      # Rend une relance réservée dont l'envoi a échoué.
      private def self.release_reminder(id : Int64) : Nil
        Transaction.run do
          Partiduo::Invoicing::Reminder.filter(id: id, status: "sending").update(status: "proposed")
          Result(Nil).success(nil)
        end
      end

      def self.dismiss_reminder(actor : Actor, id : Int64) : Result(ReminderView)
        authorize!(actor, REMIND)
        Transaction.run do
          reminder = Partiduo::Invoicing::Reminder.filter(id: id).lock.first || raise NotFound.new("invoicing_reminder", id)
          if reminder.status != "proposed"
            next Result(ReminderView).failure(Documents.error(FieldError::BASE, "reminder.not_proposed"))
          end
          reminder.status = "dismissed"
          reminder.handled_by_id = actor.user_id
          reminder.save!
          Result(ReminderView).success(Partiduo::Invoicing::Reminders.view(reminder))
        end
      end

      # --- Envoi par courriel ------------------------------------------------------

      # Envoie le PDF d'un document émis ; l'envoi est tracé (même en échec)
      # et une facture passe à l'état « envoyée ».
      def self.send_document(actor : Actor, id : Int64, input : SendInput) : Result(EmailLogView)
        authorize!(actor, SEND)
        document = Documents.find(id)
        deliver(actor, document, input, nil)
      end

      def self.email_logs(actor : Actor, document_id : Int64) : Array(EmailLogView)
        authorize!(actor, READ)
        Documents.find(document_id)
        Partiduo::Invoicing::EmailLog.filter(document_id: document_id).order(:id).map do |log|
          Partiduo::Invoicing::Mail.log_view(log)
        end
      end

      private def self.deliver(actor : Actor, document : Partiduo::Invoicing::Document, input : SendInput,
                               reminder_id : Int64?) : Result(EmailLogView)
        mail = Partiduo::Invoicing::Mail
        if document.draft?
          return Result(EmailLogView).failure(Documents.error(FieldError::BASE, "mail.draft"))
        end
        view = Documents.view(document)
        # Facture déposée sur la plateforme : l'original est la facture
        # électronique ; le courriel joint la copie (jamais de second
        # original, ADR-004 D9 révisé, D-CPY-001).
        message, errors = mail.compose(view, input) do
          if Partiduo::Invoicing::PdfCopy.replaces_original?(document)
            Partiduo::Invoicing::PdfCopy.file(document)
          else
            document_pdf(Actor.system, view.id)
          end
        end
        return Result(EmailLogView).failure(errors) unless message
        result = Transaction.run do
          Result(EmailLogView).success(mail.send_and_record(message, view.id, reminder_id, actor))
        end
        # Échec du transport : tracé (transaction validée), puis signalé.
        log_view = result.value!
        if log_view.status == "failed"
          return Result(EmailLogView).failure(Documents.error(FieldError::BASE, "mail.delivery_failed",
            {"error" => log_view.error}))
        end
        result
      end

      # --- Bons à facturer et facture récapitulative (D-INV2) ------------------------

      # Bons de livraison émis et non facturés (liste « Bons à facturer »),
      # filtrés par client et par période de livraison.
      # Bons de retour émis et non repris compris (`ToInvoiceView#kind`,
      # montants négatifs, D-INV3-002), du plus ancien au plus récent.
      def self.delivery_notes_to_invoice(actor : Actor, query : ToInvoiceQuery = ToInvoiceQuery.new) : Array(ToInvoiceView)
        authorize!(actor, READ)
        (Partiduo::Invoicing::DeliveryBilling.to_invoice(query) + Partiduo::Invoicing::Returns.to_invoice(query))
          .sort_by! { |note| {note.delivery_date, note.number} }
      end

      # Facture un ou plusieurs bons de livraison émis, non facturés et
      # libres, d'un même client et d'une même devise : brouillon de facture
      # (un bon : transformation habituelle ; plusieurs : facture
      # récapitulative, un groupe de lignes par bon, période de facturation).
      # Refus : `delivery_notes.empty`, `.duplicate`, `.several_customers`,
      # `.several_currencies`, `document.delivery_notes.invalid`,
      # `.already_billed`, `.in_draft`.
      #
      # Bons de retour compris dans la sélection (D-INV3-003, D-INV3-004) :
      # déduits de la facture (groupe, quantités négatives) ; s'ils
      # l'emportent sur les livraisons, le brouillon est un *avoir
      # récapitulatif* (`return_notes.no_invoice_to_credit` sans facture à
      # créditer) ; refus `document.return_notes.already_settled`,
      # `.in_draft`.
      def self.invoice_delivery_notes(actor : Actor, ids : Array(Int64)) : Result(DocumentView)
        authorize!(actor, WRITE)
        if ids.size == 1 && Partiduo::Invoicing::Document.filter(id: ids.first, kind: "delivery_note").exists?
          return transform(actor, ids.first, TransformInput.new("invoice"))
        end
        Transaction.run do
          notes = ids.map { |id| Partiduo::Invoicing::Document.filter(id: id).lock.first }
          errors = Partiduo::Invoicing::Returns.selection_errors(notes, ids)
          next Result(DocumentView).failure(errors) unless errors.empty?
          found = notes.compact
          input, errors = Partiduo::Invoicing::Returns.summary_input(found)
          next Result(DocumentView).failure(errors) unless errors.empty? && input
          lines, errors = Documents.check(input)
          next Result(DocumentView).failure(errors) unless errors.empty?
          document = Documents.save_draft!(input, lines, actor)
          Documents.log(Documents.id_of(document.id), "created", actor, "",
            {"delivery_notes" => found.map(&.number.to_s).join(",")})
          found.each do |note|
            Documents.log(Documents.id_of(note.id), "transformed", actor, "", {"into" => document.id.to_s, "kind" => document.kind!})
          end
          Result(DocumentView).success(Documents.view(document))
        end
      end

      # --- Retours de marchandises (D-INV3) ---------------------------------------------

      # Avoir d'un ou de plusieurs bons de retour émis et non repris d'un
      # même client (hors facturation mensuelle, D-INV3-005) : brouillon
      # d'avoir qui les cite (un groupe par bon s'ils sont plusieurs), sur la
      # facture `credited_document_id`, ou, à défaut, la facture d'origine des
      # bons (sinon la plus récente facture du client qui peut être créditée
      # de ce montant). Le stock n'est pas mouvementé une seconde fois.
      # Refus : `delivery_notes.empty`, `.duplicate`, `.several_customers`,
      # `.several_currencies`, `document.return_notes.invalid`,
      # `.already_settled`, `.in_draft`, `return_notes.no_invoice_to_credit`,
      # et ceux de tout avoir (`document.credited.…`).
      def self.credit_return_notes(actor : Actor, ids : Array(Int64), credited_document_id : Int64? = nil) : Result(DocumentView)
        authorize!(actor, WRITE)
        Transaction.run do
          notes = ids.map { |id| Partiduo::Invoicing::Document.filter(id: id).lock.first }
          if notes.any? { |note| note && note.kind != "return_note" }
            next Result(DocumentView).failure(Documents.error("return_note_ids", "document.return_notes.invalid"))
          end
          errors = Partiduo::Invoicing::Returns.selection_errors(notes, ids)
          next Result(DocumentView).failure(errors) unless errors.empty?
          found = notes.compact
          input, errors = Partiduo::Invoicing::Returns.credit_input(found, credited_document_id)
          next Result(DocumentView).failure(errors) unless errors.empty? && input
          lines, errors = Documents.check(input)
          next Result(DocumentView).failure(errors) unless errors.empty?
          document = Documents.save_draft!(input, lines, actor)
          Documents.log(Documents.id_of(document.id), "created", actor, "",
            {"return_notes" => found.map(&.number.to_s).join(",")})
          found.each do |note|
            Documents.log(Documents.id_of(note.id), "transformed", actor, "", {"into" => document.id.to_s, "kind" => "credit_note"})
          end
          Result(DocumentView).success(Documents.view(document))
        end
      end

      # --- Réglage client : rythme de facturation, encours maximum -----------------

      # Réglage et encours HT d'un client (bons non facturés, reste dû).
      def self.customer_billing(actor : Actor, customer_card_id : Int64) : CustomerBillingView
        authorize!(actor, READ)
        card = Partiduo::Invoicing::Configuration.card(customer_card_id) || raise NotFound.new("card", customer_card_id)
        Partiduo::Invoicing::CreditControl.view(card)
      end

      # Rythme de facturation (`BILLING_RHYTHMS`) et encours maximum HT
      # (`nil` : pas de plafond) d'un client. Paramètres de la Facturation.
      def self.update_customer_billing(actor : Actor, customer_card_id : Int64,
                                       input : CustomerBillingInput) : Result(CustomerBillingView)
        authorize!(actor, SETTINGS)
        card = Partiduo::Invoicing::Configuration.card(customer_card_id)
        errors = Partiduo::Invoicing::CreditControl.errors(input, card)
        return Result(CustomerBillingView).failure(errors) unless errors.empty? && card
        Transaction.run do
          Partiduo::Invoicing::CreditControl.save!(card.id, input)
          Result(CustomerBillingView).success(Partiduo::Invoicing::CreditControl.view(card))
        end
      end

      # Clients dont l'encours HT atteint `percent` % (défaut : 90) de leur
      # encours maximum, du plus engagé au moins engagé (« À traiter »).
      def self.credit_alerts(actor : Actor, percent : Int32 = CREDIT_ALERT_PERCENT) : Array(CustomerBillingView)
        authorize!(actor, READ)
        Partiduo::Invoicing::CreditControl.alerts(percent)
      end

      # Contrôle de l'encours pour un document (brouillon ou émis) : `nil`
      # sans plafond pour le client, ou pour une facture d'acompte, un avoir.
      def self.credit_check(actor : Actor, id : Int64) : CreditCheckView?
        authorize!(actor, READ)
        Partiduo::Invoicing::CreditControl.check(Documents.find(id))
      end

      # --- Fin de mois (D-INV2-007, D-INV2-008) --------------------------------------

      # Prépare les factures récapitulatives du mois (`MonthlyInput`) :
      # pour chaque client au rythme mensuel (ou le client désigné, quel que
      # soit son rythme), un brouillon regroupant ses bons émis, non facturés
      # et livrés au plus tard le dernier jour du mois ; jamais deux pour un
      # client, un mois et une devise. Mode du dossier « émettre et envoyer »
      # : chaque facture est aussitôt émise et envoyée par le canal de son
      # client (`issue_and_send`) ; il faut alors `invoicing.invoice.issue` et
      # `invoicing.invoice.send`.
      def self.prepare_monthly_invoices(actor : Actor, input : MonthlyInput = MonthlyInput.new) : MonthlyRunView
        authorize!(actor, WRITE)
        month = Partiduo::Invoicing::MonthEnd.month_start(input.month || Partiduo::Config.today)
        run_months(actor, [month], input.customer_card_id, input.trigger)
      end

      # Passage planifié de fin de mois au jour `today` (défaut : date du
      # jour) : mois précédent s'il n'est pas clos (rattrapage), mois courant
      # si c'est son dernier jour ; chaque mois traité est clos. Idempotent :
      # à lancer chaque jour (`manage invoicing-month-end`).
      def self.month_end(actor : Actor, today : Time? = nil) : MonthlyRunView
        authorize!(actor, WRITE)
        months = Partiduo::Invoicing::MonthEnd.due_months(today || Partiduo::Config.today)
        run_months(actor, months, nil, "schedule")
      end

      private def self.run_months(actor : Actor, months : Array(Time), customer_id : Int64?, trigger : String) : MonthlyRunView
        mode = Partiduo::Invoicing::Configuration.settings.monthly_billing_mode
        if mode == "auto_send"
          authorize!(actor, ISSUE)
          authorize!(actor, SEND)
        end
        prepared = [] of Partiduo::Invoicing::MonthlyInvoice
        skipped = 0
        months.each do |month|
          rows, count = Partiduo::Invoicing::MonthEnd.prepare!(month, customer_id, mode, actor)
          prepared.concat(rows)
          skipped += count
          if trigger == "schedule" && customer_id.nil?
            Transaction.run do
              Partiduo::Invoicing::MonthEnd.close!(month, trigger, rows.size)
              Result(Nil).success(nil)
            end
          end
        end
        if mode == "auto_send"
          prepared.each do |row|
            invoice_id = row.invoice_id || next
            issue_and_send(actor, invoice_id.to_i64)
          end
        end
        views = prepared.map do |row|
          Partiduo::Invoicing::MonthEnd.view(Partiduo::Invoicing::MonthlyInvoice.filter(id: row.id).first || row)
        end
        MonthlyRunView.new(months, views, skipped)
      end

      # Factures de fin de mois encore en brouillon (« À traiter »).
      def self.monthly_proposals(actor : Actor) : Array(MonthlyInvoiceView)
        authorize!(actor, READ)
        Partiduo::Invoicing::MonthEnd.proposals.map { |row| Partiduo::Invoicing::MonthEnd.view(row) }
      end

      # Émet une facture (si elle est en brouillon) puis l'envoie par son
      # canal : courriel à l'adresse du client ; plateforme (relevée par
      # l'extension de transmission) ; papier et portail public (à remettre
      # puis marquer envoyé). L'émission refusée est un échec ; une facture
      # émise dont l'envoi n'a pas pu se faire est un succès qui le dit
      # (`DispatchView#action`). Met à jour la facture de fin de mois qu'elle
      # est, le cas échéant.
      def self.issue_and_send(actor : Actor, id : Int64, input : IssueInput = IssueInput.new) : Result(DispatchView)
        authorize!(actor, ISSUE)
        document = Documents.find(id)
        # Avoir récapitulatif de fin de mois (D-INV3-004) : émis et envoyé de
        # même.
        monthly_credit = document.kind == "credit_note" &&
                         Partiduo::Invoicing::MonthlyInvoice.filter(invoice_id: id).exists?
        unless document.kind.in?("invoice", "deposit_invoice") || monthly_credit
          return Result(DispatchView).failure(Documents.error(FieldError::BASE, "dispatch.kind"))
        end
        if document.draft?
          issued = issue(actor, id, input)
          if issued.failure?
            keys = issued.errors.map(&.key).uniq!.join(", ")
            Transaction.run do
              Partiduo::Invoicing::MonthEnd.record_outcome(id, "failed", keys)
              Result(Nil).success(nil)
            end
            return Result(DispatchView).failure(issued.errors)
          end
        end
        outcome = dispatch(actor, Documents.view(Documents.find(id)))
        status = outcome.action == "emailed" || outcome.action == "already_sent" ? "sent" : "issued"
        error = outcome.action.in?("email_missing", "email_failed", "send_denied") ? "invoicing.dispatch.#{outcome.action}" : ""
        Transaction.run do
          Partiduo::Invoicing::MonthEnd.record_outcome(id, status, error)
          Result(Nil).success(nil)
        end
        Result(DispatchView).success(outcome)
      end

      # Émet et envoie toutes les factures de fin de mois proposées.
      def self.issue_and_send_proposals(actor : Actor) : Array(Result(DispatchView))
        authorize!(actor, ISSUE)
        Partiduo::Invoicing::MonthEnd.proposals.compact_map(&.invoice_id).map { |id| issue_and_send(actor, id.to_i64) }
      end

      private def self.dispatch(actor : Actor, view : DocumentView) : DispatchView
        return DispatchView.new(view, "already_sent") if view.sent_at
        case view.issue_channel
        when "platform"      then DispatchView.new(view, "platform")
        when "paper"         then DispatchView.new(view, "to_print")
        when "public_portal" then DispatchView.new(view, "public_portal")
        else
          return DispatchView.new(view, "send_denied") unless actor.can?(SEND)
          address = view.customer.email.strip
          return DispatchView.new(view, "email_missing") if address.empty?
          sent = send_document(actor, view.id, SendInput.new(to: [address]))
          if sent.failure?
            DispatchView.new(view, "email_failed", sent.errors.map { |error| error.params["error"]? || error.key }.join(", "))
          else
            DispatchView.new(Documents.view(Documents.find(view.id)), "emailed", address)
          end
        end
      end

      # --- Transmission au comptable (Facturation seule) ---------------------------

      def self.sales_journal_csv(actor : Actor, from : Time, to : Time) : FileView
        authorize!(actor, EXPORT)
        name = "#{I18n.t("invoicing.exports.csv_name")}-#{from.to_s("%Y%m%d")}-#{to.to_s("%Y%m%d")}.csv"
        FileView.new(name, "text/csv", Partiduo::Invoicing::Exports.csv(from, to))
      end

      # FEC des ventes, en devise de tenue ; échec si un document en devise
      # étrangère n'a pas de cours du socle à sa date (`export.currency_rate`).
      def self.sales_fec(actor : Actor, from : Time, to : Time) : Result(FileView)
        authorize!(actor, EXPORT)
        content, errors = Partiduo::Invoicing::Exports.fec(from, to)
        return Result(FileView).failure(errors) unless content
        Result(FileView).success(FileView.new(Partiduo::Invoicing::Exports.fec_filename(to), "text/plain", content))
      end

      def self.pdf_archive(actor : Actor, from : Time, to : Time) : FileView
        authorize!(actor, EXPORT)
        name = "#{I18n.t("invoicing.exports.archive_name")}-#{from.to_s("%Y%m%d")}-#{to.to_s("%Y%m%d")}.zip"
        FileView.new(name, "application/zip", Partiduo::Invoicing::Exports.archive(from, to))
      end
    end
  end
end
