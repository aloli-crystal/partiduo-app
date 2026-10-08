# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Retours de marchandises (DECISIONS D-INV3-001 à D-INV3-006) : bon de
# retour, déduction sur la facture (récapitulative), avoir récapitulatif
# quand les retours l'emportent, avoir de bons de retour, encours HT.
private alias Inv = Partiduo::Api::Invoicing
private alias S = InvoicingSpec

private def d(text : String) : BigDecimal
  BigDecimal.new(text)
end

private def keys(result) : Array(String)
  result.errors.map(&.key)
end

# Bon de livraison émis le `on` : `hours` heures de conseil et `boxes`
# cartons de ramettes.
private def delivery(setup : S::Setup, on : String, hours : String = "1", boxes : String = "4") : Inv::DocumentView
  lines = [S.line(setup, hours), S.line(setup, boxes, item_card_id: setup.goods.id)]
  S.issue(S.draft(setup, "delivery_note", lines: lines).id, on)
end

# Saisie d'un bon de retour de `boxes` cartons (sans origine, ou tiré de
# `origin` par la transformation).
private def return_input(setup : S::Setup, boxes : String, reason : String? = "damaged") : Inv::DocumentInput
  S.document_input(setup, "return_note", lines: [S.line(setup, boxes, item_card_id: setup.goods.id)],
    return_reason: reason)
end

private def returned(setup : S::Setup, boxes : String, on : String, origin : Inv::DocumentView? = nil) : Inv::DocumentView
  draft = if origin
            Inv.transform(S.actor, origin.id, Inv::TransformInput.new("return_note")).value!
          else
            Inv.create_document(S.actor, return_input(setup, boxes)).value!
          end
  Inv.update_document(S.actor, draft.id, return_input(setup, boxes)).value!
  S.issue(draft.id, on)
end

private def monthly(setup : S::Setup) : Nil
  Inv.update_customer_billing(S.actor, setup.customer.id, Inv::CustomerBillingInput.new("monthly")).value!
end

describe "Bon de retour (D-INV3-001)" do
  it "se tire d'un bon de livraison, numérotation propre, motif obligatoire, quantités au plus égales aux livrées" do
    with_active_modules("invoicing") do
      setup = S.setup
      origin = delivery(setup, "2026-09-03")
      draft = Inv.transform(S.actor, origin.id, Inv::TransformInput.new("return_note")).value!
      draft.kind.should eq("return_note")
      draft.source.try(&.id).should eq(origin.id)
      draft.origin_mention.try(&.key).should eq("invoicing.links.from_delivery_note")
      draft.lines.map(&.quantity).should eq([d("1"), d("4")])

      # Au-delà des quatre cartons livrés : refusé.
      over = Inv.update_document(S.actor, draft.id, return_input(setup, "5"))
      keys(over).should eq(["invoicing.errors.return_note.exceeds_origin"])
      over.errors.first.params["delivered"].should eq("4")
      keys(Inv.update_document(S.actor, draft.id, return_input(setup, "-1")))
        .should eq(["invoicing.errors.return_note.quantity_negative"])
      keys(Inv.update_document(S.actor, draft.id, return_input(setup, "1", "lost")))
        .should eq(["invoicing.errors.document.return_reason.invalid"])
      keys(Inv.create_document(S.actor, S.document_input(setup, "invoice", return_reason: "damaged")))
        .should eq(["invoicing.errors.document.return_reason.return_note_only"])

      # Motif exigé à l'émission.
      Inv.update_document(S.actor, draft.id, return_input(setup, "3", nil)).value!
      keys(Inv.issue(S.actor, draft.id, Inv::IssueInput.new(issue_date: S.date("2026-09-05"))))
        .should eq(["invoicing.errors.issue.return_reason_required"])
      Inv.update_document(S.actor, draft.id, return_input(setup, "3")).value!
      note = S.issue(draft.id, "2026-09-05")
      note.number.should eq("BR-2026-0001")
      note.status.should eq("issued")
      note.return_reason.should eq("damaged")
      S.codes(note).should contain("dates.return")
      S.codes(note).should contain("return_note.reason.damaged")
      S.codes(note).should_not contain("operation_category.goods")
      Inv.verify_fingerprint(S.actor, note.id).should be_true

      # Un second retour de la même origine ne dépasse pas le reliquat.
      second = Inv.transform(S.actor, origin.id, Inv::TransformInput.new("return_note")).value!
      Inv.update_document(S.actor, second.id, return_input(setup, "1")).value!
      Inv.update_document(S.actor, second.id, return_input(setup, "2")).errors.first.params["returned"].should eq("3")
    end
  end

  it "publie return_note.issued, entre en stock avec le Stock, rien sans lui" do
    with_active_modules("invoicing,stock") do
      setup = S.setup
      StockSpec.repository("Entrepôt")
      Partiduo::Api::Stock.track_item(S.system, Partiduo::Api::Stock::ItemInput.new(setup.goods.id)).value!
      origin = delivery(setup, "2026-09-03")
      StockSpec.quantity(setup.goods).should eq(d("-4"))
      S.capture("return_note.issued") do |events|
        note = returned(setup, "3", "2026-09-05", origin)
        events.map(&.["return_note_id"]).should eq([note.id.to_s])
      end
      StockSpec.quantity(setup.goods).should eq(d("-1"))
    end
  end

  it "s'émet sans le module Stock, sans mouvement" do
    with_active_modules("invoicing") do
      setup = S.setup
      note = returned(setup, "2", "2026-09-05")
      note.status.should eq("issued")
      Marten::DB::Connection.default.open(&.scalar("SELECT count(*) FROM stock_movement")).as(Int64).should eq(0)
    end
  end
