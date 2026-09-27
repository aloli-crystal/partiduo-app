# SPDX-License-Identifier: AGPL-3.0-or-later

# Outils des specs des déclarations de TVA (lot 4) : dossier du régime,
# clients et fournisseurs avec numéro de TVA, achats, ventes et paiements
# par le contrat.
module VatReturnSpec
  alias Api = Partiduo::Api::Accounting

  def self.system : Partiduo::Api::Actor
    Partiduo::Api::Actor.system
  end

  def self.d(text : String) : BigDecimal
    BigDecimal.new(text)
  end

  # Dossier provisionné (identité de la société du régime) avec son plan,
  # ses taux, ses journaux et l'exercice 2026.
  def self.setup(regime : String) : Nil
    settings = if regime == "be"
                 settings_input(company_name: "Exemple SRL", legal_form: "SRL", tax_regime: "be", siren: nil, rcs: nil,
                   vat_number: "BE0417497106", street: "Rue Haute", street_number: "12", postcode: "1000",
                   city: "Bruxelles", country_code: "BE", email: "tva@exemple.be", phone: "025555555")
               else
                 settings_input
               end
    provision_instance(settings)
    ReferentialSpec.fiscal_year(2026)
  end

  def self.card(category : String, name : String, vat_number : String? = nil) : Partiduo::Api::Cards::CardView
    found = Partiduo::Api::Cards.category_by_code(system, category) || raise "catégorie #{category} absente"
    ReferentialSpec.card(found.id, name, vat_number: vat_number)
  end

  def self.sale(customer : Partiduo::Api::Cards::CardView, lines : Array(Api::DocumentLineInput),
                day : String = "2026-02-10") : Api::EntryView
    Api.post_sale(system, EntrySpec.document("V01", customer.code, lines, day)).value!
  end

  def self.purchase(supplier : Partiduo::Api::Cards::CardView, lines : Array(Api::DocumentLineInput),
                    day : String = "2026-02-12") : Api::EntryView
    Api.post_purchase(system, EntrySpec.document("A01", supplier.code, lines, day)).value!
  end

  # Encaissement ou paiement complet d'une facture, lettré avec elle.
  def self.pay(document : Api::EntryView, third_party : Partiduo::Api::Cards::CardView, day : String) : Nil
    line = document.lines.find! { |item| item.card_id == third_party.id && item.vat_role.nil? }
    amount = line.side.debit? ? line.amount : -line.amount
    input = Api::FinancialInput.new(ledger_id: EntrySpec.ledger("F01").id, date: EntrySpec.date(day), lines: [
      Api::PaymentLineInput.new(amount, card: third_party.code, match_line_ids: [line.id]),
    ])
    Api.post_financial(system, input).value!
    nil
  end

  def self.input(form : String, periodicity : String = "quarter", number : Int32 = 1, **options) : Api::VatReturnInput
    Api::VatReturnInput.new(form: form, year: 2026, periodicity: periodicity, number: number).copy_with(**options)
  end

  # Crée une déclaration en brouillon ; son identifiant.
  def self.create(input : Api::VatReturnInput) : Int64
    ReferentialSpec.present(Api.create_vat_return(system, input).value!.id)
  end

  def self.amounts(view : Api::VatReturnView) : Hash(String, BigDecimal)
    view.boxes.reject(&.amount.zero?).to_h { |box| {box.code, box.amount} }
  end
end
