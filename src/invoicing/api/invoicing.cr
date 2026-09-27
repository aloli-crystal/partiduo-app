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
          Partiduo::Invoicing::Line.filter(document_id: id).delete
          # Journal en ajout seul, sauf les traces d'un brouillon (déclencheur).
          Partiduo::Invoicing::DocumentEvent.filter(document_id: id).delete
          Partiduo::Invoicing::Document.filter(id: id).delete
          Result(Nil).success(nil)
        end
      end

      # Transforme un document émis en document suivant (devis → commande →
      # bon de livraison → facture → avoir ; commande → facture d'acompte) :
      # nouveau brouillon aux lignes recopiées, lien conservé. Un devis envoyé
      # devient accepté ; une facture tirée d'une commande déduit ses
      # factures d'acompte émises.
      def self.transform(actor : Actor, id : Int64, input : TransformInput) : Result(DocumentView)
        authorize!(actor, WRITE)
        Transaction.run do
          source = Documents.find(id, lock: true)
          document_input, errors = Documents.transform_input(source, input)
          next Result(DocumentView).failure(errors) unless errors.empty? && document_input
          lines, errors = Documents.check(document_input)
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
      def self.issue(actor : Actor, id : Int64, input : IssueInput = IssueInput.new) : Result(DocumentView)
        authorize!(actor, nil)
        kind = Documents.find(id).kind
        authorize!(actor, kind == "credit_note" ? CREDIT : ISSUE)
        Transaction.run do
          Partiduo::Invoicing::Issuing.issue!(Documents.find(id, lock: true), input, actor)
        end
      end

      # Décision du client sur un devis envoyé : `accepted` ou `refused`.
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
      # Facturation (papier imprimé, transmission par une extension de
      # plateforme) : date d'envoi posée, facture à l'état « envoyée », canal
      # figé. Sans effet sur un document déjà envoyé. Tracé.
      def self.mark_sent(actor : Actor, id : Int64) : Result(DocumentView)
        authorize!(actor, SEND)
        Transaction.run do
          Partiduo::Invoicing::Channels.mark_sent!(Documents.find(id, lock: true), actor)
        end
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
        message, errors = mail.compose(view, input) { document_pdf(Actor.system, view.id) }
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
