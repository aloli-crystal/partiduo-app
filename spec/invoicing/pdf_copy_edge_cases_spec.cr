# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Lot C (testeur) : cas limites de la copie PDF doublant le dépôt sur la
# plateforme (`invoice.platform_deposited`), du canal `public_portal`, de la
# nature du client et de la saisie express d'un particulier (ADR-004 D9
# révisé ; DECISIONS D-FIN-001, D-FIN-002, D-CPY-001 à D-CPY-004).
#
# L'application d'origine n'a ni plateforme agréée ni copie PDF : les règles viennent de
# l'ADR ; la saisie express reprend les contrôles de `Fiche::insert`
# (nom obligatoire, courriel valide), déjà portés par `create_card`.

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

private def with_transport(&)
  transport = Api::MemoryTransport.new
  previous = Api.mail_transport
  Api.mail_transport = transport
  begin
    yield transport
  ensure
    Api.mail_transport = previous
  end
end

# Transport qui lève une exception autre que `DeliveryError` (erreur de
# configuration, de programmation…).
private class BrokenTransport < Partiduo::Invoicing::Mail::Transport
  def deliver(message : Partiduo::Invoicing::Mail::Message) : Nil
    raise ArgumentError.new("URL SMTP sans hôte")
  end
end

private def deposit(id : Int64) : Nil
  Partiduo::Events.publish("invoice.platform_deposited", {"invoice_id" => id.to_s, "platform_ref" => "PA-#{id}",
                                                          "connector" => "spec"})
end

private def actions(id : Int64) : Array(String)
  Api.document_events(InvoicingSpec.actor, id).map(&.action)
end

private def all_modules_but(code : String) : String
  Partiduo::Config.active_module_codes.reject(&.==(code.downcase)).join(",")
end

