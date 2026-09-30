# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Facture récapitulative et facturation mensuelle des bons de livraison
# (art. 289-I-3 du CGI), DECISIONS D-INV2-001 à D-INV2-008. Chaque exemple
# fixe ses modules actifs.
private alias Inv = Partiduo::Api::Invoicing
private alias S = InvoicingSpec

private def d(text : String) : BigDecimal
  BigDecimal.new(text)
end

# Bon de livraison émis le `on` (livré le même jour), `quantity` heures de
# conseil et deux cartons.
private def note(setup : S::Setup, on : String, quantity : String = "1", customer = nil) : Inv::DocumentView
  lines = [S.line(setup, quantity), S.line(setup, "2", item_card_id: setup.goods.id)]
  customer_id = customer ? customer.as(Partiduo::Api::Cards::CardView).id : setup.customer.id
  S.issue(S.draft(setup, "delivery_note", lines: lines, customer_card_id: customer_id).id, on)
end

private def to_invoice(query = Inv::ToInvoiceQuery.new) : Array(Inv::ToInvoiceView)
  Inv.delivery_notes_to_invoice(S.actor, query)
end

private def credit(id : Int64) : Inv::CreditCheckView
  Inv.credit_check(S.actor, id) || raise "sans contrôle d'encours"
end

private def keys(result) : Array(String)
  result.errors.map(&.key)
end