end

describe "Retours non encore facturés : bons à facturer et facture récapitulative (D-INV3-002, D-INV3-003)" do
  it "réduit les bons à facturer et l'encours HT, puis se déduit de la facture récapitulative du mois" do
    with_active_modules("invoicing,stock") do
      setup = S.setup
      StockSpec.repository("Entrepôt")
      Partiduo::Api::Stock.track_item(S.system, Partiduo::Api::Stock::ItemInput.new(setup.goods.id)).value!
      monthly(setup)
      Inv.update_customer_billing(S.actor, setup.customer.id, Inv::CustomerBillingInput.new("monthly", d("5000"))).value!
      first = delivery(setup, "2026-09-03")
      second = delivery(setup, "2026-09-10")
      back = returned(setup, "2", "2026-09-12", first)

      listed = Inv.delivery_notes_to_invoice(S.actor)
      listed.map(&.number).should eq([first.number, second.number, back.number])
      listed.last.kind.should eq("return_note")
      listed.last.total_net.should eq(-back.totals.total_net)
      listed.last.origin.try(&.id).should eq(first.id)

      billing = Inv.customer_billing(S.actor, setup.customer.id)
      billing.returns_count.should eq(1)
      billing.returns_net.should eq(back.totals.total_net)
      billing.exposure.should eq(first.totals.total_net + second.totals.total_net - back.totals.total_net)

      run = Inv.prepare_monthly_invoices(S.actor, Inv::MonthlyInput.new(month: S.date("2026-09-01")))
      run.prepared.size.should eq(1)
      run.prepared.first.invoice_kind.should eq("invoice")
      draft = Inv.document(S.actor, run.prepared.first.invoice_id || raise "sans facture")
      draft.kind.should eq("invoice")
      draft.summary_invoice?.should be_true
      draft.return_notes.map(&.number).should eq([back.number])
      draft.lines.map(&.kind).should eq(%w[title item item subtotal] * 2 + %w[title item subtotal])
      group = draft.lines[8..]
      group.first.description.should eq("Bon de retour #{back.number} du 12/09/2026")
      group.map(&.return_note_id).uniq!.should eq([back.id])
      group[1].quantity.should eq(d("-2"))
      group[2].net_amount.should eq(-back.totals.total_net)
      draft.totals.total_net.should eq(first.totals.total_net + second.totals.total_net - back.totals.total_net)
      Inv.document(S.actor, back.id).billed_in.try(&.id).should eq(draft.id)
      # Repris par le brouillon : plus repris ailleurs.
      keys(Inv.credit_return_notes(S.actor, [back.id])).should eq(["invoicing.errors.document.return_notes.in_draft"])
      # Encours inchangé à l'émission : la facture n'ajoute que la différence.
      Inv.credit_check(S.actor, draft.id).try(&.amount).should eq(d("0"))

      invoice = S.issue(draft.id, "2026-09-27")
      S.codes(invoice).should contain("return_notes.deducted")
      S.codes(invoice).should contain("delivery_notes.summary.fr")
      Inv.verify_fingerprint(S.actor, invoice.id).should be_true
      returned_note = Inv.document(S.actor, back.id)
      returned_note.status.should eq("invoiced")
      returned_note.status_key.should eq("invoicing.statuses.returned")
      Inv.delivery_notes_to_invoice(S.actor).should be_empty
      Inv.customer_billing(S.actor, setup.customer.id).returns_count.should eq(0)
      # Le stock n'est pas mouvementé une seconde fois.
      StockSpec.quantity(setup.goods).should eq(d("-6"))
      Partiduo::Api::Stock.movements(S.system, Partiduo::Api::Stock::MovementQuery.new(source: "invoice:#{invoice.id}"))
        .should be_empty

      # Factur-X : quantité négative (BT-129), bon de retour cité (BT-127).
      xml = String.new(Inv.facturx_xml(S.actor, invoice.id).content)
      items = xml.split("<ram:IncludedSupplyChainTradeLineItem>")[1..]
      items.size.should eq(5)
      items[4].should contain("<ram:Content>#{back.number}</ram:Content>")
      items[4].should match(/<ram:BilledQuantity unitCode="C62">-2\.0000</)
      xml.should contain("<ram:TypeCode>380</ram:TypeCode>")
    end
  end

  it "émet un avoir récapitulatif quand les retours du mois l'emportent sur les livraisons" do
    with_active_modules("invoicing") do
      setup = S.setup
      # Facture de juillet (déjà émise), retour en août plus fort que la livraison d'août.
      earlier = S.issued(setup, "invoice", "2026-07-30")
      monthly(setup)
      august = delivery(setup, "2026-08-05", "0.5", "1")
      back = returned(setup, "10", "2026-08-20")
      back.totals.total_gross.should be > august.totals.total_gross

      run = Inv.prepare_monthly_invoices(S.actor, Inv::MonthlyInput.new(month: S.date("2026-08-01")))
      run.prepared.first.invoice_kind.should eq("credit_note")
      credit = Inv.document(S.actor, run.prepared.first.invoice_id || raise "sans avoir")
      credit.kind.should eq("credit_note")
      credit.credited.try(&.id).should eq(earlier.id)
      credit.totals.total_gross.should eq(back.totals.total_gross - august.totals.total_gross)
      credit.lines.select(&.return_note_id).select(&.priced?).map(&.quantity).should eq([d("10")])
      credit.lines.select(&.delivery_note_id).select(&.priced?).map(&.quantity).should eq([d("-0.5"), d("-1")])
      Inv.monthly_proposals(S.actor).map(&.invoice_kind).should eq(["credit_note"])

      outcome = Inv.issue_and_send(S.actor, credit.id).value!
      issued = outcome.document
      issued.number.should eq("AV-2026-0001")
      S.codes(issued).should contain("return_notes.credited")
      S.codes(issued).should contain("delivery_notes.offset")
      Inv.document(S.actor, august.id).status.should eq("invoiced")
      Inv.document(S.actor, back.id).status.should eq("invoiced")
      Inv.document(S.actor, earlier.id).totals.credited.should eq(issued.totals.total_gross)
      xml = String.new(Inv.facturx_xml(S.actor, issued.id).content)
      xml.should contain("<ram:TypeCode>381</ram:TypeCode>")
      xml.should contain(earlier.number.to_s)
    end
  end

  it "refuse l'avoir récapitulatif sans facture à créditer ; la préparation échoue, motif à l'écran" do
    with_active_modules("invoicing") do
      setup = S.setup
      monthly(setup)
      returned(setup, "2", "2026-08-20")
      run = Inv.prepare_monthly_invoices(S.actor, Inv::MonthlyInput.new(month: S.date("2026-08-01")))
      run.prepared.first.status.should eq("failed")
      run.prepared.first.error.should eq("invoicing.errors.return_notes.no_invoice_to_credit")
    end
  end

  it "déduit un retour d'une facture de bons choisie à la main, et refuse les bons d'un autre client" do
    with_active_modules("invoicing") do
      setup = S.setup
      first = delivery(setup, "2026-09-03")
      back = returned(setup, "1", "2026-09-04", first)
      draft = Inv.invoice_delivery_notes(S.actor, [first.id, back.id]).value!
      draft.kind.should eq("invoice")
      draft.totals.total_net.should eq(first.totals.total_net - back.totals.total_net)
      Inv.delete_draft(S.actor, draft.id).value!
      Inv.document(S.actor, back.id).billed_in.should be_nil

      other = S.issued(setup, "delivery_note", "2026-09-05", customer_card_id: setup.private_customer.id)
      keys(Inv.invoice_delivery_notes(S.actor, [other.id, back.id]))
        .should eq(["invoicing.errors.delivery_notes.several_customers"])
    end
  end
