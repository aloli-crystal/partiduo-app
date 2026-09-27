# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Synthèse du tableau de bord agrégée par PostgreSQL (D-2F-005) : mêmes
# chiffres que ceux qu'on calculerait en relisant chaque document.

private alias Api = Partiduo::Api::Invoicing

private def d(text : String) : BigDecimal
  BigDecimal.new(text)
end

private def actor : Partiduo::Api::Actor
  InvoicingSpec.actor
end

describe_module "INVOICING", "Facturation — synthèse du tableau de bord" do
  it "agrège factures ouvertes, échues, facturé du mois, devis et brouillons sans relire les documents" do
    setup = InvoicingSpec.setup
    late = InvoicingSpec.issued(setup, on: "2026-07-01") # échue le 31/07
    current = InvoicingSpec.issued(setup, on: "2026-09-15")
    credit = Api.transform(actor, current.id, Api::TransformInput.new("credit_note")).value!
    Api.update_document(actor, credit.id, InvoicingSpec.document_input(setup, "credit_note",
      credited_document_id: current.id, lines: [InvoicingSpec.line(setup, "1")])).value!
    InvoicingSpec.issue(credit.id, "2026-09-16")
    InvoicingSpec.issued(setup, "quote", on: "2026-09-10")                                                  # valable
    InvoicingSpec.issued(setup, "quote", on: "2026-09-11", validity_date: InvoicingSpec.date("2026-09-20")) # périmé
    InvoicingSpec.draft(setup)

    summary = Api.summary(actor)
    summary.on.should eq(InvoicingSpec.date("2026-09-27"))
    summary.open_count.should eq(2)
    summary.open_amount.should eq(late.totals.total_gross + current.totals.total_gross - d("96"))
    summary.overdue_count.should eq(1)
    summary.overdue_amount.should eq(late.totals.total_gross)
    summary.overdue_customers.should eq(["Client Pro SARL"])
    summary.billed_net.should eq(current.totals.total_net - d("80"))
    summary.billed_invoices.should eq(1)
    summary.billed_credit_notes.should eq(1)
    summary.quotes_waiting_count.should eq(1)
    summary.quotes_waiting_net.should eq(d("849.8"))
    summary.quotes_expired.should eq(1)
    summary.drafts.should eq(1)
    summary.recent_invoices.map(&.number).should eq([nil, current.number, late.number])
    summary.recent_invoices.map(&.effective_status).should eq(["draft", "issued", "overdue"])
    summary.recent_invoices[1].amount_due.should eq(current.totals.total_gross - d("96"))
    summary.recent_invoices.first.customer_name.should eq("Client Pro SARL")

    # Mêmes chiffres qu'en relisant chaque document.
    open = Api::FISCAL_KINDS.flat_map { |kind| Api.documents(actor, Api::DocumentQuery.new(kind: kind)) }
      .select { |doc| doc.kind != "credit_note" && !doc.draft? && doc.totals.amount_due.positive? && doc.effective_status != "cancelled" }
    summary.open_amount.should eq(open.sum(BigDecimal.new(0), &.totals.amount_due))

    # Au 1er octobre : rien de facturé dans le mois ; la facture de septembre est échue ou non selon sa date.
    october = Api.summary(actor, InvoicingSpec.date("2026-10-20"))
    october.billed_net.should eq(BigDecimal.new(0))
    october.overdue_count.should eq(2)
  end

  it "exige la lecture des documents" do
    InvoicingSpec.setup
    expect_raises(Partiduo::Api::Forbidden) { Api.summary(actor_with("cards.card.read")) }
  end
end
