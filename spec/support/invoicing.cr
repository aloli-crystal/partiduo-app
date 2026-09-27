# SPDX-License-Identifier: AGPL-3.0-or-later

# Outils des specs du module Facturation (lot F) : tout passe par le contrat
# (`Partiduo::Api::Invoicing` et le socle).
module InvoicingSpec
  alias Api = Partiduo::Api::Invoicing

  PERMISSIONS = %w[invoicing.invoice.read invoicing.invoice.write invoicing.invoice.issue invoicing.invoice.send
    invoicing.credit_note.issue invoicing.payment.record invoicing.reminder.send invoicing.template.manage
    invoicing.settings.manage invoicing.export.read]

  record Setup,
    customer : Partiduo::Api::Cards::CardView,
    private_customer : Partiduo::Api::Cards::CardView,
    item : Partiduo::Api::Cards::CardView,
    goods : Partiduo::Api::Cards::CardView,
    rates : Hash(String, Partiduo::Api::Vat::RateView)

  def self.system : Partiduo::Api::Actor
    Partiduo::Api::Actor.system
  end

  # Utilisateur de la facturation (toutes les permissions du module).
  def self.actor : Partiduo::Api::Actor
    Partiduo::Api::Actor.user(7_i64, PERMISSIONS)
  end

  def self.date(text : String) : Time
    Time.parse_utc(text, "%Y-%m-%d")
  end

  def self.d(text : String) : BigDecimal
    BigDecimal.new(text)
  end

  def self.fr_vat(siren : String) : String
    key = (12 + 3 * (siren.to_i64 % 97)) % 97
    "FR#{key.to_s.rjust(2, '0')}#{siren}"
  end

  # Instance provisionnée (régime FR par défaut, ou BE), clients et articles.
  def self.setup(regime : String = "fr") : Setup
    if regime == "be"
      provision_instance(settings_input(
        company_name: "Exemple SRL", legal_form: "SRL", share_capital: nil, rcs: "RPM Bruxelles",
        siren: nil, vat_number: "BE0417497106", street: "rue de la Loi", street_number: "16",
        postcode: "1000", city: "Bruxelles", country_code: "BE", tax_regime: "be",
        email: "factures@exemple.test"))
    else
      provision_instance(settings_input(email: "factures@exemple.test"))
    end
    cards = Partiduo::Api::Cards
    customers = cards.category_by_code(system, "CUSTOMER") || raise "catégorie CUSTOMER absente"
    items = cards.category_by_code(system, "SALE") || raise "catégorie SALE absente"
    rates = Partiduo::Api::Vat.rates(system).to_h { |rate| {rate.code, rate} }
    country = regime == "be" ? "BE" : "FR"
    customer_input = if regime == "be"
                       Partiduo::Api::Cards::CardInput.new(category_id: customers.id, name: "Client Pro SA",
                         vat_number: "BE0403019261", email: "compta@client.test",
                         address: Partiduo::Api::Cards::AddressInput.new(line1: "avenue Louise 1", postcode: "1050",
                           city: "Ixelles", country_code: "BE"))
                     else
                       Partiduo::Api::Cards::CardInput.new(category_id: customers.id, name: "Client Pro SARL",
                         siren: "443061841", vat_number: fr_vat("443061841"), email: "compta@client.test",
                         address: Partiduo::Api::Cards::AddressInput.new(line1: "3 rue du Port", postcode: "44100",
                           city: "Nantes", country_code: "FR"),
                         delivery_addresses: [Partiduo::Api::Cards::AddressInput.new(line1: "Zone artisanale, lot 7",
                           postcode: "44800", city: "Saint-Herblain", country_code: "FR")])
                     end
    customer = cards.create_card(system, customer_input).value!
    private_customer = cards.create_card(system, Partiduo::Api::Cards::CardInput.new(category_id: customers.id, name: "Jeanne Martin",
      address: Partiduo::Api::Cards::AddressInput.new(line1: "5 place Royale", postcode: country == "BE" ? "1000" : "44000",
        city: country == "BE" ? "Bruxelles" : "Nantes", country_code: country))).value!
    standard = regime == "be" ? rates["21G"] : rates["NOR"]
    item = cards.create_card(system, Partiduo::Api::Cards::CardInput.new(category_id: items.id, name: "Conseil (heure)",
      code: "CONSEIL", unit_code: "HUR", sale_price: d("80"), vat_rate_id: standard.id)).value!
    goods = cards.create_card(system, Partiduo::Api::Cards::CardInput.new(category_id: items.id, name: "Carton de ramettes",
      code: "RAMETTES", unit_code: "C62", sale_price: d("24.90"), vat_rate_id: standard.id)).value!
    Setup.new(customer, private_customer, item, goods, rates)
  end

  def self.standard_rate(setup : Setup) : Partiduo::Api::Vat::RateView
    setup.rates["NOR"]? || setup.rates["21G"]
  end

  def self.line(setup : Setup, quantity : String = "1", **options) : Api::LineInput
    Api::LineInput.new(kind: "item", item_card_id: setup.item.id, quantity: d(quantity)).copy_with(**options)
  end

  def self.document_input(setup : Setup, kind : String = "invoice", lines : Array(Api::LineInput)? = nil,
                          **options) : Api::DocumentInput
    Api::DocumentInput.new(kind: kind, customer_card_id: setup.customer.id,
      lines: lines || [line(setup, "10"), line(setup, "2", item_card_id: setup.goods.id)]).copy_with(**options)
  end

  def self.draft(setup : Setup, kind : String = "invoice", **options) : Api::DocumentView
    Api.create_document(actor, document_input(setup, kind, **options)).value!
  end

  def self.issue(id : Int64, on : String = "2026-09-15") : Api::DocumentView
    result = Api.issue(actor, id, Api::IssueInput.new(issue_date: date(on)))
    raise "émission refusée : #{result.error_keys.join(", ")}" if result.failure?
    result.value!
  end

  def self.issued(setup : Setup, kind : String = "invoice", on : String = "2026-09-15", **options) : Api::DocumentView
    issue(draft(setup, kind, **options).id, on)
  end

  # Événements `name` publiés pendant le bloc.
  def self.capture(name : String, & : Array(Partiduo::Events::Event) ->) : Nil
    ReferentialSpec.capture_events(name) { |events| yield events }
  end

  # Mentions du document, par code.
  def self.codes(view : Api::DocumentView) : Array(String)
    view.mentions.map(&.code)
  end

  # Exécute une instruction SQL brute ; renvoie le message d'erreur de
  # PostgreSQL, ou `nil` si elle passe.
  def self.sql_error(sql : String, *args) : String?
    Marten::DB::Connection.default.open(&.exec(sql, *args))
    nil
  rescue ex : PQ::PQError
    ex.message
  end
end