describe_module "INVOICING", "Facturation — copie PDF après dépôt : cas limites (lot C)" do
  describe "dépôt sur la plateforme" do
    it "trace le dépôt avec sa référence et marque envoyé, sans rien faire d'un brouillon" do
      setup = InvoicingSpec.setup
      with_transport do |transport|
        draft = InvoicingSpec.draft(setup)
        deposit(draft.id)
        Api.document(InvoicingSpec.actor, draft.id).status.should eq("draft")
        actions(draft.id).should_not contain("platform_deposited")
        transport.messages.should be_empty

        invoice = InvoicingSpec.issued(setup)
        deposit(invoice.id)
        event = Api.document_events(InvoicingSpec.actor, invoice.id).find!(&.action.==("platform_deposited"))
        event.details["platform_ref"]?.should eq("PA-#{invoice.id}")
        event.details["connector"]?.should eq("spec")
        actions(invoice.id).should contain("marked_sent")
        Api.document(InvoicingSpec.actor, invoice.id).channel_editable?.should be_false
      end
    end

    it "double aussi l'avoir déposé, sous le nom de fichier de la copie" do
      setup = InvoicingSpec.setup
      with_transport do |transport|
        invoice = InvoicingSpec.issued(setup)
        credit = Api.transform(InvoicingSpec.actor, invoice.id, Api::TransformInput.new("credit_note")).value!
        credit = InvoicingSpec.issue(credit.id)
        credit.issue_channel.should eq("platform")
        deposit(credit.id)
        transport.messages.size.should eq(1)
        transport.messages.first.attachments.first.filename.should eq("#{credit.number}-copie.pdf")
        Api.pdf_copy_status(InvoicingSpec.actor, credit.id).sent_count.should eq(1)
      end
    end

    it "ignore le dépôt signalé d'un document émis hors plateforme : ni envoyé, ni doublé, anomalie tracée" do
      setup = InvoicingSpec.setup
      with_transport do |transport|
        invoice = InvoicingSpec.issued(setup, issue_channel: "email")
        deposit(invoice.id)
        transport.messages.should be_empty
        actions(invoice.id).should contain("platform_deposit_ignored")
        actions(invoice.id).should_not contain("platform_deposited")
        actions(invoice.id).should_not contain("marked_sent")
        document = Api.document(InvoicingSpec.actor, invoice.id)
        {document.sent_at, document.channel_editable?}.should eq({nil, true})
        Api.pdf_copy_status(InvoicingSpec.actor, invoice.id).deposited_at.should be_nil
        status = Api.pdf_copy_status(InvoicingSpec.actor, invoice.id)
        {status.eligible, status.due, status.sent_count}.should eq({false, false, 0})
        Api.settings(InvoicingSpec.actor).pdf_copy_from.should be_nil
        # L'original reste le PDF envoyé par courriel.
        Api.send_document(InvoicingSpec.actor, invoice.id, Api::SendInput.new(to: [] of String)).value!
        transport.messages.first.attachments.first.filename.should_not contain("copie")
      end
    end

    it "suit la langue du document : sujet et nom de fichier en anglais et en néerlandais" do
      setup = InvoicingSpec.setup
      with_transport do |transport|
        {"en" => {"Copy of invoice", "copy"}, "nl" => {"Kopie van factuur", "kopie"}}.each do |locale, (subject, suffix)|
          invoice = InvoicingSpec.issued(setup, locale: locale)
          deposit(invoice.id)
          message = transport.messages.last
          message.subject.should start_with(subject)
          message.attachments.first.filename.should eq("#{invoice.number}-#{suffix}.pdf")
        end
        transport.messages.size.should eq(2)
      end
    end

    it "ouvre la période sans envoyer pour un client sans courriel ; ne l'ouvre pas si l'option est coupée" do
      setup = InvoicingSpec.setup
      with_transport do |transport|
        silent = customer("Atelier sans courriel", siren: "552100554", customer_nature: "business")
        invoice = InvoicingSpec.issued(setup, customer_card_id: silent.id)
        Api.pdf_copy_due?(InvoicingSpec.actor, invoice.id).should be_false
        deposit(invoice.id)
        transport.messages.should be_empty
        Api.settings(InvoicingSpec.actor).pdf_copy_from.should eq(Partiduo::Config.today)
        # Envoi demandé : sans adresse, refus traduit et tracé.
        result = Api.send_pdf_copy(InvoicingSpec.actor, invoice.id)
        result.failure?.should be_true
        ReferentialSpec.expect_translated(result)
        actions(invoice.id).should contain("pdf_copy_failed")
        # Motif : clés de traduction du contrat (D-CPY-006).
        Api.pdf_copy_status(InvoicingSpec.actor, invoice.id).error.should contain("invoicing.errors.mail.no_recipient")
      end
    end

    it "ne pose pas la période et n'envoie rien quand l'option du dossier est coupée" do
      setup = InvoicingSpec.setup
      with_transport do |transport|
        Api.update_settings(InvoicingSpec.actor, Api.settings(InvoicingSpec.actor).to_input
          .copy_with(pdf_copy_enabled: false)).value!
        invoice = InvoicingSpec.issued(setup)
        Api.pdf_copy_due?(InvoicingSpec.actor, invoice.id).should be_false
        deposit(invoice.id)
        transport.messages.should be_empty
        settings = Api.settings(InvoicingSpec.actor)
        {settings.pdf_copy_from, settings.pdf_copy_until}.should eq({nil, nil})
        Api.document(InvoicingSpec.actor, invoice.id).status.should eq("sent")
      end
    end

    it "trace l'échec du transport sans bloquer le dépôt, puis l'efface d'un envoi réussi" do
      setup = InvoicingSpec.setup
      with_transport do |transport|
        invoice = InvoicingSpec.issued(setup)
        transport.failure = "421 plus tard"
        deposit(invoice.id)
        Api.document(InvoicingSpec.actor, invoice.id).status.should eq("sent")
        actions(invoice.id).should contain("pdf_copy_failed")
        status = Api.pdf_copy_status(InvoicingSpec.actor, invoice.id)
        status.failed_at.should_not be_nil
        # Motif : clé de traduction, détail du serveur à part (D-CPY-007).
        {status.error, status.error_detail}.should eq({"invoicing.errors.mail.delivery_failed", "421 plus tard"})
        {status.sent_at, status.sent_count}.should eq({nil, 0})

        # Un second dépôt ne rejoue pas la copie : elle se renvoie à la main.
        transport.failure = nil
        deposit(invoice.id)
        transport.messages.should be_empty
        Api.send_pdf_copy(InvoicingSpec.actor, invoice.id).value!
        status = Api.pdf_copy_status(InvoicingSpec.actor, invoice.id)
        {status.failed_at, status.error, status.sent_count}.should eq({nil, "", 1})
      end
    end

    it "trace sans la propager une exception quelconque du transport après le dépôt" do
      setup = InvoicingSpec.setup
      previous = Api.mail_transport
      Api.mail_transport = BrokenTransport.new
      begin
        invoice = InvoicingSpec.issued(setup)
        deposit(invoice.id)
        Api.document(InvoicingSpec.actor, invoice.id).status.should eq("sent")
        status = Api.pdf_copy_status(InvoicingSpec.actor, invoice.id)
        {status.error, status.error_detail}.should eq({"invoicing.errors.pdf_copy.internal", "URL SMTP sans hôte"})
        I18n.t(status.error, {"detail" => status.error_detail}).should_not contain("invoicing.errors")
      ensure
        Api.mail_transport = previous
      end
    end

    it "efface l'échec d'un envoi réussi tracé dans la même transaction (ordre des identifiants)" do
      setup = InvoicingSpec.setup
      invoice = InvoicingSpec.issued(setup)
      deposit(invoice.id)
      system = Partiduo::Api::Actor.system
      Marten::DB::Connection.default.transaction do
        Partiduo::Invoicing::PdfCopy.log_failure(invoice.id, system, "invoicing.errors.mail.delivery_failed", "421")
        Partiduo::Invoicing::Documents.log(invoice.id, "pdf_copy_sent", system, "", {"to" => "a@example.test"})
      end
      status = Api.pdf_copy_status(InvoicingSpec.actor, invoice.id)
      {status.failed_at, status.error, status.sent_to}.should eq({nil, "", ["a@example.test"]})
    end

    it "joint la copie, jamais l'original, à la relance d'une facture déposée" do
      setup = InvoicingSpec.setup
      with_transport do |transport|
        invoice = InvoicingSpec.issued(setup, on: "2026-07-01")
        deposit(invoice.id)
        transport.clear
        reminder = Api.propose_reminders(InvoicingSpec.actor, InvoicingSpec.date("2026-08-10"))
          .find! { |proposed| proposed.document_id == invoice.id }
        Api.send_reminder(InvoicingSpec.actor, reminder.id).value!
        transport.messages.size.should eq(1)
        transport.messages.first.attachments.first.filename.should eq("#{invoice.number}-copie.pdf")
      end
    end

    it "refuse un dépôt incomplet ou d'un document inconnu" do
      InvoicingSpec.setup
      expect_raises(ArgumentError, /invoice_id/) do
        Partiduo::Events.publish("invoice.platform_deposited", {"platform_ref" => "PA-1"})
      end
      # Document inconnu : journalisé puis ignoré, sans lever (D-CPY-007).
      deposit(999_999_i64)
    end
  end

  describe "canal public_portal" do
    it "refuse l'ancien canal chorus_pro au contrat et en base, accepte public_portal" do
      setup = InvoicingSpec.setup
      invoice = InvoicingSpec.issued(setup)
      refused = Api.set_issue_channel(InvoicingSpec.actor, invoice.id, Api::ChannelInput.new("chorus_pro"))
      refused.error_keys.should eq(["invoicing.errors.document.issue_channel.invalid"])
      ReferentialSpec.expect_translated(refused)
      Api.set_issue_channel(InvoicingSpec.actor, invoice.id, Api::ChannelInput.new("public_portal"))
        .value!.issue_channel.should eq("public_portal")
      # Le copie PDF ne double que la plateforme agréée.
      Api.pdf_copy_status(InvoicingSpec.actor, invoice.id).eligible.should be_false

      draft = InvoicingSpec.draft(setup)
      InvoicingSpec.sql_error("UPDATE invoicing_document SET issue_channel = 'chorus_pro' WHERE id = $1", draft.id)
        .to_s.should contain("invoicing_document_issue_channel_check")
      InvoicingSpec.sql_error("UPDATE invoicing_document SET issue_channel = 'public_portal' WHERE id = $1", draft.id)
        .should be_nil
    end

    it "propose le courriel à une administration qui en a un, sans l'extension, et traduit la raison" do
      InvoicingSpec.setup
      body = customer("Commune", siren: "217500016", email: "factures@commune.test", customer_nature: "public")
      proposal = Api.propose_channel(InvoicingSpec.actor, body.id)
      {proposal.channel, proposal.b2c, proposal.reason}.should eq({"email", false, "public_customer_manual"})
      Partiduo::LOCALES.each do |locale|
        I18n.with_locale(locale) { I18n.t(proposal.reason_key).should_not contain("missing") }
      end
      # Administration étrangère : pas de portail français.
      foreign = customer("Commune belge", customer_nature: "public", vat_number: "BE0207373429",
        address: Cards::AddressInput.new(line1: "Grand-Place 1", postcode: "1000", city: "Bruxelles", country_code: "BE"))
      Api.propose_channel(InvoicingSpec.actor, foreign.id).channel.should_not eq("public_portal")
    end
  end

  describe "contrat" do
    it "exige le droit de lecture pour l'état et le PDF de la copie ; document inconnu" do
      setup = InvoicingSpec.setup
      invoice = InvoicingSpec.issued(setup)
      expect_raises(Partiduo::Api::Forbidden) { Api.pdf_copy_status(actor_with, invoice.id) }
      expect_raises(Partiduo::Api::Forbidden) { Api.document_pdf_copy(actor_with, invoice.id) }
      expect_raises(Partiduo::Api::NotFound) { Api.pdf_copy_status(InvoicingSpec.actor, 999_999_i64) }
      Api.pdf_copy_status(actor_with("invoicing.invoice.read"), invoice.id).eligible.should be_true
    end
  end
