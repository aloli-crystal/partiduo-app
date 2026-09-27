# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Factures d'achat reçues hors plateforme (ADR-004 D9) : saisie manuelle
# dans le journal d'achats avec la pièce jointe, marquage « reçue hors
# plateforme », contrôle de doublon (même fournisseur, même numéro, même
# montant) commun avec les factures reçues par la plateforme.

private alias Api = Partiduo::Api::Accounting

private PDF = "%PDF-1.7\n1 0 obj << >> endobj\n%%EOF\n"

private def system
  Partiduo::Api::Actor.system
end

private def attachment : Int64
  Partiduo::Api::Core.store_attachment(system,
    Partiduo::Api::Core::AttachmentInput.new("facture.pdf", "application/pdf", IO::Memory.new(PDF))).value!.id
end

private def received(supplier : String, number : String = "FB-2026-0918-4471", amount : String = "72",
                     day : String = "2026-09-24", **options) : Api::ReceivedInvoiceInput
  document = EntrySpec.document("A01", supplier, [EntrySpec.item(amount, account: "603")], day,
    attachment_id: attachment, label: "Abonnement fibre")
  Api::ReceivedInvoiceInput.new(document: document, number: number).copy_with(**options)
end

describe_module "ACCOUNTING", "Factures d'achat reçues hors plateforme (ADR-004 D9)" do
  it "enregistre l'écriture d'achat avec sa pièce jointe et la facture marquée « reçue hors plateforme »" do
    EntrySpec.setup
    supplier = EntrySpec.card("SUPPLIER", "Orange Business")
    input = received(supplier.code, invoice_date: EntrySpec.date("2026-09-18"))

    view = Api.post_received_invoice(system, input).value!

    view.off_platform?.should be_true
    view.origin_key.should eq("accounting.received_invoice.origins.off_platform")
    {view.number, view.invoice_date, view.total_amount, view.currency_code}
      .should eq({"FB-2026-0918-4471", EntrySpec.date("2026-09-18"), BigDecimal.new("86.40"), "EUR"})
    {view.supplier_card_id, view.supplier_code, view.ledger_code}.should eq({supplier.id, supplier.code, "A01"})
    view.cancelled.should be_false

    entry = Api.entry(system, view.entry_id)
    entry.attachment_id.should eq(input.document.attachment_id)
    entry.attachment_id.should eq(view.attachment_id)
    entry.amount.should eq(BigDecimal.new("86.40"))
    Api.received_invoice_for_entry(system, entry.id).should eq(view)
    Api.received_invoice(system, view.id).should eq(view)
    Api.received_invoice_for_entry(system, EntrySpec.post_misc([EntrySpec.debit("603", "1"), EntrySpec.credit("510001", "1")]).id)
      .should be_nil
  end

  it "prend la date de l'écriture à défaut de date de facture, et l'origine « plateforme » d'une extension" do
    EntrySpec.setup
    supplier = EntrySpec.card("SUPPLIER", "Fournisseur PA")
    view = Api.post_received_invoice(system, received(supplier.code, origin: Api::ReceptionOrigin::Platform,
      platform_reference: "inv_8f2a")).value!
    view.invoice_date.should eq(EntrySpec.date("2026-09-24"))
    view.off_platform?.should be_false
    view.platform_reference.should eq("inv_8f2a")
  end

  it "refuse le doublon : même fournisseur, même numéro (casse et séparateurs ignorés), même montant" do
    EntrySpec.setup
    supplier = EntrySpec.card("SUPPLIER", "Orange Business")
    other = EntrySpec.card("SUPPLIER", "Autre fournisseur")
    first = Api.post_received_invoice(system, received(supplier.code)).value!

    duplicate = Api.post_received_invoice(system, received(supplier.code, number: " fb 2026 0918/4471 "))
    duplicate.errors.map { |error| {error.field, error.key} }
      .should eq([{"number", "accounting.errors.received_invoice.duplicate"}])
    duplicate.errors.first.params["receipt"].should eq(first.receipt)
    duplicate.errors.first.params["date"].should eq("2026-09-24")
    Api.check_received_invoice(system, received(supplier.code)).error_keys
      .should eq(["accounting.errors.received_invoice.duplicate"])

    # Autre montant, autre fournisseur, autre numéro : pas un doublon.
    Api.post_received_invoice(system, received(supplier.code, amount: "73")).success?.should be_true
    Api.post_received_invoice(system, received(other.code)).success?.should be_true
    Api.post_received_invoice(system, received(supplier.code, number: "FB-2026-0918-4472")).success?.should be_true

    found = Api.received_invoice_duplicates(system, Api::DuplicateQuery.new(supplier.id, "FB20260918-4471", BigDecimal.new("86.4")))
    found.map(&.id).should eq([first.id])
    Api.received_invoice_duplicates(system, Api::DuplicateQuery.new(supplier.id, "FB-2026-0918-4471",
      BigDecimal.new("86.40"), "USD")).should be_empty
  end

  it "ne compte plus comme doublon une facture dont l'écriture est annulée par extourne" do
    EntrySpec.setup
    supplier = EntrySpec.card("SUPPLIER", "Orange Business")
    first = Api.post_received_invoice(system, received(supplier.code)).value!
    Api.cancel_entry(system, Api::CancelEntryInput.new(first.entry_id)).value!
    Api.received_invoice(system, first.id).cancelled.should be_true
    Api.post_received_invoice(system, received(supplier.code)).success?.should be_true
  end

  it "exige le numéro et la pièce jointe, un journal d'achats et une écriture valide" do
    EntrySpec.setup
    supplier = EntrySpec.card("SUPPLIER", "Orange Business")
    no_attachment = received(supplier.code, number: "  ")
    no_attachment = no_attachment.copy_with(document: no_attachment.document.copy_with(attachment_id: nil))
    result = Api.post_received_invoice(system, no_attachment)
    result.errors.map { |error| {error.field, error.key} }.should eq([
      {"number", "accounting.errors.received_invoice.number.blank"},
      {"attachment_id", "accounting.errors.received_invoice.attachment.required"},
    ])
    Api.post_received_invoice(system, received(supplier.code, number: "X" * 101)).error_keys
      .should eq(["accounting.errors.received_invoice.number.too_long"])

    sale = received(supplier.code)
    sale = sale.copy_with(document: sale.document.copy_with(ledger_id: EntrySpec.ledger("V01").id))
    Api.post_received_invoice(system, sale).error_keys.should eq(["accounting.errors.entry.ledger.not_purchase"])

    unknown = received("INCONNU")
    Api.post_received_invoice(system, unknown).failure?.should be_true
    Api.check_received_invoice(system, received(supplier.code)).value!.total_including_vat.should eq(BigDecimal.new("86.40"))
    Api.count_entries(system).should eq(0)
  end

  it "garde la facture reçue intangible en base" do
    EntrySpec.setup
    supplier = EntrySpec.card("SUPPLIER", "Orange Business")
    view = Api.post_received_invoice(system, received(supplier.code)).value!
    expect_raises(Exception, /ni modification ni suppression/) do
      EntrySpec.sql("UPDATE accounting_received_invoice SET number = 'X' WHERE id = $1", view.id)
    end
    expect_raises(Exception, /ni modification ni suppression/) do
      EntrySpec.sql("DELETE FROM accounting_received_invoice WHERE id = $1", view.id)
    end
  end

  it "exige le droit de saisie, et le module actif" do
    EntrySpec.setup
    supplier = EntrySpec.card("SUPPLIER", "Orange Business")
    expect_raises(Partiduo::Api::Forbidden) do
      Api.post_received_invoice(actor_with("accounting.entry.read"), received(supplier.code))
    end
    expect_raises(Partiduo::Api::Forbidden) do
      Api.received_invoice_duplicates(actor_with("accounting.entry.read"),
        Api::DuplicateQuery.new(supplier.id, "1", BigDecimal.new(1)))
    end
    with_active_modules("invoicing") do
      expect_raises(Partiduo::Api::ModuleDisabled) do
        Api.received_invoice_duplicates(system, Api::DuplicateQuery.new(supplier.id, "1", BigDecimal.new(1)))
      end
    end
  end
end
