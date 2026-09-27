# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias Api = Partiduo::Api::Invoicing

private def with_memory_transport(&)
  transport = Api::MemoryTransport.new
  previous = Api.mail_transport
  Api.mail_transport = transport
  begin
    yield transport
  ensure
    Api.mail_transport = previous
  end
end

# Faux serveur SMTP sur une paire de tubes : dialogue scripté, transcription
# et message reçu.
private class FakeSmtpServer
  getter commands = [] of String
  getter data = ""

  def initialize(@io : IO)
  end

  def run : Nil
    reply "220 fake.test ESMTP"
    while line = @io.gets(chomp: true)
      @commands << line
      case line
      when .starts_with?("EHLO") then reply "250-fake.test\r\n250 AUTH PLAIN"
      when .starts_with?("AUTH") then reply "235 2.7.0 ok"
      when .starts_with?("MAIL") then reply "250 ok"
      when .starts_with?("RCPT") then line.includes?("refuse@") ? reply("550 no such user") : reply("250 ok")
      when "DATA"
        reply "354 go"
        body = String::Builder.new
        while (text = @io.gets(chomp: true)) && text != "."
          body << text << "\n"
        end
        @data = body.to_s
        reply "250 queued"
      when "QUIT"
        reply "221 bye"
        break
      else reply "500 ?"
      end
    end
    @io.close
  end

  private def reply(text : String) : Nil
    @io << text << "\r\n"
    @io.flush
  end
end

# Transport qui s'arrête au milieu de l'envoi jusqu'à ce qu'on le libère :
# deux validations simultanées d'une même relance.
private class GateTransport < Api::MailTransport
  getter messages = [] of Api::MailMessage

  def initialize(@entered : Channel(Nil), @release : Channel(Nil))
  end

  def deliver(message : Api::MailMessage) : Nil
    @entered.send(nil)
    @release.receive
    @messages << message
  end
end

