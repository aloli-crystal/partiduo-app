# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Canal d'émission des factures et marquage B2C (ADR-004 D9) : proposé selon
# le client, modifiable jusqu'à l'envoi, publié dans `invoice.issued`, sans
# aucune extension de facturation électronique.

private alias Api = Partiduo::Api::Invoicing

private def foreign_customer(email : String = "") : Partiduo::Api::Cards::CardView
  cards = Partiduo::Api::Cards
  category = cards.category_by_code(InvoicingSpec.system, "CUSTOMER") || raise "catégorie CUSTOMER absente"
  cards.create_card(InvoicingSpec.system, Partiduo::Api::Cards::CardInput.new(category_id: category.id, name: "Kunde GmbH",
    vat_number: "DE136695976", email: email,
    address: Partiduo::Api::Cards::AddressInput.new(line1: "Hauptstraße 1", postcode: "10115", city: "Berlin",
      country_code: "DE"))).value!
end

describe_module "INVOICING", "Facturation — canal d'émission (ADR-004 D9)" do
  describe ".propose_channel" do
    it "propose la plateforme à un professionnel français, le courriel ou le papier sinon" do
      setup = InvoicingSpec.setup
      pro = Api.propose_channel(InvoicingSpec.actor, setup.customer.id)
      {pro.channel, pro.b2c, pro.reason, pro.international}.should eq({"platform", false, "domestic_business", false})

      private_customer = Api.propose_channel(InvoicingSpec.actor, setup.private_customer.id)
      {private_customer.channel, private_customer.b2c, private_customer.reason}.should eq({"paper", true, "private_customer"})
      private_customer.reason_key.should eq("invoicing.channel_reasons.private_customer")

      foreign = Api.propose_channel(InvoicingSpec.actor, foreign_customer("buchhaltung@kunde.test").id)
      {foreign.channel, foreign.b2c, foreign.reason, foreign.international}.should eq({"email", false, "foreign_business", true})
    end

    it "propose la plateforme à un assujetti belge dans un dossier belge" do
      setup = InvoicingSpec.setup("be")
      Api.propose_channel(InvoicingSpec.actor, setup.customer.id).channel.should eq("platform")
      Api.propose_channel(InvoicingSpec.actor, setup.private_customer.id).b2c.should be_true
    end

    it "exige le droit de lecture" do
      setup = InvoicingSpec.setup
      expect_raises(Partiduo::Api::Forbidden) do
        Api.propose_channel(actor_with("invoicing.invoice.write"), setup.customer.id)
      end
    end
  end

  describe "brouillons" do
    it "porte la proposition par défaut, le canal saisi sinon, et le garde pour le même client" do
      setup = InvoicingSpec.setup
      draft = InvoicingSpec.draft(setup)
      {draft.issue_channel, draft.b2c}.should eq({"platform", false})
      draft.channel_key.should eq("invoicing.channels.platform")

      chosen = Api.update_document(InvoicingSpec.actor, draft.id,
        InvoicingSpec.document_input(setup, issue_channel: "paper")).value!
      chosen.issue_channel.should eq("paper")
      # Canal non repris dans la saisie : gardé pour le même client…
      Api.update_document(InvoicingSpec.actor, draft.id, InvoicingSpec.document_input(setup)).value!
        .issue_channel.should eq("paper")
      # … proposé à nouveau pour un autre client.
      other = Api.update_document(InvoicingSpec.actor, draft.id,
        InvoicingSpec.document_input(setup, customer_card_id: setup.private_customer.id)).value!
      {other.issue_channel, other.b2c}.should eq({"paper", true})
    end

    it "refuse un canal inconnu, et un canal sur un devis" do
      setup = InvoicingSpec.setup
      result = Api.create_document(InvoicingSpec.actor, InvoicingSpec.document_input(setup, issue_channel: "fax"))
      result.errors.map { |error| {error.field, error.key} }
        .should eq([{"issue_channel", "invoicing.errors.document.issue_channel.invalid"}])
      quote = Api.create_document(InvoicingSpec.actor, InvoicingSpec.document_input(setup, "quote", issue_channel: "email"))
      quote.error_keys.should eq(["invoicing.errors.document.issue_channel.fiscal_only"])
      InvoicingSpec.draft(setup, "quote").issue_channel.should eq("")
    end

    it "fait partir l'avoir par le canal de la facture qu'il corrige" do
      setup = InvoicingSpec.setup
      invoice = InvoicingSpec.issued(setup, issue_channel: "email", b2c: true)
      credit = Api.transform(InvoicingSpec.actor, invoice.id, Api::TransformInput.new("credit_note")).value!
      {credit.issue_channel, credit.b2c}.should eq({"email", true})
    end
  end

  describe ".set_issue_channel et .mark_sent" do
    it "change le canal d'une facture émise jusqu'à l'envoi, puis le fige (contrat et base)" do
      setup = InvoicingSpec.setup
      invoice = InvoicingSpec.issued(setup)
      invoice.channel_editable?.should be_true
      changed = Api.set_issue_channel(InvoicingSpec.actor, invoice.id, Api::ChannelInput.new("paper", b2c: true)).value!
      {changed.issue_channel, changed.b2c, changed.number}.should eq({"paper", true, invoice.number})
      Api.verify_fingerprint(InvoicingSpec.actor, invoice.id).should be_true
      Api.document_events(InvoicingSpec.actor, invoice.id).map(&.action).should contain("channel_changed")

      sent = Api.mark_sent(InvoicingSpec.actor, invoice.id).value!
      sent.sent_at.should_not be_nil
      sent.status.should eq("sent")
      sent.channel_editable?.should be_false
      Api.mark_sent(InvoicingSpec.actor, invoice.id).value!.sent_at.should eq(sent.sent_at)

      refused = Api.set_issue_channel(InvoicingSpec.actor, invoice.id, Api::ChannelInput.new("email"))
      refused.errors.map { |error| {error.field, error.key} }
        .should eq([{"issue_channel", "invoicing.errors.channel.already_sent"}])
      message = InvoicingSpec.sql_error("UPDATE invoicing_document SET issue_channel = 'email' WHERE id = $1", invoice.id)
      message.to_s.should contain("canal d'émission figé")
    end

    it "laisse la base modifier le canal d'une facture émise non envoyée, rien d'autre" do
      setup = InvoicingSpec.setup
      invoice = InvoicingSpec.issued(setup)
      InvoicingSpec.sql_error("UPDATE invoicing_document SET issue_channel = 'email', b2c = true WHERE id = $1",
        invoice.id).should be_nil
      InvoicingSpec.sql_error("UPDATE invoicing_document SET issue_channel = 'fax' WHERE id = $1", invoice.id)
        .to_s.should contain("invoicing_document_issue_channel_check")
      InvoicingSpec.sql_error("UPDATE invoicing_document SET notes = 'x' WHERE id = $1", invoice.id)
        .to_s.should contain("modification interdite")
    end

    it "refuse le canal d'un devis et l'envoi d'un brouillon ; exige les droits" do
      setup = InvoicingSpec.setup
      quote = InvoicingSpec.issued(setup, "quote")
      Api.set_issue_channel(InvoicingSpec.actor, quote.id, Api::ChannelInput.new("paper"))
        .error_keys.should eq(["invoicing.errors.channel.not_fiscal"])
      draft = InvoicingSpec.draft(setup)
      Api.mark_sent(InvoicingSpec.actor, draft.id).error_keys.should eq(["invoicing.errors.channel.draft"])
      Api.set_issue_channel(InvoicingSpec.actor, draft.id, Api::ChannelInput.new("email")).value!
        .issue_channel.should eq("email")
      expect_raises(Partiduo::Api::Forbidden) do
        Api.mark_sent(actor_with("invoicing.invoice.read", "invoicing.invoice.write"), draft.id)
      end
      expect_raises(Partiduo::Api::Forbidden) do
        Api.set_issue_channel(actor_with("invoicing.invoice.read"), draft.id, Api::ChannelInput.new("paper"))
      end
    end

    it "fige le canal à l'envoi par courriel" do
      setup = InvoicingSpec.setup
      transport = Api::MemoryTransport.new
      previous = Api.mail_transport
      Api.mail_transport = transport
      begin
        invoice = InvoicingSpec.issued(setup)
        Api.send_document(InvoicingSpec.actor, invoice.id, Api::SendInput.new(["compta@client.test"])).value!
        Api.document(InvoicingSpec.actor, invoice.id).channel_editable?.should be_false
      ensure
        Api.mail_transport = previous
      end
    end
  end

  it "publie le canal, le marquage B2C et le pays du client dans invoice.issued et credit_note.issued" do
    setup = InvoicingSpec.setup
    InvoicingSpec.capture("invoice.issued") do |events|
      InvoicingSpec.issued(setup, customer_card_id: setup.private_customer.id)
      payload = events.last.payload
      {payload["issue_channel"], payload["b2c"], payload["customer_country"]}.should eq({"paper", "true", "FR"})
    end
    invoice = InvoicingSpec.issued(setup)
    InvoicingSpec.capture("credit_note.issued") do |events|
      credit = Api.transform(InvoicingSpec.actor, invoice.id, Api::TransformInput.new("credit_note")).value!
      InvoicingSpec.issue(credit.id)
      {events.last.payload["issue_channel"], events.last.payload["b2c"]}.should eq({"platform", "false"})
    end
  end
end