describe "Facture récapitulative de plusieurs bons de livraison (D-INV2-001 à D-INV2-003)" do
  it "regroupe les bons d'un client : un groupe de lignes par bon, période de facturation, bons facturés à l'émission" do
    with_active_modules("invoicing") do
      setup = S.setup
      first = note(setup, "2026-09-03", "1")
      second = note(setup, "2026-09-10", "2")
      third = note(setup, "2026-09-17", "3")
      to_invoice.map(&.number).should eq([first.number, second.number, third.number])

      draft = Inv.invoice_delivery_notes(S.actor, [third.id, first.id, second.id]).value!
      draft.kind.should eq("invoice")
      draft.source.should be_nil
      draft.delivery_notes.map(&.number).should eq([first.number, second.number, third.number])
      draft.billing_period_start.should eq(S.date("2026-09-03"))
      draft.billing_period_end.should eq(S.date("2026-09-17"))
      draft.delivery_date.should eq(S.date("2026-09-17"))
      draft.summary_invoice?.should be_true
      # Titre, deux lignes et sous-total par bon, du premier livré au dernier.
      draft.lines.map(&.kind).should eq(%w[title item item subtotal] * 3)
      draft.lines.first.description.should eq("Bon de livraison #{first.number} du 03/09/2026")
      draft.lines.map(&.delivery_note_id).uniq!.should eq([first.id, second.id, third.id])
      draft.lines[3].net_amount.should eq(first.totals.total_net)
      draft.totals.total_net.should eq(first.totals.total_net + second.totals.total_net + third.totals.total_net)
      # Repris par un brouillon : plus sélectionnables pour une autre facture.
      to_invoice.map(&.draft_invoice_id).uniq!.should eq([draft.id])
      keys(Inv.invoice_delivery_notes(S.actor, [first.id, second.id])).should eq(["invoicing.errors.document.delivery_notes.in_draft"] * 2)

      invoice = S.issue(draft.id, "2026-09-27")
      S.codes(invoice).should contain("dates.delivery_period")
      S.codes(invoice).should_not contain("dates.delivery")
      S.codes(invoice).should contain("delivery_notes.summary.fr")
      summary = invoice.mentions.find! { |mention| mention.code == "delivery_notes.summary.fr" }
      summary.params["numbers"].should eq([first, second, third].map(&.number).join(", "))
      invoice.mentions.find! { |mention| mention.code == "dates.delivery_period" }.params
        .should eq({"from" => "2026-09-03", "to" => "2026-09-17"})
      Inv.verify_fingerprint(S.actor, invoice.id).should be_true

      [first, second, third].each do |delivered|
        Inv.document(S.actor, delivered.id).status.should eq("invoiced")
        Inv.document_events(S.actor, delivered.id).map(&.action).should contain("invoiced")
      end
      to_invoice.should be_empty
      keys(Inv.invoice_delivery_notes(S.actor, [first.id, second.id])).should eq(["invoicing.errors.document.delivery_notes.already_billed"] * 2)
      keys(Inv.transform(S.actor, first.id, Inv::TransformInput.new("invoice")))
        .should eq(["invoicing.errors.document.delivery_notes.already_billed"])

      # Lien figé avec la facture émise.
      S.sql_error("DELETE FROM invoicing_billed_delivery WHERE invoice_id = $1", invoice.id).should_not be_nil
    end
  end

  it "écrit la période (BG-14), le bon et la date de livraison de chaque ligne (BG-26, BT-127) dans le Factur-X" do
    with_active_modules("invoicing") do
      setup = S.setup
      first = note(setup, "2026-09-03")
      second = note(setup, "2026-09-10")
      invoice = S.issue(Inv.invoice_delivery_notes(S.actor, [first.id, second.id]).value!.id, "2026-09-27")
      xml = String.new(Inv.facturx_xml(S.actor, invoice.id).content)
      header = xml.split("<ram:ApplicableHeaderTradeSettlement>").last
      header.should contain("<ram:BillingSpecifiedPeriod>")
      header.should match(/<ram:StartDateTime>\s*<udt:DateTimeString format="102">20260903</m)
      header.should match(/<ram:EndDateTime>\s*<udt:DateTimeString format="102">20260910</m)
      xml.should_not contain("ActualDeliverySupplyChainEvent")
      items = xml.split("<ram:IncludedSupplyChainTradeLineItem>")[1..]
      items.size.should eq(4)
      items[0].should contain("<ram:Content>#{first.number}</ram:Content>")
      items[0].should match(/<ram:StartDateTime>\s*<udt:DateTimeString format="102">20260903</m)
      items[3].should contain("<ram:Content>#{second.number}</ram:Content>")
      items[3].should match(/<ram:EndDateTime>\s*<udt:DateTimeString format="102">20260910</m)
    end
  end

  it "facture un seul bon comme la transformation : lien d'origine, date de livraison du bon, un bon ne se facture qu'une fois" do
    with_active_modules("invoicing") do
      setup = S.setup
      delivered = note(setup, "2026-09-03")
      draft = Inv.invoice_delivery_notes(S.actor, [delivered.id]).value!
      draft.source.try(&.id).should eq(delivered.id)
      draft.delivery_date.should eq(S.date("2026-09-03"))
      draft.billing_period_start.should be_nil
      draft.delivery_notes.map(&.id).should eq([delivered.id])
      keys(Inv.transform(S.actor, delivered.id, Inv::TransformInput.new("invoice")))
        .should eq(["invoicing.errors.document.delivery_notes.in_draft"])
      # Le brouillon supprimé libère le bon.
      Inv.delete_draft(S.actor, draft.id).success?.should be_true
      to_invoice.map(&.id).should eq([delivered.id])
      invoice = S.issue(Inv.transform(S.actor, delivered.id, Inv::TransformInput.new("invoice")).value!.id, "2026-09-27")
      S.codes(invoice).should contain("dates.delivery")
      Inv.document(S.actor, delivered.id).status.should eq("invoiced")
    end
  end

  it "retirer le groupe d'un bon du brouillon le libère ; ses lignes gardent le bon à la modification" do
    with_active_modules("invoicing") do
      setup = S.setup
      first = note(setup, "2026-09-03")
      second = note(setup, "2026-09-10")
      draft = Inv.invoice_delivery_notes(S.actor, [first.id, second.id]).value!
      kept = draft.lines.select { |line| line.delivery_note_id == first.id }.map do |line|
        Inv::LineInput.new(kind: line.kind, item_card_id: line.item_card_id, description: line.description,
          quantity: line.priced? ? line.quantity : d("1"), unit_price: line.priced? ? line.unit_price : nil,
          vat_rate_id: line.vat_rate_id, delivery_note_id: line.delivery_note_id)
      end
      extra = S.line(setup, "1")
      updated = Inv.update_document(S.actor, draft.id, S.document_input(setup, lines: kept + [extra])).value!
      updated.delivery_notes.map(&.id).should eq([first.id])
      updated.billing_period_start.should be_nil
      to_invoice.find! { |row| row.id == second.id }.draft_invoice_id.should be_nil
    end
  end

  it "refuse une sélection vide, en double, de plusieurs clients, un bon en brouillon ou d'une autre nature" do
    with_active_modules("invoicing") do
      setup = S.setup
      first = note(setup, "2026-09-03")
      other = note(setup, "2026-09-04", customer: setup.private_customer)
      keys(Inv.invoice_delivery_notes(S.actor, [] of Int64)).should eq(["invoicing.errors.delivery_notes.empty"])
      keys(Inv.invoice_delivery_notes(S.actor, [first.id, first.id])).should eq(["invoicing.errors.delivery_notes.duplicate"])
      keys(Inv.invoice_delivery_notes(S.actor, [first.id, other.id])).should eq(["invoicing.errors.delivery_notes.several_customers"])
      draft_note = S.draft(setup, "delivery_note")
      keys(Inv.invoice_delivery_notes(S.actor, [first.id, draft_note.id])).should eq(["invoicing.errors.document.delivery_notes.invalid"])
      order = S.issued(setup, "order", "2026-09-05")
      keys(Inv.invoice_delivery_notes(S.actor, [first.id, order.id])).should eq(["invoicing.errors.document.delivery_notes.invalid"])
      # Une ligne ne cite un bon que sur une facture, et un bon du même client.
      bad = S.document_input(setup, "quote", lines: [S.line(setup, "1", delivery_note_id: first.id)])
      keys(Inv.create_document(S.actor, bad)).should eq(["invoicing.errors.document.delivery_notes.invoice_only"])
      foreign = S.document_input(setup, lines: [S.line(setup, "1", delivery_note_id: other.id)])
      keys(Inv.create_document(S.actor, foreign)).should eq(["invoicing.errors.document.delivery_notes.other_customer"])
    end
  end

  it "filtre la liste des bons à facturer par client et par période de livraison" do
    with_active_modules("invoicing") do
      setup = S.setup
      first = note(setup, "2026-09-03")
      second = note(setup, "2026-09-12")
      other = note(setup, "2026-09-13", customer: setup.private_customer)
      to_invoice(Inv::ToInvoiceQuery.new(customer_card_id: setup.customer.id)).map(&.id).should eq([first.id, second.id])
      to_invoice(Inv::ToInvoiceQuery.new(from: S.date("2026-09-10"), to: S.date("2026-09-12"))).map(&.id).should eq([second.id])
      row = to_invoice(Inv::ToInvoiceQuery.new(customer_card_id: setup.private_customer.id)).first
      row.id.should eq(other.id)
      row.customer_name.should eq("Jeanne Martin")
      row.total_net.should eq(other.totals.total_net)
      row.billing_rhythm.should eq("per_delivery")
    end
  end
