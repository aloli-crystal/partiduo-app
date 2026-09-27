# SPDX-License-Identifier: AGPL-3.0-or-later

require "base64"
require "socket"
require "openssl"
require "uri"
require "random/secure"

module Partiduo
  module Invoicing
    # Envoi des documents et des relances par courriel (ADR-006 D5), tracé
    # sur le document (`EmailLog`). Le transport est configurable :
    #
    # * `SmtpTransport` — client SMTP minimal (EHLO, STARTTLS ou TLS direct,
    #   AUTH PLAIN, MAIL, RCPT, DATA), configuré par `PARTIDUO_SMTP_URL`
    #   (`smtp://utilisateur:secret@hôte:587?security=starttls`,
    #   `smtps://hôte:465`) ;
    # * `MemoryTransport` — garde les messages en mémoire (specs,
    #   développement) ;
    # * `DisabledTransport` — aucun envoi (défaut sans configuration).
    module Mail
      ADDRESS = /\A[^@\s<>,;"]+@[^@\s<>,;"]+\.[^@\s<>,;"]+\z/

      def self.valid_address?(address : String) : Bool
        address.matches?(ADDRESS)
      end

      class DeliveryError < Exception
      end

      record Attachment, filename : String, content_type : String, content : Bytes

      # Message prêt à partir ; `to_mime` produit le texte RFC 5322 (MIME,
      # UTF-8, pièces jointes en base64, lignes terminées par CRLF).
      class Message
        getter from : String
        getter from_name : String
        getter to : Array(String)
        getter cc : Array(String)
        getter subject : String
        getter body : String
        getter attachments : Array(Attachment)
        getter message_id : String
        getter date : Time

        def initialize(@from : String, @from_name : String, @to : Array(String), @cc : Array(String),
                       @subject : String, @body : String, @attachments = [] of Attachment,
                       @message_id = "<#{Random::Secure.hex(12)}@partiduo>", @date = Time.utc)
        end

        def recipients : Array(String)
          (to + cc).uniq
        end

        def self.encode_header(text : String) : String
          return text if text.ascii_only? && !text.includes?('\n')
          "=?UTF-8?B?#{Base64.strict_encode(text)}?="
        end

        def self.wrap(encoded : String) : String
          encoded.scan(/.{1,76}/).map(&.[0]).join("\r\n")
        end

        def to_mime : String
          boundary = "partiduo-#{Random::Secure.hex(12)}"
          String.build do |io|
            sender = from_name.empty? ? from : "#{Message.encode_header(from_name)} <#{from}>"
            io << "From: " << sender << "\r\n"
            io << "To: " << to.join(", ") << "\r\n"
            io << "Cc: " << cc.join(", ") << "\r\n" unless cc.empty?
            io << "Subject: " << Message.encode_header(subject) << "\r\n"
            io << "Date: " << date.to_rfc2822 << "\r\n"
            io << "Message-ID: " << message_id << "\r\n"
            io << "MIME-Version: 1.0\r\n"
            io << "Content-Type: multipart/mixed; boundary=\"" << boundary << "\"\r\n\r\n"
            io << "--" << boundary << "\r\n"
            io << "Content-Type: text/plain; charset=UTF-8\r\n"
            io << "Content-Transfer-Encoding: base64\r\n\r\n"
            io << Message.wrap(Base64.strict_encode(body)) << "\r\n"
            attachments.each do |attachment|
              io << "--" << boundary << "\r\n"
              io << "Content-Type: " << attachment.content_type << "; name=\"" << attachment.filename << "\"\r\n"
              io << "Content-Transfer-Encoding: base64\r\n"
              io << "Content-Disposition: attachment; filename=\"" << attachment.filename << "\"\r\n\r\n"
              io << Message.wrap(Base64.strict_encode(attachment.content)) << "\r\n"
            end
            io << "--" << boundary << "--\r\n"
          end
        end
      end

      abstract class Transport
        # Remet le message ; lève `DeliveryError` en cas de refus.
        abstract def deliver(message : Message) : Nil

        def configured? : Bool
          true
        end
      end

      class DisabledTransport < Transport
        def deliver(message : Message) : Nil
          raise DeliveryError.new("aucun transport de courriel configuré (PARTIDUO_SMTP_URL)")
        end

        def configured? : Bool
          false
        end
      end

      class MemoryTransport < Transport
        getter messages = [] of Message
        property failure : String? = nil

        def deliver(message : Message) : Nil
          if error = failure
            raise DeliveryError.new(error)
          end
          @messages << message
        end

        def clear : Nil
          @messages.clear
        end
      end

      class SmtpTransport < Transport
        enum Security
          None
          StartTls
          Tls
        end

        getter host : String
        getter port : Int32
        getter username : String?
        getter password : String?
        getter security : Security
        getter helo : String
        # Ouverture de la connexion, remplaçable (specs : dialogue simulé).
        property connector : Proc(IO)? = nil
        property timeout : Time::Span = 30.seconds

        def initialize(@host : String, @port : Int32 = 587, @username : String? = nil, @password : String? = nil,
                       @security : Security = Security::StartTls, @helo : String = "partiduo.localhost")
        end

        # `smtp://utilisateur:secret@hôte:587?security=starttls|none` ou
        # `smtps://hôte:465` (TLS direct).
        def self.from_url(url : String) : SmtpTransport
          uri = URI.parse(url)
          host = uri.host.presence || raise ArgumentError.new("URL SMTP sans hôte")
          tls = uri.scheme == "smtps"
          security = if tls
                       Security::Tls
                     else
                       case uri.query_params["security"]?
                       when "none" then Security::None
                       when "tls"  then Security::Tls
                       else             Security::StartTls
                       end
                     end
          helo = uri.query_params["helo"]? || "partiduo.localhost"
          new(host, uri.port || (tls ? 465 : 587), uri.user.try { |user| URI.decode(user) },
            uri.password.try { |secret| URI.decode(secret) }, security, helo)
        end

        def deliver(message : Message) : Nil
          io = open
          begin
            expect(io, [220])
            command(io, "EHLO #{helo}", [250])
            if security.start_tls?
              command(io, "STARTTLS", [220])
              io = upgrade(io)
              command(io, "EHLO #{helo}", [250])
            end
            if (user = username) && (secret = password)
              command(io, "AUTH PLAIN #{Base64.strict_encode("\0#{user}\0#{secret}")}", [235])
            end
            command(io, "MAIL FROM:<#{message.from}>", [250])
            message.recipients.each { |recipient| command(io, "RCPT TO:<#{recipient}>", [250, 251]) }
            command(io, "DATA", [354])
            message.to_mime.split("\r\n").each do |line|
              io << (line.starts_with?('.') ? ".#{line}" : line) << "\r\n"
            end
            io << ".\r\n"
            io.flush
            expect(io, [250])
            begin
              command(io, "QUIT", [221])
            rescue DeliveryError | IO::Error
            end
          ensure
            io.close rescue nil
          end
        end

        private def open : IO
          if connector = @connector
            return connector.call
          end
          socket = TCPSocket.new(host, port, connect_timeout: timeout)
          socket.read_timeout = timeout
          security.tls? ? upgrade(socket) : socket
        end

        private def upgrade(io : IO) : IO
          context = OpenSSL::SSL::Context::Client.new
          OpenSSL::SSL::Socket::Client.new(io, context: context, sync_close: true, hostname: host)
        end

        private def command(io : IO, line : String, codes : Array(Int32)) : String
          io << line << "\r\n"
          io.flush
          expect(io, codes)
        end

        private def expect(io : IO, codes : Array(Int32)) : String
          reply = String.build do |text|
            loop do
              line = io.gets(chomp: true) || raise DeliveryError.new("connexion SMTP fermée")
              text << line << '\n'
              break unless line.size > 3 && line[3] == '-'
            end
          end
          code = reply[0, 3].to_i? || 0
          raise DeliveryError.new("SMTP #{reply.strip}") unless codes.includes?(code)
          reply
        end
      end

      @@transport : Transport? = nil

      def self.transport : Transport
        @@transport ||= if url = ENV["PARTIDUO_SMTP_URL"]?.presence
                          SmtpTransport.from_url(url)
                        else
                          DisabledTransport.new
                        end
      end

      def self.transport=(transport : Transport?) : Transport?
        @@transport = transport
      end

      # Message d'envoi d'un document émis : destinataires (par défaut
      # l'adresse du client), expéditeur des paramètres (sinon celle de la
      # société), textes par défaut dans la langue du document, PDF joint.
      def self.compose(view : Partiduo::Api::Invoicing::DocumentView, input : Partiduo::Api::Invoicing::SendInput,
                       & : -> Partiduo::Api::Invoicing::FileView) : {Message?, Array(Partiduo::Api::FieldError)}
        errors = [] of Partiduo::Api::FieldError
        recipients = input.to.map(&.strip).reject(&.empty?)
        recipients = [view.customer.email] if recipients.empty? && !view.customer.email.empty?
        cc = input.cc.map(&.strip).reject(&.empty?)
        if recipients.empty?
          errors << Documents.error("to", "mail.no_recipient")
        elsif (recipients + cc).any? { |address| !valid_address?(address) }
          errors << Documents.error("to", "mail.invalid_address")
        end
        settings = Configuration.settings
        sender = settings.sender_email.presence || view.seller.email
        errors << Documents.error(Partiduo::Api::FieldError::BASE, "mail.no_sender") if sender.empty?
        errors << Documents.error(Partiduo::Api::FieldError::BASE, "mail.not_configured") unless transport.configured?
        return {nil, errors} unless errors.empty?

        params = {"kind" => I18n.with_locale(view.locale) { I18n.t(view.kind_key) }, "number" => view.number.to_s,
                  "seller" => view.seller.name, "customer" => view.customer.name,
                  "amount" => Output.format_amount(view.totals.payable, view.locale, view.currency_code),
                  "due_date" => Output.format_date(view.due_date, view.locale)}
        subject, body = I18n.with_locale(view.locale) do
          {input.subject || I18n.t("invoicing.mail.subject", params), input.body || I18n.t("invoicing.mail.body", params)}
        end
        pdf = yield
        message = Message.new(sender, settings.sender_name.presence || view.seller.name, recipients, cc, subject, body,
          [Attachment.new(pdf.filename, pdf.content_type, pdf.content)])
        {message, errors}
      end

      # Envoie, trace l'envoi (réussi ou non) et, s'il a réussi, marque le
      # document envoyé (une facture passe à l'état « envoyée »).
      def self.send_and_record(message : Message, document_id : Int64, reminder_id : Int64?,
                               actor : Partiduo::Api::Actor) : Partiduo::Api::Invoicing::EmailLogView
        log, error = deliver_and_log(message, document_id, reminder_id, actor)
        if error
          Documents.log(document_id, "email_failed", actor, "", {"error" => error})
        else
          document = Documents.find(document_id, lock: true)
          document.sent_at = Time.utc
          if Payments::PAYABLE_KINDS.includes?(document.kind)
            Payments.refresh_status(document)
          else
            document.save!
          end
          Documents.log(document_id, "emailed", actor, "", {"to" => message.recipients.join(", ")})
        end
        log_view(log)
      end

      # Envoie le message et en garde la trace sur le document ; un échec de
      # transport est tracé aussi (statut `failed`) puis signalé.
      def self.deliver_and_log(message : Message, document_id : Int64, reminder_id : Int64?,
                               actor : Partiduo::Api::Actor) : {EmailLog, String?}
        error = nil
        begin
          transport.deliver(message)
        rescue ex : DeliveryError | IO::Error | Socket::Error | OpenSSL::Error
          error = ex.message || ex.class.name
        end
        attachment = message.attachments.first?
        log = EmailLog.create!(
          document_id: document_id, reminder_id: reminder_id, recipients: message.recipients.join(", "),
          subject: message.subject[0, Math.min(255, message.subject.size)], body: message.body,
          attachment_name: attachment.try(&.filename) || "",
          attachment_sha256: attachment.try { |file| Digest::SHA256.hexdigest(file.content) } || "",
          message_id: message.message_id, status: error ? "failed" : "sent", error: error || "",
          sent_by_id: actor.user_id,
        )
        {log, error}
      end

      def self.log_view(log : EmailLog) : Partiduo::Api::Invoicing::EmailLogView
        Partiduo::Api::Invoicing::EmailLogView.new(
          id: Documents.id_of(log.id), document_id: Documents.id_of(log.document_id),
          reminder_id: log.reminder_id.try { |reminder_id| Documents.id_of(reminder_id) },
          recipients: log.recipients!.split(", "), subject: log.subject!, attachment_name: log.attachment_name.to_s,
          attachment_sha256: log.attachment_sha256.to_s, message_id: log.message_id.to_s, status: log.status!,
          error: log.error.to_s, sent_by_id: log.sent_by_id.try(&.to_i64), created_at: log.created_at!,
        )
      end
    end
  end
end
