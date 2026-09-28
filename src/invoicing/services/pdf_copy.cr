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
    #   `pdf_copy_sent` / `pdf_copy_failed`), sans changer l'état du document.
    #
    # DECISIONS D-FIN-002.
    module PdfCopy
      alias Api = Partiduo::Api::Invoicing
      alias FieldError = Partiduo::Api::FieldError

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
          Documents.log(document_id, "pdf_copy_failed", actor, "", {"error" => errors.map(&.key).join(", ")})
          return result.failure(errors)
        end
        log, error = Mail.deliver_and_log(message, document_id, nil, actor)
        if error
          Documents.log(document_id, "pdf_copy_failed", actor, "", {"error" => error})
          return result.failure(Documents.error(FieldError::BASE, "mail.delivery_failed", {"error" => error}))
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
