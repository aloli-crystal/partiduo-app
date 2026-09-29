# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Conditions de paiement et adresse de livraison d'un document (BLOCAGES
# B-FIN-001, DECISIONS D-R5-003, D-R5-004).

private alias Api = Partiduo::Api::Invoicing
private alias I = InvoicingSpec

private def terms_of(xml : String) : String
  XML.parse(xml).xpath_node("//*[local-name()='SpecifiedTradePaymentTerms']/*[local-name()='Description']")
    .try(&.content).to_s
end

describe_module "INVOICING", "Conditions de paiement d'un document" do
  it "calcule l'échéance à l'émission selon les conditions du document" do
    setup = I.setup
    {
      {nil, nil, "2026-10-15"},            # paramètres : 30 jours nets
      {"net", 45, "2026-10-30"},           # 45 jours nets
      {"end_of_month", 45, "2026-10-31"},  # 45 jours fin de mois
      {"end_of_month", nil, "2026-10-31"}, # délai des paramètres, fin de mois
      {"on_receipt", nil, "2026-09-15"},   # à réception
      {"net", 0, "2026-09-15"},            # comptant
    }.each do |(terms, days, due)|
      invoice = I.issued(setup, payment_terms: terms, payment_terms_days: days)
      invoice.due_date.should eq(I.date(due))
      {invoice.payment_terms, invoice.payment_terms_days}.should eq({terms || "", days})
    end
  end

  it "garde l'échéance saisie, quelles que soient les conditions" do
    setup = I.setup
    invoice = I.issued(setup, payment_terms: "on_receipt", due_date: I.date("2026-12-01"))
    invoice.due_date.should eq(I.date("2026-12-01"))
  end

  it "mentionne les conditions choisies, jusque dans Factur-X, et rien de plus sans condition" do
    setup = I.setup
    plain = I.issued(setup)
    I.codes(plain).none?(&.starts_with?("payment.terms")).should be_true
    invoice = I.issued(setup, payment_terms: "end_of_month", payment_terms_days: 45)
    mention = invoice.mentions.find! { |item| item.code == "payment.terms.end_of_month" }
    mention.params.should eq({"days" => "45"})
    Partiduo::LOCALES.each do |locale|
      I18n.with_locale(locale) { I18n.t(mention.key, mention.params).should_not contain("missing") }
    end
    xml = String.new(Api.facturx_xml(I.actor, invoice.id).content)
    terms_of(xml).should contain("Conditions de paiement : 45 jours fin de mois")
    receipt = I.issued(setup, payment_terms: "on_receipt")
    I.codes(receipt).should contain("payment.terms.on_receipt")
    quote = I.draft(setup, "quote", payment_terms: "net", payment_terms_days: 30)
    I.codes(quote).should contain("payment.terms.net")
  end

  it "refuse des conditions inconnues, un délai hors bornes ou un délai pour un paiement à réception" do
    setup = I.setup
    result = Api.create_document(I.actor, I.document_input(setup, payment_terms: "cash", payment_terms_days: 400))
    result.error_keys.should eq(["invoicing.errors.document.payment_terms.invalid",
                                 "invoicing.errors.document.payment_terms_days.range"])
    ReferentialSpec.expect_translated(result)
    receipt = Api.create_document(I.actor, I.document_input(setup, payment_terms: "on_receipt", payment_terms_days: 10))
    receipt.error_keys.should eq(["invoicing.errors.document.payment_terms_days.on_receipt"])
    ReferentialSpec.expect_translated(receipt)
    draft = I.draft(setup)
    I.sql_error("UPDATE invoicing_document SET payment_terms = 'x' WHERE id = #{draft.id}").to_s.should contain("invoicing_document_payment_terms_check")
  end

  it "reprend les conditions et l'absence d'adresse de livraison du devis dans la facture" do
    setup = I.setup
    quote = I.issued(setup, "quote", payment_terms: "net", payment_terms_days: 60,
      delivery_address: Partiduo::Api::Cards::AddressInput.new)
    quote.delivery_address.should be_nil
    invoice = Api.transform(I.actor, quote.id, Api::TransformInput.new("invoice")).value!
    {invoice.payment_terms, invoice.payment_terms_days}.should eq({"net", 60})
    invoice.delivery_address.should be_nil
  end
end

describe_module "INVOICING", "Adresse de livraison d'un document" do
  it "reprend par défaut la première adresse de livraison du client, en accepte une autre ou aucune" do
    setup = I.setup
    I.draft(setup).delivery_address.try(&.city).should eq("Saint-Herblain")
    other = Partiduo::Api::Cards::AddressInput.new(line1: "Quai de la Fosse 2", postcode: "44000", city: "Nantes")
    chosen = I.issued(setup, delivery_address: other)
    address = chosen.delivery_address || raise "adresse absente"
    {address.line1, address.city, address.country_code}.should eq({"Quai de la Fosse 2", "Nantes", "FR"})
    I.codes(chosen).should contain("delivery_address")
    String.new(Api.facturx_xml(I.actor, chosen.id).content).should contain("Quai de la Fosse 2")
    none = I.draft(setup, delivery_address: Partiduo::Api::Cards::AddressInput.new)
    none.delivery_address.should be_nil
  end
end
