# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# ADR-004 D9 révisé (28 septembre 2026) : nature du client explicite
# (particulier, professionnel, administration publique), qui commande le
# canal proposé, le marquage B2C et les mentions ; refus d'une facture à un
# professionnel établi en France sans SIREN ; copie PDF doublant l'envoi par
# la plateforme agréée (option datée du dossier, refus par client, bandeau
# « Copie », sans XML Factur-X, tracée). DECISIONS D-FIN-001 et D-FIN-002.

private alias Api = Partiduo::Api::Invoicing
private alias Cards = Partiduo::Api::Cards

private def customer_category : Cards::CategoryView
  Cards.category_by_code(InvoicingSpec.system, "CUSTOMER") || raise "catégorie CUSTOMER absente"
end

private def customer(name : String, **options) : Cards::CardView
  input = Cards::CardInput.new(category_id: customer_category.id, name: name,
    address: Cards::AddressInput.new(line1: "1 rue Neuve", postcode: "75001", city: "Paris", country_code: "FR"))
  result = Cards.create_card(InvoicingSpec.system, input.copy_with(**options))
  raise "fiche refusée : #{result.error_keys.join(", ")}" if result.failure?
  result.value!
end

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

describe_module "INVOICING", "Facturation — nature du client et copie PDF (ADR-004 D9 révisé)" do
  describe "nature du client (fiche)" do
    it "propose la nature d'après le SIREN et le numéro de TVA, sans l'enregistrer" do
      Cards.propose_nature("", "").should eq("individual")
      Cards.propose_nature("443061841", "").should eq("business")
      Cards.propose_nature("", "DE136695976").should eq("business")
      Cards.propose_nature("217500016", "").should eq("public")
      Cards.propose_nature("", InvoicingSpec.fr_vat("217500016")).should eq("public")

      InvoicingSpec.setup
      card = customer("Mairie", siren: "217500016")
      card.customer_nature.should eq("")
      card.proposed_nature.should eq("public")
      card.effective_nature.should eq("public")
      card.customer_nature_key.should be_nil
    end

    it "enregistre la nature choisie, la garde sans saisie, la refuse hors des fiches de client" do
      InvoicingSpec.setup
      card = customer("Paul Durand", siren: "443061841", customer_nature: "individual")
      card.customer_nature.should eq("individual")
      card.customer_nature_key.should eq("cards.natures.individual")
      card.effective_nature.should eq("individual")

      kept = Cards.update_card(InvoicingSpec.system, card.id, card.to_input.copy_with(customer_nature: nil)).value!
      kept.customer_nature.should eq("individual")
      cleared = Cards.update_card(InvoicingSpec.system, card.id, card.to_input.copy_with(customer_nature: "")).value!
      cleared.customer_nature.should eq("")

      invalid = Cards.create_card(InvoicingSpec.system, Cards::CardInput.new(category_id: customer_category.id,
        name: "X", customer_nature: "company"))
      invalid.error_keys.should eq(["cards.errors.card.customer_nature.invalid"])
      supplier = Cards.category_by_code(InvoicingSpec.system, "SUPPLIER") || raise "catégorie SUPPLIER absente"
      refused = Cards.create_card(InvoicingSpec.system, Cards::CardInput.new(category_id: supplier.id,
        name: "Fournisseur", customer_nature: "business"))
      refused.error_keys.should eq(["cards.errors.card.customer_nature.not_applicable"])
    end
  end

  describe "canal, mentions et validation" do
    it "suit la nature choisie plutôt que les identifiants" do
      InvoicingSpec.setup
      individual = customer("Paul Durand", siren: "443061841", email: "paul@exemple.test",
        customer_nature: "individual")
      proposal = Api.propose_channel(InvoicingSpec.actor, individual.id)
      {proposal.channel, proposal.b2c, proposal.reason}.should eq({"email", true, "private_customer"})

      public_body = customer("Ville de Paris", siren: "217500016", customer_nature: "public")
      proposal = Api.propose_channel(InvoicingSpec.actor, public_body.id)
      {proposal.channel, proposal.b2c, proposal.reason}.should eq({"chorus_pro", false, "public_customer"})
      proposal.reason_key.should eq("invoicing.channel_reasons.public_customer")
    end

    it "fige la nature dans l'identité du client et en tire l'indemnité forfaitaire" do
      setup = InvoicingSpec.setup
      individual = customer("Paul Durand", siren: "443061841", customer_nature: "individual")
      invoice = InvoicingSpec.issued(setup, customer_card_id: individual.id)
      invoice.customer.nature.should eq("individual")
      invoice.customer.professional?.should be_false
      InvoicingSpec.codes(invoice).should_not contain("payment.indemnity")
      InvoicingSpec.codes(invoice).should contain("customer.siren")

      business = InvoicingSpec.issued(setup)
      business.customer.nature.should eq("business")
      InvoicingSpec.codes(business).should contain("payment.indemnity")
      Api.verify_fingerprint(InvoicingSpec.actor, business.id).should be_true
    end

    it "refuse d'émettre une facture à un professionnel établi en France sans SIREN" do
      setup = InvoicingSpec.setup
      business = customer("Atelier sans SIREN", customer_nature: "business")
      draft = InvoicingSpec.draft(setup, customer_card_id: business.id)
      result = Api.issue(InvoicingSpec.actor, draft.id, Api::IssueInput.new(issue_date: InvoicingSpec.date("2026-09-15")))
      result.errors.map { |error| {error.field, error.key} }
        .should eq([{"customer_card_id", "invoicing.errors.issue.customer_siren_required"}])

      # Un devis n'est pas concerné ; une fiche sans nature n'est pas jugée
      # en silence.
      InvoicingSpec.issued(setup, "quote", customer_card_id: business.id).number.should_not be_nil
      unknown = customer("Client sans nature")
      InvoicingSpec.issued(setup, customer_card_id: unknown.id).number.should_not be_nil
    end
  end

  describe "copie PDF doublant la plateforme" do
    it "part au premier envoi par la plateforme, ouvre la période d'un an et se trace" do
      setup = InvoicingSpec.setup
      with_memory_transport do |transport|
        invoice = InvoicingSpec.issued(setup)
        invoice.issue_channel.should eq("platform")
        Api.pdf_copy_due?(InvoicingSpec.actor, invoice.id).should be_true
        Api.mark_sent(InvoicingSpec.actor, invoice.id).value!

        transport.messages.size.should eq(1)
        message = transport.messages.first
        message.to.should eq(["compta@client.test"])
        message.subject.should contain("Copie")
        attachment = message.attachments.first
        attachment.filename.should eq("#{invoice.number}-copie.pdf")
        # Pas de XML Factur-X : la copie ne passe pas pour un original.
        String.new(attachment.content).should_not contain("factur-x.xml")
        Partiduo::Invoicing::Output.check(attachment.content).should be_empty

        Api.document_events(InvoicingSpec.actor, invoice.id).map(&.action).should contain("pdf_copy_sent")
        Api.email_logs(InvoicingSpec.actor, invoice.id).map(&.status).should eq(["sent"])
        settings = Api.settings(InvoicingSpec.actor)
        today = Partiduo::Config.today
        settings.pdf_copy_from.should eq(today)
        settings.pdf_copy_until.should eq(today.shift(years: 1))
        Api.document(InvoicingSpec.actor, invoice.id).status.should eq("sent")
      end
    end

    it "ne part pas pour un client qui la refuse, ni hors de la période ; se renvoie à la demande" do
      setup = InvoicingSpec.setup
      with_memory_transport do |transport|
        refusing = Cards.update_card(InvoicingSpec.system, setup.customer.id,
          setup.customer.to_input.copy_with(pdf_copy: false)).value!
        refusing.pdf_copy.should be_false
        invoice = InvoicingSpec.issued(setup)
        Api.pdf_copy_due?(InvoicingSpec.actor, invoice.id).should be_false
        Api.mark_sent(InvoicingSpec.actor, invoice.id).value!
        transport.messages.should be_empty

        Cards.update_card(InvoicingSpec.system, setup.customer.id, refusing.to_input.copy_with(pdf_copy: true)).value!
        past = InvoicingSpec.date("2025-01-01")
        input = Api.settings(InvoicingSpec.actor).to_input
          .copy_with(pdf_copy_from: past, pdf_copy_until: past.shift(years: 1))
        Api.update_settings(InvoicingSpec.actor, input).value!
        later = InvoicingSpec.issued(setup)
        Api.pdf_copy_due?(InvoicingSpec.actor, later.id).should be_false
        Api.mark_sent(InvoicingSpec.actor, later.id).value!
        transport.messages.should be_empty

        # Envoi demandé : hors période, il part quand même, tracé.
        Api.send_pdf_copy(InvoicingSpec.actor, later.id).value!.status.should eq("sent")
        transport.messages.size.should eq(1)
        Api.document_pdf_copy(InvoicingSpec.actor, later.id).filename.should eq("#{later.number}-copie.pdf")
      end
    end

    it "refuse la copie d'un document hors plateforme et une période inversée ; exige le droit d'envoi" do
      setup = InvoicingSpec.setup
      paper = InvoicingSpec.issued(setup, issue_channel: "paper")
      Api.send_pdf_copy(InvoicingSpec.actor, paper.id).error_keys.should eq(["invoicing.errors.pdf_copy.not_platform"])
      expect_raises(Partiduo::Api::NotFound) { Api.document_pdf_copy(InvoicingSpec.actor, paper.id) }

      input = Api.settings(InvoicingSpec.actor).to_input
        .copy_with(pdf_copy_from: InvoicingSpec.date("2027-01-01"), pdf_copy_until: InvoicingSpec.date("2026-01-01"))
      Api.update_settings(InvoicingSpec.actor, input).errors.map { |error| {error.field, error.key} }
        .should eq([{"pdf_copy_until", "invoicing.errors.settings.pdf_copy_period"}])

      platform = InvoicingSpec.issued(setup)
      expect_raises(Partiduo::Api::Forbidden) do
        Api.send_pdf_copy(actor_with("invoicing.invoice.read"), platform.id)
      end
    end
  end
end
