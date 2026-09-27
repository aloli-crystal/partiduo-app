# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Canal d'émission et marquage B2C (ADR-004 D9) : cas limites de la
# proposition, conservation du marquage, intégrité en base, module inactif
# (lot E, testeur).

private alias Api = Partiduo::Api::Invoicing
private alias Cards = Partiduo::Api::Cards

private def customer(name : String, siren : String? = nil, vat : String? = nil, country : String? = nil,
                     email : String = "") : Cards::CardView
  category = Cards.category_by_code(InvoicingSpec.system, "CUSTOMER") || raise "catégorie CUSTOMER absente"
  address = country.try { |code| Cards::AddressInput.new(line1: "1 rue", postcode: "1000", city: "Ville", country_code: code) }
  Cards.create_card(InvoicingSpec.system, Cards::CardInput.new(category_id: category.id, name: name, siren: siren,
    vat_number: vat, email: email, address: address)).value!
end

private def proposal(card : Cards::CardView) : {String, Bool, String, Bool}
  view = Api.propose_channel(InvoicingSpec.actor, card.id)
  {view.channel, view.b2c, view.reason, view.international}
end

describe_module "INVOICING", "Facturation — canal d'émission : règles et cas limites (lot E)" do
  it "reconnaît le professionnel à son SIREN ou à son seul numéro de TVA, dans le pays du dossier" do
    InvoicingSpec.setup
    proposal(customer("TVA seule", vat: InvoicingSpec.fr_vat("443061841"), country: "FR"))
      .should eq({"platform", false, "domestic_business", false})
    proposal(customer("SIREN seul", siren: "552100554", country: "FR"))
      .should eq({"platform", false, "domestic_business", false})
    # Sans adresse : le pays du dossier.
    proposal(customer("Sans adresse", siren: "552100554")).should eq({"platform", false, "domestic_business", false})
    # Un SIREN n'y change rien si le client est établi hors du pays du dossier.
    proposal(customer("Filiale belge", siren: "552100554", country: "BE", email: "a@b.test"))
      .should eq({"email", false, "foreign_business", true})
    # Particulier étranger : B2C, international.
    proposal(customer("Hans Muster", country: "DE")).should eq({"paper", true, "private_customer", true})
    proposal(customer("Jeanne Doe", email: "jeanne@doe.test")).should eq({"email", true, "private_customer", false})
  end

  it "ne propose pas la plateforme à un client français depuis un dossier belge" do
    InvoicingSpec.setup("be")
    proposal(customer("Client FR", siren: "552100554", country: "FR")).should eq({"paper", false, "foreign_business", true})
  end

  it "garde un marquage B2C saisi, et le b2c inchangé quand seul le canal change" do
    setup = InvoicingSpec.setup
    draft = InvoicingSpec.draft(setup, customer_card_id: setup.private_customer.id, b2c: false)
    {draft.issue_channel, draft.b2c}.should eq({"paper", false})
    invoice = InvoicingSpec.issue(draft.id)
    changed = Api.set_issue_channel(InvoicingSpec.actor, invoice.id, Api::ChannelInput.new("email")).value!
    {changed.issue_channel, changed.b2c}.should eq({"email", false})
    Api.set_issue_channel(InvoicingSpec.actor, invoice.id, Api::ChannelInput.new("")).error_keys
      .should eq(["invoicing.errors.document.issue_channel.invalid"])
  end

  it "reprend la proposition pour un acompte et pour une facture tirée d'un devis" do
    setup = InvoicingSpec.setup
    quote = InvoicingSpec.issued(setup, "quote")
    quote.issue_channel.should eq("")
    invoice = Api.transform(InvoicingSpec.actor, quote.id, Api::TransformInput.new("invoice")).value!
    {invoice.issue_channel, invoice.b2c}.should eq({"platform", false})
    deposit = InvoicingSpec.draft(setup, "deposit_invoice")
    deposit.issue_channel.should eq("platform")
  end

  it "fige la date d'envoi en base : un envoi ne s'efface pas pour rouvrir le canal" do
    setup = InvoicingSpec.setup
    invoice = InvoicingSpec.issued(setup)
    Api.mark_sent(InvoicingSpec.actor, invoice.id).value!
    InvoicingSpec.sql_error("UPDATE invoicing_document SET sent_at = NULL WHERE id = $1", invoice.id)
      .to_s.should contain("date d'envoi figée")
    InvoicingSpec.sql_error("UPDATE invoicing_document SET sent_at = NULL, issue_channel = 'paper' WHERE id = $1",
      invoice.id).should_not be_nil
    Api.document(InvoicingSpec.actor, invoice.id).issue_channel.should eq("platform")
    # Brouillon : la date d'envoi n'existe pas, rien n'est figé.
    draft = InvoicingSpec.draft(setup)
    InvoicingSpec.sql_error("UPDATE invoicing_document SET issue_channel = 'paper', b2c = true WHERE id = $1",
      draft.id).should be_nil
  end

  it "trace chaque changement de canal et l'envoi marqué" do
    setup = InvoicingSpec.setup
    invoice = InvoicingSpec.issued(setup)
    Api.set_issue_channel(InvoicingSpec.actor, invoice.id, Api::ChannelInput.new("paper", b2c: true)).value!
    Api.mark_sent(InvoicingSpec.actor, invoice.id).value!
    actions = Api.document_events(InvoicingSpec.actor, invoice.id).map(&.action)
    actions.should contain("channel_changed")
    actions.should contain("marked_sent")
  end

  it "refuse le contrat du canal quand la Facturation est inactive" do
    setup = InvoicingSpec.setup
    invoice = InvoicingSpec.issued(setup)
    with_active_modules("accounting") do
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.propose_channel(InvoicingSpec.actor, setup.customer.id) }
      expect_raises(Partiduo::Api::ModuleDisabled) do
        Api.set_issue_channel(InvoicingSpec.actor, invoice.id, Api::ChannelInput.new("paper"))
      end
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.mark_sent(InvoicingSpec.actor, invoice.id) }
    end
    expect_raises(Partiduo::Api::NotFound) { Api.propose_channel(InvoicingSpec.actor, 999_999_i64) }
  end
end
