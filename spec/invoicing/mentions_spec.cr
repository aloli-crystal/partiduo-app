# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias Api = Partiduo::Api::Invoicing

private def message(view : Api::DocumentView, code : String) : String
  mention = view.mentions.find { |item| item.code == code } || raise "mention #{code} absente : #{InvoicingSpec.codes(view)}"
  I18n.with_locale("fr") { Partiduo::Invoicing::Output.mention_text(mention, view) }
end

# ADR-006 D5 : mentions obligatoires générées, jamais laissées au modèle.
describe_module "INVOICING", "Facturation — mentions obligatoires" do
  it "génère les mentions françaises d'une facture à un professionnel" do
    setup = InvoicingSpec.setup
    settings = Api.settings(InvoicingSpec.actor).to_input.copy_with(vat_on_debits: true, iban: "FR7630006000011234567890189",
      bic: "AGRIFRPP")
    Api.update_settings(InvoicingSpec.actor, settings).value!
    invoice = InvoicingSpec.issued(setup, operation_category: "mixed")
    codes = InvoicingSpec.codes(invoice)
    %w[seller.legal_form_capital seller.rcs.fr seller.siren seller.vat_number customer.siren customer.vat_number
      dates.issue dates.delivery dates.due delivery_address operation_category.mixed vat_on_debits
      payment.bank payment.no_early_discount payment.late_penalties_legal.fr payment.indemnity].each do |code|
      codes.should contain(code)
    end
    message(invoice, "customer.siren").should eq("SIREN du client : 443061841")
    message(invoice, "seller.legal_form_capital").should eq("SARL au capital de 10\u00A0000,00 €")
    message(invoice, "payment.indemnity").should contain("40,00 €")
    message(invoice, "dates.due").should eq("Date d'échéance : 15/10/2026")
    message(invoice, "delivery_address").should contain("Saint-Herblain")
    message(invoice, "vat_on_debits").should eq("Option pour le paiement de la taxe d'après les débits")
  end

  it "adapte les mentions : particulier, taux de pénalités, escompte, franchise, autoliquidation" do
    setup = InvoicingSpec.setup
    settings = Api.settings(InvoicingSpec.actor).to_input.copy_with(late_penalty_rate: BigDecimal.new("12.15"),
      early_discount_rate: BigDecimal.new("2"), early_discount_days: 10)
    Api.update_settings(InvoicingSpec.actor, settings).value!
    franchise = setup.rates["FRANC"]
    lines = [InvoicingSpec.line(setup, "1", vat_rate_id: franchise.id)]
    invoice = InvoicingSpec.issued(setup, lines: lines, customer_card_id: setup.private_customer.id)
    codes = InvoicingSpec.codes(invoice)
    codes.should_not contain("payment.indemnity")
    codes.should_not contain("customer.siren")
    codes.should_not contain("delivery_address")
    message(invoice, "special.franchise.fr").should eq("TVA non applicable, art. 293 B du CGI")
    message(invoice, "payment.late_penalties").should eq("Pénalités de retard : 12,15 % par an")
    message(invoice, "payment.early_discount").should contain("2 % pour un règlement sous 10 jours")

    reverse = InvoicingSpec.issued(setup, lines: [InvoicingSpec.line(setup, "1", vat_rate_id: setup.rates["AUTOL"].id)])
    InvoicingSpec.codes(reverse).should contain("special.reverse_charge.fr")
    reverse.totals.total_vat.should eq(BigDecimal.new(0))
  end

  it "génère les mentions belges, dont la communication structurée modulo 97" do
    setup = InvoicingSpec.setup("be")
    invoice = InvoicingSpec.issued(setup)
    invoice.structured_reference.should eq("+++261/0000/00149+++")
    Partiduo::Invoicing::Numbering.valid_structured_reference?(invoice.structured_reference).should be_true
    codes = InvoicingSpec.codes(invoice)
    codes.should contain("payment.structured_reference")
    codes.should contain("seller.enterprise_number")
    codes.should contain("payment.late_penalties_legal.be")
    codes.should_not contain("seller.siren")
    codes.should_not contain("vat_on_debits")
    message(invoice, "seller.enterprise_number").should eq("Numéro d'entreprise : 0417.497.106")
    message(invoice, "payment.structured_reference").should eq("Communication structurée : +++261/0000/00149+++")
    reverse = InvoicingSpec.issued(setup, lines: [InvoicingSpec.line(setup, "1", vat_rate_id: setup.rates["COC"].id)])
    message(reverse, "special.reverse_charge.be").should contain("art. 51, § 2")
  end

  it "fige les mentions à l'émission ; les paramètres modifiés ensuite ne les changent pas" do
    setup = InvoicingSpec.setup
    invoice = InvoicingSpec.issued(setup)
    Api.update_settings(InvoicingSpec.actor, Api.settings(InvoicingSpec.actor).to_input
      .copy_with(late_penalty_rate: BigDecimal.new("15"))).value!
    InvoicingSpec.codes(Api.document(InvoicingSpec.actor, invoice.id)).should contain("payment.late_penalties_legal.fr")
    InvoicingSpec.codes(InvoicingSpec.issued(setup)).should contain("payment.late_penalties")
  end

  it "traduit chaque mention en fr, en et nl" do
    setup = InvoicingSpec.setup
    invoice = InvoicingSpec.issued(setup)
    invoice.mentions.each do |mention|
      Partiduo::LOCALES.each do |locale|
        I18n.with_locale(locale) do
          text = Partiduo::Invoicing::Output.mention_text(mention, invoice)
          text.should_not contain("missing")
          text.should_not contain("%{")
        end
      end
    end
  end
end