end

describe "Réglage client : rythme de facturation et encours maximum HT (D-INV2-004, D-INV2-005)" do
  it "enregistre le rythme et le plafond ; refuse un rythme inconnu, un plafond négatif, une fiche qui n'est pas un client" do
    with_active_modules("invoicing") do
      setup = S.setup
      view = Inv.customer_billing(S.actor, setup.customer.id)
      view.billing_rhythm.should eq("per_delivery")
      view.credit_limit.should be_nil
      saved = Inv.update_customer_billing(S.actor, setup.customer.id,
        Inv::CustomerBillingInput.new("monthly", d("5000"))).value!
      saved.monthly?.should be_true
      saved.credit_limit.should eq(d("5000"))
      keys(Inv.update_customer_billing(S.actor, setup.customer.id, Inv::CustomerBillingInput.new("weekly")))
        .should eq(["invoicing.errors.customer_billing.rhythm"])
      keys(Inv.update_customer_billing(S.actor, setup.customer.id, Inv::CustomerBillingInput.new("monthly", d("-1"))))
        .should eq(["invoicing.errors.customer_billing.credit_limit"])
      keys(Inv.update_customer_billing(S.actor, setup.item.id, Inv::CustomerBillingInput.new))
        .should eq(["invoicing.errors.document.customer.not_customer"])
      reader = Partiduo::Api::Actor.user(8_i64, ["invoicing.invoice.read", "invoicing.invoice.write"])
      expect_raises(Partiduo::Api::Forbidden) do
        Inv.update_customer_billing(reader, setup.customer.id, Inv::CustomerBillingInput.new)
      end
    end
  end

  it "compte l'encours HT : bons non facturés + part HT restant due des factures (règlement partiel au prorata)" do
    with_active_modules("invoicing") do
      setup = S.setup
      delivered = note(setup, "2026-09-03", "1")         # 80 + 49,80 = 129,80 HT ; 155,76 TTC
      invoice = S.issued(setup, "invoice", "2026-09-05") # 849,80 HT ; 1 019,76 TTC
      Inv.record_payment(S.actor, Inv::PaymentInput.new(invoice.id, d("509.88"), S.date("2026-09-20"))).value!
      view = Inv.customer_billing(S.actor, setup.customer.id)
      view.unbilled_count.should eq(1)
      view.unbilled_net.should eq(delivered.totals.total_net)
      view.unbilled_gross.should eq(delivered.totals.total_gross)
      view.receivable_net.should eq(d("424.90")) # moitié du HT restant due
      view.exposure.should eq(d("554.70"))
      view.currency_code.should eq("EUR")
      view.percent_used.should be_nil
    end
  end