describe_module "INVOICING", "Facturation — envoi par courriel" do
  it "envoie le PDF Factur-X au client, trace l'envoi et passe la facture à « envoyée »" do
    with_memory_transport do |transport|
      setup = InvoicingSpec.setup
      invoice = InvoicingSpec.issued(setup)
      log = Api.send_document(InvoicingSpec.actor, invoice.id, Api::SendInput.new(to: [] of String,
        cc: ["associe@exemple.test"])).value!
      log.status.should eq("sent")
      log.recipients.should eq(["compta@client.test", "associe@exemple.test"])
      log.attachment_name.should eq("F-2026-0001.pdf")
      transport.messages.size.should eq(1)
      message = transport.messages.first
      message.subject.should eq("Facture F-2026-0001 — Exemple SARL")
      message.from.should eq("factures@exemple.test")
      pdf = message.attachments.first
      log.attachment_sha256.should eq(Digest::SHA256.hexdigest(pdf.content))
      pdf.content.should eq(Api.document_pdf(InvoicingSpec.actor, invoice.id).content)
      mime = message.to_mime
      mime.should contain("Content-Type: application/pdf; name=\"F-2026-0001.pdf\"")
      mime.should contain("Subject: =?UTF-8?B?")
      sent = Api.document(InvoicingSpec.actor, invoice.id)
      sent.status.should eq("sent")
      sent.sent_at.should_not be_nil
      Api.email_logs(InvoicingSpec.actor, invoice.id).size.should eq(1)
      Api.document_events(InvoicingSpec.actor, invoice.id).map(&.action).should contain("emailed")
      Api.verify_fingerprint(InvoicingSpec.actor, invoice.id).should be_true
    end
  end

  it "trace un échec du transport et refuse un brouillon ou une adresse invalide" do
    with_memory_transport do |transport|
      setup = InvoicingSpec.setup
      invoice = InvoicingSpec.issued(setup)
      transport.failure = "550 boîte pleine"
      result = Api.send_document(InvoicingSpec.actor, invoice.id, Api::SendInput.new(to: ["x@client.test"]))
      result.error_keys.should eq(["invoicing.errors.mail.delivery_failed"])
      Api.email_logs(InvoicingSpec.actor, invoice.id).map(&.status).should eq(["failed"])
      Api.document(InvoicingSpec.actor, invoice.id).status.should eq("issued")
      draft = InvoicingSpec.draft(setup)
      Api.send_document(InvoicingSpec.actor, draft.id, Api::SendInput.new(to: ["x@client.test"]))
        .error_keys.should eq(["invoicing.errors.mail.draft"])
      Api.send_document(InvoicingSpec.actor, invoice.id, Api::SendInput.new(to: ["pas une adresse"]))
        .error_keys.should eq(["invoicing.errors.mail.invalid_address"])
    end
    Api.mail_transport = Partiduo::Invoicing::Mail::DisabledTransport.new
    setup_invoice = Partiduo::Invoicing::Document.all.first!
    Api.send_document(InvoicingSpec.actor, setup_invoice.id.as(Int).to_i64, Api::SendInput.new(to: ["x@client.test"]))
      .error_keys.should eq(["invoicing.errors.mail.not_configured"])
    Api.mail_transport = nil
  end

  it "dialogue avec un serveur SMTP (EHLO, AUTH PLAIN, MAIL, RCPT, DATA, QUIT)" do
    client, server_io = IO::Stapled.pipe
    server = FakeSmtpServer.new(server_io)
    spawn { server.run }
    transport = Api::SmtpTransport.from_url("smtp://factures%40exemple.test:s3cret@smtp.exemple.test:587?security=none")
    transport.port.should eq(587)
    transport.username.should eq("factures@exemple.test")
    transport.connector = -> { client.as(IO) }
    message = Api::MailMessage.new("factures@exemple.test", "Exemple SARL", ["compta@client.test"], [] of String,
      "Facture F-2026-0001", "Bonjour,\n.\nVoici la facture.",
      [Partiduo::Invoicing::Mail::Attachment.new("F-2026-0001.pdf", "application/pdf", "%PDF-1.7".to_slice)])
    transport.deliver(message)
    server.commands.first.should eq("EHLO partiduo.localhost")
    server.commands.should contain("AUTH PLAIN #{Base64.strict_encode("\0factures@exemple.test\0s3cret")}")
    server.commands.should contain("MAIL FROM:<factures@exemple.test>")
    server.commands.should contain("RCPT TO:<compta@client.test>")
    server.commands.last.should eq("QUIT")
    server.data.should contain("Message-ID: #{message.message_id}")
    server.data.should contain("Content-Disposition: attachment; filename=\"F-2026-0001.pdf\"")

    client2, server_io2 = IO::Stapled.pipe
    spawn { FakeSmtpServer.new(server_io2).run }
    transport.connector = -> { client2.as(IO) }
    refused = Api::MailMessage.new("factures@exemple.test", "", ["refuse@client.test"], [] of String, "x", "y")
    expect_raises(Partiduo::Invoicing::Mail::DeliveryError, /550/) { transport.deliver(refused) }
    Api::SmtpTransport.from_url("smtps://smtp.exemple.test").security.tls?.should be_true
  end
end

