# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Factures d'achat reçues (ADR-004 D9) : cas limites du contrôle de doublon
# (arrondi au centime, devise, avoir, numéro normalisé), permissions par
# journal, intégrité en base (lot E, testeur).

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
                     **options) : Api::ReceivedInvoiceInput
  document = EntrySpec.document("A01", supplier, [EntrySpec.item(amount, account: "603")], "2026-09-24",
    attachment_id: attachment, label: "Achat")
  Api::ReceivedInvoiceInput.new(document: document, number: number).copy_with(**options)
end

private def query(card : Partiduo::Api::Cards::CardView, number : String, amount : String,
                  currency : String? = nil) : Array(Api::ReceivedInvoiceView)
  Api.received_invoice_duplicates(system, Api::DuplicateQuery.new(card.id, number, BigDecimal.new(amount), currency))
end

describe_module "ACCOUNTING", "Factures d'achat reçues : règles et cas limites (lot E)" do
  it "compare le montant au centime par l'arrondi commercial, non l'arrondi bancaire" do
    EntrySpec.setup
    supplier = EntrySpec.card("SUPPLIER", "Orange Business")
    view = Api.post_received_invoice(system, received(supplier.code, amount: "99.99")).value!
    view.total_amount.should eq(BigDecimal.new("119.99"))
    query(supplier, view.number, "119.99").map(&.id).should eq([view.id])
    query(supplier, view.number, "119.985").map(&.id).should eq([view.id])
    query(supplier, view.number, "119.9849").should be_empty
    query(supplier, view.number, "119.98").should be_empty
  end

  it "distingue la devise quand elle est donnée, et l'avoir de la facture" do
    EntrySpec.setup
    supplier = EntrySpec.card("SUPPLIER", "Orange Business")
    view = Api.post_received_invoice(system, received(supplier.code)).value!
    query(supplier, view.number, "86.40", "EUR").map(&.id).should eq([view.id])
    query(supplier, view.number, "86.40", "USD").should be_empty
    query(supplier, view.number, "-86.40").should be_empty
    # Numéro vide ou fait de séparateurs : rien n'est comparé.
    query(supplier, "  ", "86.40").should be_empty
    query(supplier, " - / . ", "86.40").should be_empty
  end

  it "normalise le numéro : casse, espaces et séparateurs usuels ignorés, autres caractères gardés" do
    EntrySpec.setup
    supplier = EntrySpec.card("SUPPLIER", "Orange Business")
    view = Api.post_received_invoice(system, received(supplier.code, number: "  FB-2026 0918/4471  ")).value!
    view.number.should eq("FB-2026 0918/4471")
    query(supplier, "fb_2026.0918-4471", "86.40").map(&.id).should eq([view.id])
    query(supplier, "FB#2026-0918-4471", "86.40").should be_empty
    query(supplier, "FB-2026-0918-447", "86.40").should be_empty
  end

  it "signale le doublon dès le contrôle instantané, pièce jointe encore absente, sans rien écrire" do
    EntrySpec.setup
    supplier = EntrySpec.card("SUPPLIER", "Orange Business")
    Api.post_received_invoice(system, received(supplier.code)).value!
    count = Api.count_entries(system)
    input = received(supplier.code, number: "fb 2026 0918 4471")
    input = input.copy_with(document: input.document.copy_with(attachment_id: nil))
    result = Api.check_received_invoice(system, input)
    result.errors.map { |error| {error.field, error.key} }.sort!.should eq([
      {"attachment_id", "accounting.errors.received_invoice.attachment.required"},
      {"number", "accounting.errors.received_invoice.duplicate"},
    ])
    duplicate = result.errors.find!(&.key.ends_with?("duplicate"))
    duplicate.params["date"].should eq("2026-09-24")
    Api.count_entries(system).should eq(count)
  end

  it "admet une même facture chez deux fournisseurs, ou deux montants chez le même" do
    EntrySpec.setup
    first = EntrySpec.card("SUPPLIER", "Orange Business")
    second = EntrySpec.card("SUPPLIER", "SFR Business")
    Api.post_received_invoice(system, received(first.code)).success?.should be_true
    Api.post_received_invoice(system, received(second.code)).success?.should be_true
    Api.post_received_invoice(system, received(first.code, amount: "72.01")).success?.should be_true
  end

  it "borne la référence de la plateforme et la garde sans blancs" do
    EntrySpec.setup
    supplier = EntrySpec.card("SUPPLIER", "Orange Business")
    Api.post_received_invoice(system, received(supplier.code, platform_reference: "x" * 101)).error_keys
      .should eq(["accounting.errors.received_invoice.platform_reference.too_long"])
    view = Api.post_received_invoice(system, received(supplier.code, origin: Api::ReceptionOrigin::Platform,
      platform_reference: "  inv_1  ")).value!
    view.platform_reference.should eq("inv_1")
  end

  it "ne montre la facture reçue qu'à qui lit son journal" do
    EntrySpec.setup
    supplier = EntrySpec.card("SUPPLIER", "Orange Business")
    view = Api.post_received_invoice(system, received(supplier.code)).value!
    expect_raises(Partiduo::Api::NotFound) { Api.received_invoice(system, 999_999_i64) }
    expect_raises(Partiduo::Api::Forbidden) { Api.received_invoice(actor_with, view.id) }
    expect_raises(Partiduo::Api::Forbidden) { Api.received_invoice_for_entry(actor_with, view.entry_id) }
    expect_raises(Partiduo::Api::Forbidden) do
      Api.check_received_invoice(actor_with("accounting.entry.read"), received(supplier.code))
    end
    expect_raises(Partiduo::Api::ModuleDisabled) do
      with_active_modules("invoicing") { Api.received_invoice(system, view.id) }
    end
  end

  it "ne rend que le signal de doublon à qui ne lit pas le journal de l'écriture (D-ACC-020)" do
    EntrySpec.setup
    supplier = EntrySpec.card("SUPPLIER", "Orange Business")
    view = Api.post_received_invoice(system, received(supplier.code)).value!
    full = query(supplier, view.number, "86.40").first
    {full.restricted, full.entry_id, full.supplier_code}.should eq({false, view.entry_id, supplier.code})
    # Utilisateur soumis aux droits par journal, sans accès au journal d'achats.
    user_id, actor = AccountingSpec.user_actor("comptable@example.com", "accounting.entry.post")
    Partiduo::Api::Auth.set_ledger_security(system, user_id, true).value!
    masked = Api.received_invoice_duplicates(actor, Api::DuplicateQuery.new(supplier.id, view.number,
      BigDecimal.new("86.40"))).first
    {masked.restricted, masked.id, masked.number}.should eq({true, view.id, view.number})
    {masked.entry_id, masked.ledger_code, masked.receipt, masked.supplier_name}.should eq({0_i64, "", nil, ""})
    {masked.total_amount, masked.attachment_id}.should eq({BigDecimal.new(0), nil})
  end

  it "garantit en base l'origine, le numéro, l'écriture unique et la fiche du fournisseur" do
    EntrySpec.setup
    supplier = EntrySpec.card("SUPPLIER", "Orange Business")
    view = Api.post_received_invoice(system, received(supplier.code)).value!
    other = EntrySpec.post_misc([EntrySpec.debit("603", "1"), EntrySpec.credit("510001", "1")])
    insert = "INSERT INTO accounting_received_invoice (entry_id, supplier_card_id, number, number_key, invoice_date, " \
             "total_amount, currency_code, origin, platform_reference, created_at) " \
             "VALUES ($1, $2, $3, $4, '2026-09-24', 1, 'EUR', $5, '', now())"
    expect_raises(Exception, /accounting_received_invoice_checks/) do
      EntrySpec.sql(insert, other.id, supplier.id, "F-1", "F1", "email")
    end
    expect_raises(Exception, /accounting_received_invoice_checks/) do
      EntrySpec.sql(insert, other.id, supplier.id, "  ", "X", "platform")
    end
    expect_raises(Exception, /accounting_received_invoice_supplier_fk/) do
      EntrySpec.sql(insert, other.id, 999_999_i64, "F-1", "F1", "platform")
    end
    expect_raises(Exception, /unique|duplicate/i) do
      EntrySpec.sql(insert, view.entry_id, supplier.id, "F-2", "F2", "platform")
    end
  end
end
