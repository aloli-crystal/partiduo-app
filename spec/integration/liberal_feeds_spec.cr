# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias Lib = Partiduo::Api::Liberal
private alias I = IntegrationSpec
private alias L = LiberalSpec

# Lot L (tests) : cas limites de l'alimentation du livre-journal par les
# événements de la Facturation (ADR-007 D6, ADR-006 D3) : nature par
# défaut, facture émise avant l'activation, idempotence d'une référence,
# mode de règlement inconnu, échec qui ne bloque jamais le règlement.

private def payment_event(payment_id : String, invoice_id : Int64, amount : String, on : String = "2026-09-20",
                          method : String = "transfer") : Nil
  Partiduo::Events.publish("payment.recorded", {
    "payment_id" => payment_id, "invoice_id" => invoice_id.to_s, "amount" => amount, "paid_on" => on,
    "method" => method,
  })
end

describe "Profession libérale et Facturation — cas limites de l'alimentation" do
  it "inscrit la recette sur la nature par défaut des paramètres, sinon sur la première nature de recettes active" do
    with_active_modules("liberal,invoicing") do
      setup = I.setup
      fees = Lib.create_nature(L.system, Lib::NatureInput.new("RETRO", "Honoraires rétrocédés", "receipt", "receipts")).value!
      Lib.update_settings(L.system, Lib::SettingsInput.new(profession: "Avocat", default_nature_id: fees.id)).value!
      invoice = InvoicingSpec.issued(setup)
      I.record_payment(invoice.id, "100", "2026-09-20")
      Lib.lines(L.system).map(&.nature_code).should eq(["RETRO"])

      # Nature par défaut désactivée : repli sur la nature de la rubrique « recettes ».
      Lib.update_nature(L.system, fees.id, Lib::NatureInput.new("RETRO", fees.label, "receipt", "receipts",
        enabled: false)).value!
      I.record_payment(invoice.id, "50", "2026-09-21")
      Lib.lines(L.system).map(&.nature_code).should eq(%w[RETRO RECEIPTS])
    end
  end

  it "n'empêche jamais le règlement quand la recette ne peut pas être inscrite" do
    with_active_modules("liberal,invoicing") do
      setup = I.setup
      Lib.natures(L.system, "receipt").each do |nature|
        Lib.update_nature(L.system, nature.id, Lib::NatureInput.new(nature.code, nature.label, nature.kind,
          nature.heading, enabled: false)).value!
      end
      invoice = InvoicingSpec.issued(setup)
      payment = I.record_payment(invoice.id, "100", "2026-09-20")
      payment.id.should be > 0
      Lib.lines(L.system).should be_empty
    end
  end

  it "retrouve dans le journal du socle une facture émise avant l'activation du module" do
    setup, invoice = with_active_modules("invoicing") do
      books = I.setup
      {books, InvoicingSpec.issued(books)}
    end
    with_active_modules("liberal,invoicing") do
      Lib.load_defaults(L.system).should be >= 0
      I.record_payment(invoice.id, "1019.76", "2026-09-20", "card")
      line = Lib.lines(L.system).first
      {line.amount, line.method, line.reference, line.label}.should eq({L.d("1019.76"), "card", invoice.number, invoice.number})
      line.card_id.should eq(setup.customer.id)
    end
  end

  it "n'inscrit qu'une fois une référence, arrondit au centime et ramène un mode inconnu à « autre »" do
    with_active_modules("liberal,invoicing") do
      setup = I.setup
      invoice = InvoicingSpec.issued(setup)
      payment_event("900001", invoice.id, "10.005", method: "bitcoin")
      payment_event("900001", invoice.id, "10.005", method: "bitcoin")
      lines = Lib.lines(L.system)
      lines.size.should eq(1)
      {lines.first.amount, lines.first.method, lines.first.source}.should eq({L.d("10.01"), "other", "payment:900001"})
      # Montant nul ou négatif, facture inconnue, date illisible : rien d'inscrit, rien de levé.
      payment_event("900002", invoice.id, "0")
      payment_event("900003", invoice.id, "-5")
      payment_event("900004", 999_999_i64, "5")
      payment_event("900005", invoice.id, "5", on: "20/09/2026")
      Lib.lines(L.system).map(&.source).should eq(["payment:900001", "payment:900005"])
      # Date illisible : date du jour.
      Lib.lines(L.system).last.date.should eq(Partiduo::Config.today)
    end
  end

  it "ne relève pas les avoirs comme des factures" do
    with_active_modules("liberal,invoicing") do
      setup = I.setup
      invoice = InvoicingSpec.issued(setup)
      credit = I.credit_note(setup, invoice.id)
      Partiduo::Liberal::Invoice.filter(invoice_id: credit.id).exists?.should be_false
      Partiduo::Liberal::Invoice.filter(invoice_id: invoice.id).exists?.should be_true
      Lib.lines(L.system).should be_empty
    end
  end
end