end

describe "Avoir de bons de retour, hors facturation mensuelle (D-INV3-005)" do
  it "crédite la facture d'origine, regroupe plusieurs bons, ne mouvemente pas le stock une seconde fois" do
    with_active_modules("invoicing,stock") do
      setup = S.setup
      StockSpec.repository("Entrepôt")
      Partiduo::Api::Stock.track_item(S.system, Partiduo::Api::Stock::ItemInput.new(setup.goods.id)).value!
      invoice = S.issued(setup, "invoice", "2026-09-02")
      StockSpec.quantity(setup.goods).should eq(d("-2"))
      one = returned(setup, "1", "2026-09-04", invoice)
      two = returned(setup, "1", "2026-09-06", invoice)
      StockSpec.quantity(setup.goods).should eq(d("0"))
      third = Inv.transform(S.actor, invoice.id, Inv::TransformInput.new("return_note")).value!
      keys(Inv.update_document(S.actor, third.id, return_input(setup, "1")))
        .should eq(["invoicing.errors.return_note.exceeds_origin"])
      Inv.delete_draft(S.actor, third.id).value!

      draft = Inv.credit_return_notes(S.actor, [two.id, one.id]).value!
      draft.kind.should eq("credit_note")
      draft.credited.try(&.id).should eq(invoice.id)
      draft.return_notes.map(&.number).should eq([one.number, two.number])
      draft.lines.map(&.kind).should eq(%w[title item subtotal] * 2)
      credit = S.issue(draft.id, "2026-09-07")
      credit.totals.total_gross.should eq(one.totals.total_gross + two.totals.total_gross)
      S.codes(credit).should contain("return_notes.credited")
      S.codes(credit).should contain("credit_note.reference")
      Inv.document(S.actor, one.id).status.should eq("invoiced")
      Inv.document(S.actor, invoice.id).totals.credited.should eq(credit.totals.total_gross)
      StockSpec.quantity(setup.goods).should eq(d("0"))
      keys(Inv.credit_return_notes(S.actor, [one.id])).should eq(["invoicing.errors.document.return_notes.already_settled"])
    end
  end

  it "crédite la facture du bon de livraison d'origine, ou celle choisie ; refuse sans facture ni bon de retour" do
    with_active_modules("invoicing") do
      setup = S.setup
      note = delivery(setup, "2026-09-03")
      invoice = S.issue(Inv.invoice_delivery_notes(S.actor, [note.id]).value!.id, "2026-09-04")
      back = returned(setup, "1", "2026-09-05", note)
      Inv.credit_return_notes(S.actor, [back.id]).value!.credited.try(&.id).should eq(invoice.id)

      free = returned(setup, "1", "2026-09-06")
      other = S.issued(setup, "invoice", "2026-09-06")
      Inv.credit_return_notes(S.actor, [free.id], other.id).value!.credited.try(&.id).should eq(other.id)
      keys(Inv.credit_return_notes(S.actor, [note.id])).should eq(["invoicing.errors.document.return_notes.invalid"])

      input = return_input(setup, "1").copy_with(customer_card_id: setup.private_customer.id)
      lonely = S.issue(Inv.create_document(S.actor, input).value!.id, "2026-09-07")
      keys(Inv.credit_return_notes(S.actor, [lonely.id]))
        .should eq(["invoicing.errors.return_notes.no_invoice_to_credit"])
    end
  end
end