end

describe "Encours maximum HT : contrôle à l'émission, dérogation motivée (D-INV2-009)" do
  it "refuse l'émission d'un bon de livraison, d'une commande ou d'une facture au-delà du plafond ; le devis n'est pas bloqué" do
    with_active_modules("invoicing") do
      setup = S.setup
      Inv.update_customer_billing(S.actor, setup.customer.id, Inv::CustomerBillingInput.new("per_delivery", d("1000"))).value!
      first = note(setup, "2026-09-03", "5")                               # 449,80 HT
      draft = S.draft(setup, "delivery_note", lines: [S.line(setup, "8")]) # 640 HT
      check = credit(draft.id)
      check.exposure.should eq(first.totals.total_net)
      check.amount.should eq(d("640"))
      check.exceeded?.should be_true
      check.excess.should eq(d("89.80"))
      result = Inv.issue(S.actor, draft.id, Inv::IssueInput.new(issue_date: S.date("2026-09-10")))
      keys(result).should eq(["invoicing.errors.credit_limit.exceeded"])
      result.errors.first.params.should eq({"customer" => "Client Pro SARL", "exposure" => "449.80", "amount" => "640.00",
                                            "limit" => "1000.00", "excess" => "89.80", "currency" => "EUR"})
      %w[order invoice].each do |kind|
        other = S.draft(setup, kind, lines: [S.line(setup, "8")])
        keys(Inv.issue(S.actor, other.id, Inv::IssueInput.new(issue_date: S.date("2026-09-10"))))
          .should eq(["invoicing.errors.credit_limit.exceeded"])
      end
      quote = S.draft(setup, "quote", lines: [S.line(setup, "8")])
      credit(quote.id).controlled.should be_false
      S.issue(quote.id, "2026-09-10").status.should eq("sent")
      # La facture des bons déjà livrés n'ajoute rien à l'encours.
      invoice = Inv.transform(S.actor, first.id, Inv::TransformInput.new("invoice")).value!
      credit(invoice.id).amount.should eq(d("0"))
      S.issue(invoice.id, "2026-09-11").status.should eq("issued")
    end
  end

  it "admet la dérogation motivée d'un utilisateur autorisé, tracée ; la refuse sans permission ou sans motif" do
    with_active_modules("invoicing") do
      setup = S.setup
      Inv.update_customer_billing(S.actor, setup.customer.id, Inv::CustomerBillingInput.new("per_delivery", d("100"))).value!
      draft = S.draft(setup, "delivery_note", lines: [S.line(setup, "2")])
      input = Inv::IssueInput.new(issue_date: S.date("2026-09-10"), credit_override_reason: "  ")
      keys(Inv.issue(S.actor, draft.id, input)).should eq(["invoicing.errors.credit_limit.exceeded"])
      input = input.copy_with(credit_override_reason: "Client historique, accord du gérant")
      keys(Inv.issue(S.actor, draft.id, input)).should eq(["invoicing.errors.credit_limit.override_denied"])
      manager = Partiduo::Api::Actor.user(9_i64, S::PERMISSIONS + [Inv::CREDIT_OVERRIDE])
      issued = Inv.issue(manager, draft.id, input).value!
      issued.status.should eq("issued")
      trace = Inv.document_events(S.actor, draft.id).find! { |event| event.action == "credit_override" }
      trace.user_id.should eq(9_i64)
      trace.details["reason"].should eq("Client historique, accord du gérant")
      trace.details["excess"].should eq("60.00")
    end
  end

  it "signale les clients au-delà de 90 % de leur plafond" do
    with_active_modules("invoicing") do
      setup = S.setup
      Inv.update_customer_billing(S.actor, setup.customer.id, Inv::CustomerBillingInput.new("monthly", d("140"))).value!
      Inv.update_customer_billing(S.actor, setup.private_customer.id, Inv::CustomerBillingInput.new("per_delivery", d("10000"))).value!
      note(setup, "2026-09-03", "1") # 129,80 HT : 92 %
      note(setup, "2026-09-04", "1", customer: setup.private_customer)
      alerts = Inv.credit_alerts(S.actor)
      alerts.map(&.customer_card_id).should eq([setup.customer.id])
      alerts.first.percent_used.should eq(92)
      alerts.first.near_limit?.should be_true
      alerts.first.exceeded?.should be_false
    end
  end
