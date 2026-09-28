# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Invoicing
    # Copie PDF doublant l'envoi par la plateforme agréée (ADR-004 D9 révisé,
    # 28 septembre 2026). Une facture émise par la plateforme peut être
    # doublée d'un envoi de son PDF par courriel :
    #
    # * option du dossier (`Settings#pdf_copy_enabled`), active par défaut
    #   pendant la *première année* de facturation électronique : la période
    #   (`pdf_copy_from` … `pdf_copy_until`) est posée pour un an au premier
    #   envoi par la plateforme quand elle est vide, puis se règle à l'écran ;
    #   aucune échéance écrite en dur ;
    # * désactivable par client (`pdf_copy` de la fiche) ;
    # * le PDF porte la mention « Copie — l'original est la facture
    #   électronique transmise par la plateforme agréée » et n'embarque pas
    #   le XML Factur-X : il ne peut passer pour un second original (CGI
    #   art. 283-3) ;
    # * l'envoi est tracé comme les autres (`EmailLog`, événements
    #   `pdf_copy_sent` / `pdf_copy_failed`), sans changer l'état du document ;
    # * elle part *après le dépôt réussi* sur la plateforme : l'extension qui
    #   transmet publie `invoice.platform_deposited`, la Facturation s'y
    #   abonne (aucun appel entre modules) ; sans extension de plateforme,
    #   aucune copie ne part d'elle-même ;
    # * jamais de second original : une fois la facture déposée, tout envoi
    #   par courriel de son PDF (envoi, relance) joint la copie.
    #
    # DECISIONS D-FIN-002, D-CPY-001.
    module PdfCopy
      alias Api = Partiduo::Api::Invoicing
      alias FieldError = Partiduo::Api::FieldError

      Log = ::Log.for("partiduo.invoicing.pdf_copy")

      # La copie est-elle prévue pour ce document ? Facture, facture
      # d'acompte ou avoir émis, au canal `platform`, client qui l'accepte et
      # a une adresse électronique, option active à la date du jour.
      def self.due?(document : Document) : Bool
        return false if document.draft? || !Channels.fiscal?(document.kind!)
        return false unless document.issue_channel == "platform"
        card = Configuration.card(Documents.id_of(document.customer_id))
        return false if card.nil? || !card.pdf_copy || card.email.strip.empty?
        Configuration.settings.pdf_copy_active?(Documents.today)
      end

      # Abonné de `invoice.platform_deposited` : le document est marqué
      # envoyé (canal figé), le dépôt tracé, la période ouverte si elle est
      # vide ; la copie part après la validation (effet extérieur), si elle
      # est prévue. Idempotent pour l'envoi : une copie déjà envoyée pour ce
      # dépôt ne repart pas.
      #
      # Tolérant (D-CPY-007) : un document introuvable ou brouillon est
      # journalisé puis ignoré ; un document dont le canal n'est pas
      # `platform` (événement erroné ou tardif) n'est ni marqué envoyé ni
      # doublé : l'anomalie est tracée (`platform_deposit_ignored`).
      def self.on_platform_deposited(event : Partiduo::Events::Event) : Nil
        id = event["invoice_id"].to_i64
        document = begin
          Documents.find(id, lock: true)
        rescue Partiduo::Api::NotFound
          Log.warn { "dépôt sur la plateforme signalé pour le document #{id}, introuvable : ignoré" }
          return
        end
        return if document.draft?
        actor = Partiduo::Api::Actor.system
        details = {"platform_ref" => event["platform_ref"]? || "", "connector" => event["connector"]? || ""}
        unless document.issue_channel == "platform"
          Documents.log(id, "platform_deposit_ignored", actor, "",
            details.merge({"channel" => document.issue_channel.to_s}))
          return
        end
        first = !deposited?(id)
        Channels.mark_sent!(document, actor)
        Documents.log(id, "platform_deposited", actor, "", details)
        return unless first && eligible?(document)
        open_period!
        Partiduo::Events.after_commit { send_after_deposit(id) }
      end

      # Envoi de la copie après le dépôt (hors transaction) : tout échec est
      # journalisé et tracé (`pdf_copy_failed`), jamais propagé : il ne doit
      # ni remonter jusqu'à l'extension qui a déposé la facture ni changer
      # l'état de sa transmission (D-CPY-001, D-CPY-007).
      def self.send_after_deposit(id : Int64) : Nil
        send!(Documents.find(id), Partiduo::Api::Actor.system)
      rescue ex
        Log.error(exception: ex) { "copie PDF du document #{id} non envoyée" }
        key = ex.is_a?(Output::ConformanceError) ? "render_failed" : "internal"
        begin
          log_failure(id, Partiduo::Api::Actor.system, "invoicing.errors.pdf_copy.#{key}", ex.message || ex.class.name)
        rescue error
          Log.error(exception: error) { "échec de la copie PDF du document #{id} non tracé" }
        end
      end

      # Trace un échec de la copie : `error` porte une ou plusieurs clés de
      # traduction (séparées par « , »), `detail` le détail technique
      # (message du serveur de courrier, de la conformité…) qui renseigne
      # leur paramètre (D-CPY-006, D-CPY-007).
      def self.log_failure(id : Int64, actor : Partiduo::Api::Actor, keys : String, detail : String = "") : Nil
        Documents.log(id, "pdf_copy_failed", actor, "", {"error" => keys, "detail" => detail})
      end

      # Le document a-t-il été déposé sur la plateforme ?
      def self.deposited?(id : Int64) : Bool
        DocumentEvent.filter(document_id: id, action: "platform_deposited").exists?
      end

      # Un envoi par courriel du PDF de ce document doit-il joindre la copie
      # plutôt que l'original ? Oui dès que la plateforme a remis la facture :
      # l'original est alors la facture électronique.
      def self.replaces_original?(document : Document) : Bool
        eligible?(document) && deposited?(Documents.id_of(document.id))
      end

      # État de la copie pour l'écran de la facture : prévue, déposée le,
      # dernière copie envoyée (date, destinataires), dernier échec.
      def self.status(document : Document) : Api::PdfCopyStatusView
        id = Documents.id_of(document.id)
        events = DocumentEvent.filter(document_id: id, action__in: %w[platform_deposited pdf_copy_sent pdf_copy_failed])
          .order(:id).to_a
        detail = ->(event : DocumentEvent, key : String) do
          event.details.try(&.as_h?).try(&.[key]?).try(&.as_s?) || ""
        end
        deposited = events.find(&.action.==("platform_deposited"))
        sent = events.reverse.find(&.action.==("pdf_copy_sent"))
        failed = events.reverse.find(&.action.==("pdf_copy_failed"))
        # Ordre des traces par identifiant : deux traces d'une même
        # transaction portent le même horodatage.
        failed = nil if failed && sent && sent.id!.to_i64 > failed.id!.to_i64
        Api::PdfCopyStatusView.new(
          eligible: eligible?(document), due: due?(document), deposited_at: deposited.try(&.created_at),
          sent_at: sent.try(&.created_at), sent_to: sent ? detail.call(sent, "to").split(", ").reject(&.empty?) : [] of String,
          sent_count: events.count(&.action.==("pdf_copy_sent")), failed_at: failed.try(&.created_at),
          error: failed ? detail.call(failed, "error") : "",
          error_detail: failed ? detail.call(failed, "detail") : "",
        )
      end

      # Premier envoi par la plateforme : la période vide est posée pour un
      # an à compter du jour, si l'option est active.
      def self.open_period! : Nil
        row = Settings.all.lock.first || Settings.new
        return unless row.pdf_copy_enabled.nil? || row.pdf_copy_enabled!
        return unless row.pdf_copy_from.nil? && row.pdf_copy_until.nil?
        today = Documents.today
        row.pdf_copy_from = today
        row.pdf_copy_until = today.shift(years: 1)
        row.save!
      end

      # PDF de la copie : mise en page du document, bandeau « Copie » sur
      # chaque page, sans XML Factur-X.
      def self.file(document : Document) : Api::FileView
        view = Documents.view(document)
        pdf = Output.render(view, Issuing.layout_for(document), copy: true).pdf
        name = Output.filename(view).rchop(".pdf")
        suffix = I18n.with_locale(view.locale) { I18n.t("invoicing.pdf_copy.file_suffix") }
        Api::FileView.new("#{name}-#{suffix}.pdf", "application/pdf", pdf)
      end

      # Envoie la copie par courriel et la trace ; `nil` si elle n'est pas
      # prévue (`due?`), sauf `force` (envoi demandé à l'écran).
      def self.send!(document : Document, actor : Partiduo::Api::Actor, input : Api::SendInput? = nil,
                     force : Bool = false) : Partiduo::Api::Result(Api::EmailLogView)?
        result = Partiduo::Api::Result(Api::EmailLogView)
        document_id = Documents.id_of(document.id)
        if force
          return result.failure(Documents.error(FieldError::BASE, "pdf_copy.not_platform")) unless eligible?(document)
        else
          return unless due?(document)
        end
        view = Documents.view(document)
        subject, body = I18n.with_locale(view.locale) do
          params = {"number" => view.number.to_s, "seller" => view.seller.name, "customer" => view.customer.name}
          {I18n.t("invoicing.pdf_copy.subject", params), I18n.t("invoicing.pdf_copy.body", params)}
        end
        input ||= Api::SendInput.new(to: [] of String)
        input = input.copy_with(subject: input.subject || subject, body: input.body || body)
        message, errors = Mail.compose(view, input) { file(document) }
        unless message
          log_failure(document_id, actor, errors.map(&.key).join(", "))
          return result.failure(errors)
        end
        log, error = Mail.deliver_and_log(message, document_id, nil, actor)
        if error
          # Transport absent : clé à part, le message technique reste en
          # détail (il n'est pas traduit).
          key = Mail.transport.configured? ? "mail.delivery_failed" : "mail.not_configured"
          log_failure(document_id, actor, "invoicing.errors.#{key}", error)
          return result.failure(Documents.error(FieldError::BASE, key, {"error" => error}))
        end
        Documents.log(document_id, "pdf_copy_sent", actor, "", {"to" => message.recipients.join(", ")})
        result.success(Mail.log_view(log))
      end

      # Une copie ne se fait que d'un document fiscal émis au canal `platform`.
      def self.eligible?(document : Document) : Bool
        !document.draft? && Channels.fiscal?(document.kind!) && document.issue_channel == "platform"
      end
    end
  end
end