describe_module "INVOICING", "Facturation — relances" do
  it "propose les relances des factures échues, par niveau, sans rien envoyer" do
    with_memory_transport do |transport|
      setup = InvoicingSpec.setup
      Api.update_settings(InvoicingSpec.actor, Api.settings(InvoicingSpec.actor).to_input
        .copy_with(late_penalty_rate: BigDecimal.new("10"))).value!
      invoice = InvoicingSpec.issued(setup, on: "2026-07-01") # échéance 31/07/2026
      private_invoice = InvoicingSpec.issued(setup, on: "2026-07-02", customer_card_id: setup.private_customer.id)
      InvoicingSpec.issued(setup, on: "2026-09-15") # pas encore échue

      Api.propose_reminders(InvoicingSpec.actor, InvoicingSpec.date("2026-08-02")).should be_empty
      first = Api.propose_reminders(InvoicingSpec.actor, InvoicingSpec.date("2026-08-10"))
      first.map { |reminder| {reminder.document_number, reminder.level} }
        .should eq([{"F-2026-0001", 1}, {"F-2026-0002", 1}])
      first.first.interest.should eq(BigDecimal.new(0)) # pénalités à partir du niveau 2
      Api.propose_reminders(InvoicingSpec.actor, InvoicingSpec.date("2026-08-10")).should be_empty
      transport.messages.should be_empty

      second = Api.propose_reminders(InvoicingSpec.actor, InvoicingSpec.date("2026-09-05"))
      pro = second.find! { |reminder| reminder.document_id == invoice.id }
      pro.level.should eq(2)
      pro.days_late.should eq(36)
      pro.interest.should eq(BigDecimal.new("10.06")) # 1 019,76 × 10 % × 36 / 365
      pro.indemnity.should eq(BigDecimal.new("40"))
      second.find! { |reminder| reminder.document_id == private_invoice.id }.indemnity.should eq(BigDecimal.new(0))
      Api.reminders(InvoicingSpec.actor).size.should eq(4)
      transport.messages.should be_empty

      sent = Api.send_reminder(InvoicingSpec.actor, pro.id).value!
      sent.status.should eq("sent")
      transport.messages.size.should eq(1)
      transport.messages.first.subject.should eq("Deuxième rappel : facture F-2026-0001 impayée")
      transport.messages.first.body.should contain("indemnité forfaitaire pour frais de recouvrement : 40,00")
      Api.send_reminder(InvoicingSpec.actor, pro.id).error_keys.should eq(["invoicing.errors.reminder.not_proposed"])
      other = Api.reminders(InvoicingSpec.actor).find! { |reminder| reminder.document_id == private_invoice.id && reminder.level == 2 }
      Api.dismiss_reminder(InvoicingSpec.actor, other.id).value!.status.should eq("dismissed")
      Api.email_logs(InvoicingSpec.actor, invoice.id).first.reminder_id.should eq(pro.id)

      # Une facture payée n'est plus relancée (règlement saisi : Comptabilité inactive).
      unless Partiduo::Modules.active?("ACCOUNTING")
        Api.record_payment(InvoicingSpec.actor, Api::PaymentInput.new(document_id: invoice.id,
          amount: invoice.totals.total_gross, paid_on: InvoicingSpec.date("2026-09-10"))).value!
        Api.propose_reminders(InvoicingSpec.actor, InvoicingSpec.date("2026-12-01"))
          .map(&.document_id).should_not contain(invoice.id)
      end
    end
  end

  it "réserve la relance avant l'envoi : deux validations simultanées n'envoient qu'un courriel (D-2F-008)" do
    setup = InvoicingSpec.setup
    InvoicingSpec.issued(setup, on: "2026-07-01")
    reminder = Api.propose_reminders(InvoicingSpec.actor, InvoicingSpec.date("2026-08-10")).first
    entered = Channel(Nil).new
    release = Channel(Nil).new
    transport = GateTransport.new(entered, release)
    previous = Api.mail_transport
    Api.mail_transport = transport
    begin
      done = Channel(Partiduo::Api::Result(Api::ReminderView) | Exception).new
      spawn do
        done.send(Api.send_reminder(InvoicingSpec.actor, reminder.id))
      rescue ex
        done.send(ex)
      end
      entered.receive # le premier envoi est en cours, sa réservation validée
      Partiduo::Invoicing::Reminder.filter(id: reminder.id).first!.status.should eq("sending")
      second = Api.send_reminder(InvoicingSpec.actor, reminder.id)
      second.error_keys.should eq(["invoicing.errors.reminder.in_progress"])
      ReferentialSpec.expect_translated(second)
      release.send(nil)
      first = done.receive
      raise first if first.is_a?(Exception)
      first.value!.status.should eq("sent")
      transport.messages.size.should eq(1)
      Api.email_logs(InvoicingSpec.actor, reminder.document_id).size.should eq(1)
    ensure
      Api.mail_transport = previous
    end
  end

  it "rend la relance proposée quand l'envoi échoue, et reprend une réservation abandonnée" do
    with_memory_transport do |transport|
      setup = InvoicingSpec.setup
      InvoicingSpec.issued(setup, on: "2026-07-01")
      reminder = Api.propose_reminders(InvoicingSpec.actor, InvoicingSpec.date("2026-08-10")).first
      transport.failure = "421 plus tard"
      Api.send_reminder(InvoicingSpec.actor, reminder.id).error_keys.should eq(["invoicing.errors.mail.delivery_failed"])
      Api.reminders(InvoicingSpec.actor).map(&.id).should eq([reminder.id])

      # Réservation abandonnée (processus interrompu) : reprise après le délai.
      transport.failure = nil
      InvoicingSpec.sql_error("UPDATE invoicing_reminder SET status = 'sending', updated_at = now() WHERE id = $1",
        reminder.id).should be_nil
      Api.send_reminder(InvoicingSpec.actor, reminder.id).error_keys.should eq(["invoicing.errors.reminder.in_progress"])
      InvoicingSpec.sql_error("UPDATE invoicing_reminder SET updated_at = now() - interval '1 hour' WHERE id = $1",
        reminder.id).should be_nil
      Api.send_reminder(InvoicingSpec.actor, reminder.id).value!.status.should eq("sent")
      transport.messages.size.should eq(1)
    end
  end
end