end

describe "Fin de mois : factures récapitulatives des clients mensuels (D-INV2-007, D-INV2-008)" do
  it "prépare un brouillon par client mensuel, idempotent ; les clients à chaque livraison n'en reçoivent pas" do
    with_active_modules("invoicing") do
      setup = S.setup
      Inv.update_customer_billing(S.actor, setup.customer.id, Inv::CustomerBillingInput.new("monthly")).value!
      first = note(setup, "2026-09-03")
      second = note(setup, "2026-09-17")
      note(setup, "2026-09-18", customer: setup.private_customer)
      run = Inv.prepare_monthly_invoices(S.actor, Inv::MonthlyInput.new(month: S.date("2026-09-15")))
      run.prepared.size.should eq(1)
      prepared = run.prepared.first
      prepared.status.should eq("proposed")
      prepared.customer_card_id.should eq(setup.customer.id)
      invoice = Inv.document(S.actor, prepared.invoice_id || raise "sans facture")
      invoice.delivery_notes.map(&.id).should eq([first.id, second.id])
      Inv.monthly_proposals(S.actor).map(&.invoice_id).should eq([invoice.id])

      again = Inv.prepare_monthly_invoices(S.actor, Inv::MonthlyInput.new(month: S.date("2026-09-30")))
      again.prepared.should be_empty
      again.skipped.should eq(0) # bons déjà repris : plus rien à préparer
      # Un brouillon supprimé : le mois n'est pas repris pour ce client.
      Inv.delete_draft(S.actor, invoice.id).success?.should be_true
      third = Inv.prepare_monthly_invoices(S.actor, Inv::MonthlyInput.new(month: S.date("2026-09-30")))
      third.prepared.should be_empty
      third.skipped.should eq(1)
      Inv.monthly_proposals(S.actor).should be_empty
      # « Facturer le mois » d'un client à chaque livraison, à la demande.
      single = Inv.prepare_monthly_invoices(S.actor, Inv::MonthlyInput.new(month: S.date("2026-09-30"),
        customer_card_id: setup.private_customer.id))
      single.prepared.map(&.customer_card_id).should eq([setup.private_customer.id])
    end
  end

  it "passe le dernier jour du mois, rattrape un mois manqué, ne repasse jamais un mois clos" do
    with_active_modules("invoicing") do
      setup = S.setup
      Inv.update_customer_billing(S.actor, setup.customer.id, Inv::CustomerBillingInput.new("monthly")).value!
      august = note(setup, "2026-08-28")
      # Le 15 septembre : août n'est pas clos, il est rattrapé.
      run = Inv.month_end(S.actor, S.date("2026-09-15"))
      run.months.should eq([S.date("2026-08-01")])
      Inv.document(S.actor, run.prepared.first.invoice_id || raise "sans facture").delivery_notes.map(&.id).should eq([august.id])
      Inv.month_end(S.actor, S.date("2026-09-16")).months.should be_empty
      september = note(setup, "2026-09-20")
      Inv.month_end(S.actor, S.date("2026-09-29")).months.should be_empty
      last = Inv.month_end(S.actor, S.date("2026-09-30"))
      last.months.should eq([S.date("2026-09-01")])
      Inv.document(S.actor, last.prepared.first.invoice_id || raise "sans facture").delivery_notes.map(&.id).should eq([september.id])
      Inv.month_end(S.actor, S.date("2026-09-30")).prepared.should be_empty
      Inv.month_end(S.actor, S.date("2026-10-01")).months.should be_empty
    end
  end

  it "émet et envoie d'office en mode automatique, par le canal de chaque client" do
    with_active_modules("invoicing") do
      setup = S.setup
      settings = Inv.settings(S.actor).to_input.copy_with(monthly_billing_mode: "auto_send", sender_email: "factures@exemple.test")
      Inv.update_settings(S.actor, settings).value!
      Inv.update_customer_billing(S.actor, setup.customer.id, Inv::CustomerBillingInput.new("monthly")).value!
      Inv.update_customer_billing(S.actor, setup.private_customer.id, Inv::CustomerBillingInput.new("monthly")).value!
      note(setup, "2026-09-03")
      note(setup, "2026-09-04", customer: setup.private_customer)
      transport = Inv::MemoryTransport.new
      previous = Inv.mail_transport
      Inv.mail_transport = transport
      begin
        run = Inv.month_end(Partiduo::Api::Actor.system, S.date("2026-09-30"))
        by_customer = run.prepared.to_h { |row| {row.customer_card_id, row} }
        # Professionnel : plateforme agréée ; particulier sans adresse : papier.
        pro = by_customer[setup.customer.id]
        pro.status.should eq("issued")
        Inv.document(S.actor, pro.invoice_id || raise "sans facture").issue_channel.should eq("platform")
        particular = by_customer[setup.private_customer.id]
        particular.invoice_number.should_not be_nil
        Inv.document(S.actor, particular.invoice_id || raise "sans facture").issue_channel.should eq("paper")
        Inv.monthly_proposals(S.actor).should be_empty
        transport.messages.should be_empty
      ensure
        Inv.mail_transport = previous
      end
    end
  end

  it "émet et envoie par courriel d'un clic une facture proposée" do
    with_active_modules("invoicing") do
      setup = S.setup
      Inv.update_settings(S.actor, Inv.settings(S.actor).to_input.copy_with(sender_email: "factures@exemple.test")).value!
      note(setup, "2026-09-03")
      note(setup, "2026-09-10")
      draft = Inv.prepare_monthly_invoices(S.actor, Inv::MonthlyInput.new(customer_card_id: setup.customer.id))
        .prepared.first.invoice_id || raise "sans facture"
      Inv.set_issue_channel(S.actor, draft, Inv::ChannelInput.new("email")).value!
      transport = Inv::MemoryTransport.new
      previous = Inv.mail_transport
      Inv.mail_transport = transport
      begin
        results = Inv.issue_and_send_proposals(S.actor)
        results.size.should eq(1)
        outcome = results.first.value!
        outcome.action.should eq("emailed")
        outcome.detail.should eq("compta@client.test")
        outcome.document.status.should eq("sent")
        transport.messages.size.should eq(1)
        keys(Inv.issue_and_send(S.actor, outcome.document.delivery_notes.first.id)).should eq(["invoicing.errors.dispatch.kind"])
      ensure
        Inv.mail_transport = previous
      end
    end
  end
end