end

describe_module "INVOICING", "Partiduo::Api::Invoicing — copie PDF, Facturation inactive" do
  it "refuse les commandes et requêtes de la copie (ModuleDisabled) et ignore le dépôt" do
    setup = InvoicingSpec.setup
    invoice = InvoicingSpec.issued(setup)
    with_transport do |transport|
      with_active_modules(all_modules_but("invoicing")) do
        expect_raises(Partiduo::Api::ModuleDisabled) { Api.pdf_copy_status(InvoicingSpec.actor, invoice.id) }
        expect_raises(Partiduo::Api::ModuleDisabled) { Api.send_pdf_copy(InvoicingSpec.actor, invoice.id) }
        expect_raises(Partiduo::Api::ModuleDisabled) { Api.document_pdf_copy(InvoicingSpec.actor, invoice.id) }
        # Personne n'est abonné : l'événement est consigné, sans effet.
        deposit(invoice.id)
      end
      transport.messages.should be_empty
      Api.document(InvoicingSpec.actor, invoice.id).status.should eq("issued")
      Api.pdf_copy_status(InvoicingSpec.actor, invoice.id).deposited_at.should be_nil
    end
  end
end

describe "Partiduo::Api::Cards.create_individual_customer — saisie express (lot C)" do
  it "refuse sans catégorie de clients, avec une erreur traduite" do
    result = Cards.create_individual_customer(Partiduo::Api::Actor.system,
      Cards::IndividualCustomerInput.new(name: "Jeanne Martin"))
    result.errors.map { |error| {error.field, error.key} }
      .should eq([{"category_id", "cards.errors.card.category_id.no_customer_category"}])
    ReferentialSpec.expect_translated(result)
  end

  it "prend à défaut une autre catégorie de clients, normalise le courriel et publie card.saved" do
    system = Partiduo::Api::Actor.system
    Cards.create_category(system, Cards::CategoryInput.new(code: "PARTICULIERS", name: "Particuliers",
      kind: "customer")).value!
    ReferentialSpec.capture_events("card.saved") do |events|
      card = Cards.create_individual_customer(system, Cards::IndividualCustomerInput.new(name: "Jeanne Martin",
        email: "  Jeanne@Exemple.TEST ")).value!
      {card.customer_nature, card.email, card.name}.should eq({"individual", "jeanne@exemple.test", "Jeanne Martin"})
      card.address.should be_nil
      events.map(&.["card_id"]).should eq([card.id.to_s])
    end
  end

  it "refuse un courriel invalide et un acteur sans droit d'écriture sur les fiches" do
    system = Partiduo::Api::Actor.system
    Cards.create_category(system, Cards::CategoryInput.new(code: "CUSTOMER", name: "Clients", kind: "customer")).value!
    Cards.create_individual_customer(system, Cards::IndividualCustomerInput.new(name: "X", email: "pas-un-courriel"))
      .error_keys.should eq(["cards.errors.card.email.invalid"])
    expect_raises(Partiduo::Api::Forbidden) do
      Cards.create_individual_customer(actor_with("cards.card.read"), Cards::IndividualCustomerInput.new(name: "X"))
    end
  end
