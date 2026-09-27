# SPDX-License-Identifier: AGPL-3.0-or-later

# Outils des specs de bout en bout Facturation ↔ Comptabilité (ADR-006 D3,
# D7) : tout passe par les contrats et les événements.
module IntegrationSpec
  alias Acc = Partiduo::Api::Accounting
  alias Inv = Partiduo::Api::Invoicing

  BOTH = "accounting,invoicing"

  def self.system : Partiduo::Api::Actor
    Partiduo::Api::Actor.system
  end

  def self.d(text : String) : BigDecimal
    BigDecimal.new(text)
  end

  def self.date(text : String) : Time
    Time.parse_utc(text, "%Y-%m-%d")
  end

  # Instance FR provisionnée avec les modules actifs (plan, journaux, taux),
  # clients et articles de `InvoicingSpec`, exercice 2026 si `year`.
  def self.setup(year : Bool = true) : InvoicingSpec::Setup
    setup = InvoicingSpec.setup
    ReferentialSpec.fiscal_year(2026) if year
    setup
  end

  # Écritures portant la référence `source`.
  def self.entries(source : String) : Array(Acc::EntryView)
    Acc.entries(system, Acc::EntryQuery.new(source: source))
  end

  def self.entry(source : String) : Acc::EntryView
    found = entries(source)
    found.size.should eq(1)
    found.first
  end

  def self.card_account(card_id : Int64) : String
    (Acc.card_account(system, card_id) || raise "fiche sans compte").account.number
  end

  # Ligne d'une écriture au compte `number`.
  def self.line(entry : Acc::EntryView, number : String) : Acc::EntryLineView
    entry.lines.find { |line| line.account_number == number } || raise "compte #{number} absent de l'écriture"
  end

  # {sens, montant} par compte.
  def self.by_account(entry : Acc::EntryView) : Hash(String, Array({String, BigDecimal}))
    EntrySpec.lines_by_account(entry)
  end

  # Encaissement en banque (journal F01) lettré avec les lignes citées.
  def self.bank_receipt(customer_code : String, amount : String, match : Array(Int64), on : String = "2026-09-25") : Acc::EntryView
    ledger = Acc.ledger_by_code(system, "F01")
    input = Acc::FinancialInput.new(ledger_id: ledger.id, date: date(on),
      lines: [Acc::PaymentLineInput.new(amount: d(amount), card: customer_code, label: "Virement",
        match_line_ids: match)])
    result = Acc.post_financial(system, input)
    raise "encaissement refusé : #{result.error_keys.join(", ")}" if result.failure?
    result.value!.first
  end

  def self.document(id : Int64) : Inv::DocumentView
    Inv.document(InvoicingSpec.actor, id)
  end

  def self.record_payment(id : Int64, amount : String, on : String = "2026-09-20",
                          method : String = "transfer") : Inv::PaymentView
    result = Inv.record_payment(InvoicingSpec.actor, Inv::PaymentInput.new(document_id: id, amount: d(amount),
      paid_on: date(on), method: method))
    raise "règlement refusé : #{result.error_keys.join(", ")}" if result.failure?
    result.value!
  end

  # Avoir d'une ligne sur la facture `invoice_id`, émis le `on`.
  def self.credit_note(setup : InvoicingSpec::Setup, invoice_id : Int64, quantity : String = "1",
                       on : String = "2026-09-16") : Inv::DocumentView
    credit = Inv.transform(InvoicingSpec.actor, invoice_id, Inv::TransformInput.new("credit_note")).value!
    Inv.update_document(InvoicingSpec.actor, credit.id, InvoicingSpec.document_input(setup, "credit_note",
      credited_document_id: invoice_id, lines: [InvoicingSpec.line(setup, quantity)])).value!
    InvoicingSpec.issue(credit.id, on)
  end
end
