# SPDX-License-Identifier: AGPL-3.0-or-later

# Outils des specs des éditions (lot 3) : un exercice 2026 en régime FR
# avec ventes, achats, règlements lettrés, opérations diverses.
module ReportSpec
  alias Api = Partiduo::Api::Accounting

  record Dataset,
    customer : Partiduo::Api::Cards::CardView,
    supplier : Partiduo::Api::Cards::CardView,
    sale : Api::EntryView,
    purchase : Api::EntryView,
    payment : Api::EntryView

  def self.system : Partiduo::Api::Actor
    Partiduo::Api::Actor.system
  end

  def self.d(text : String) : BigDecimal
    BigDecimal.new(text)
  end

  def self.date(text : String) : Time
    EntrySpec.date(text)
  end

  # Capital apporté, vente de 1 000 HT (TVA 20 %) payée à moitié, achat de
  # 500 HT, dotation aux amortissements, vente de 300 HT impayée.
  # `provisioned` : instance provisionnée (société au SIREN 732 829 320,
  # données initiales du régime) au lieu du seul chargement du plan.
  def self.dataset(provisioned : Bool = false) : Dataset
    if provisioned
      provision_instance
      ReferentialSpec.fiscal_year(2026)
    else
      EntrySpec.setup
    end
    customer = EntrySpec.card("CUSTOMER", "Client Alpha")
    supplier = EntrySpec.card("SUPPLIER", "Fournisseur Beta")
    AccountingSpec.create_account("6061", "Fournitures non stockables")
    EntrySpec.post_misc([EntrySpec.debit("510001", "10000"), EntrySpec.credit("101", "10000")], "2026-01-02",
      label: "Apport en capital")
    sale = Api.post_sale(system, EntrySpec.document("V01", customer.code, [EntrySpec.item("1000", account: "706")],
      "2026-02-01", due_date: date("2026-03-01"), label: "Facture 1")).value!
    purchase = Api.post_purchase(system, EntrySpec.document("A01", supplier.code, [EntrySpec.item("500", account: "6061")],
      "2026-02-10", due_date: date("2026-03-10"), label: "Facture achat")).value!
    sale_line = sale.lines.find! { |line| line.card_id == customer.id }.id
    payment = Api.post_financial(system, Api::FinancialInput.new(ledger_id: EntrySpec.ledger("F01").id,
      date: date("2026-03-05"), lines: [Api::PaymentLineInput.new(d("600"), card: customer.code,
      match_line_ids: [sale_line])])).value!.first
    EntrySpec.post_misc([EntrySpec.debit("681", "120"), EntrySpec.credit("281", "120")], "2026-06-30",
      label: "Dotation")
    Api.post_sale(system, EntrySpec.document("V01", customer.code, [EntrySpec.item("300", account: "706")],
      "2026-07-01", due_date: date("2026-07-31"), label: "Facture 2")).value!
    Dataset.new(customer, supplier, sale, purchase, payment)
  end
end