end

# Tables de travail de la migration : hors du vidage entre exemples (elles
# n'ont pas de modèle), vidées ici pour qu'un identifiant de fiche réutilisé
# ne soit pas pris pour une fiche touchée par un exemple précédent.
private def clear_migration_work_tables : Nil
  InvoicingSpec.sql_error("DELETE FROM cards_customer_nature_initialized").should be_nil
  InvoicingSpec.sql_error("DELETE FROM cards_customer_siren_filled").should be_nil
end

describe_module "INVOICING", "Migration cards 0003 — nature initiale des fiches de client (lot C)" do
  before_each { clear_migration_work_tables }

  it "pose la nature que proposait la règle, sur les seules fiches de client sans nature, et se retire exactement" do
    setup = InvoicingSpec.setup
    cases = {
      "Particulier"   => {"", ""},
      "Entreprise"    => {"443061841", ""},
      "Étrangère"     => {"", "DE136695976"},
      "Mairie"        => {"217500016", ""},
      "Mairie TVA"    => {"", InvoicingSpec.fr_vat("217500016")},
      "Pro TVA FR"    => {"", InvoicingSpec.fr_vat("443061841")},
      "Établissement" => {"130025265", ""},
    }
    cards = cases.map { |name, (siren, vat)| {customer("M #{name}", siren: siren, vat_number: vat), siren, vat} }
    chosen = customer("Choisie", siren: "443061841", customer_nature: "individual")
    cards.each { |card, _, _| card.customer_nature.should eq("") }

    InvoicingSpec.sql_error(Migration::Cards::V0003::FORWARD).should be_nil
    cards.each do |card, siren, vat|
      Cards.card(InvoicingSpec.system, card.id).customer_nature.should eq(Cards.propose_nature(siren, vat))
    end
    Cards.card(InvoicingSpec.system, chosen.id).customer_nature.should eq("individual")
    # SIREN tiré du numéro de TVA français quand la fiche n'en a pas
    # (D-CPY-008) : la facture n'est pas refusée faute de SIREN.
    sirens = cards.to_h { |card, _, _| {card.name, Cards.card(InvoicingSpec.system, card.id).siren} }
    sirens["M Pro TVA FR"].should eq("443061841")
    sirens["M Mairie TVA"].should eq("217500016")
    sirens["M Étrangère"].should eq("")
    sirens["M Particulier"].should eq("")
    Partiduo::Invoicing::Issuing.siren_required?(Cards.card(InvoicingSpec.system, cards[5][0].id)).should be_false
    # Les fiches du jeu d'essai sont aussi posées ; aucune fiche d'article.
    Cards.card(InvoicingSpec.system, setup.customer.id).customer_nature.should eq("business")
    Cards.card(InvoicingSpec.system, setup.private_customer.id).customer_nature.should eq("individual")
    Cards.card(InvoicingSpec.system, setup.item.id).customer_nature.should eq("")

    InvoicingSpec.sql_error(Migration::Cards::V0003::BACKWARD).should be_nil
    cards.each do |card, siren, _|
      restored = Cards.card(InvoicingSpec.system, card.id)
      {restored.customer_nature, restored.siren}.should eq({"", siren})
    end
    Cards.card(InvoicingSpec.system, chosen.id).customer_nature.should eq("individual")
  end

  it "tire le SIREN d'un numéro de TVA français même d'une fiche dont la nature est déjà choisie, sauf clé de Luhn fausse" do
    InvoicingSpec.setup
    chosen = customer("Pro choisi", vat_number: InvoicingSpec.fr_vat("443061841"), customer_nature: "business")
    wrong = customer("Clé fausse", vat_number: InvoicingSpec.fr_vat("443061842"))
    InvoicingSpec.sql_error(Migration::Cards::V0003::FORWARD).should be_nil
    Cards.card(InvoicingSpec.system, chosen.id).siren.should eq("443061841")
    Cards.card(InvoicingSpec.system, wrong.id).siren.should eq("")
    InvoicingSpec.sql_error(Migration::Cards::V0003::BACKWARD).should be_nil
    {Cards.card(InvoicingSpec.system, chosen.id).siren, Cards.card(InvoicingSpec.system, chosen.id).customer_nature}
      .should eq({"", "business"})
  end
end

describe "Facturation — actions de l'historique (liste fermée du contrat)" do
  it "déclare dans DOCUMENT_EVENT_ACTIONS toute action tracée par le module" do
    traced = Dir.glob("#{__DIR__}/../../src/invoicing/**/*.cr").flat_map do |path|
      File.read(path).scan(/(?:log\([^,\n]+,|action:)\s*"([a-z_]+)"/).map(&.[1])
    end.uniq!
    traced.should contain("platform_deposited")
    (traced - Api::DOCUMENT_EVENT_ACTIONS).should be_empty
  end
end
