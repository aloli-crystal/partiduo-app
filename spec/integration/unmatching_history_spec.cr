# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Clôture du lot 2F (relecture) : délettrage et extourne signalés à la
# Facturation (`payment.unmatched`, D-2F-003) ; référence d'écriture unique
# en vigueur, écriture extournée recomptabilisable, événement écarté de
# l'historique (D-2F-006, D-2F-010).

private alias Acc = Partiduo::Api::Accounting
private alias Inv = Partiduo::Api::Invoicing
private alias I = IntegrationSpec

private def d(text : String) : BigDecimal
  BigDecimal.new(text)
end

private def customer_line_id(entry : Acc::EntryView, setup : InvoicingSpec::Setup) : Int64
  I.line(entry, I.card_account(setup.customer.id)).id
end

describe "Délettrage et extourne d'un encaissement (D-2F-003)" do
  it "retire de la facture les règlements d'un lettrage défait, puis les rend au nouveau lettrage" do
    with_active_modules(I::BOTH) do
      setup = I.setup
      invoice = InvoicingSpec.issued(setup)
      sale = I.entry("invoice:#{invoice.id}")
      line = customer_line_id(sale, setup)
      first = I.bank_receipt(setup.customer.code, "400", [line], "2026-09-20")
      second = I.bank_receipt(setup.customer.code, "619.76", [line], "2026-09-25")
      I.document(invoice.id).status.should eq("paid")
      matching_id = I.line(Acc.entry(I.system, sale.id), I.card_account(setup.customer.id)).matching_id || raise "non lettrée"

      InvoicingSpec.capture("payment.unmatched") do |events|
        Acc.unmatch(I.system, matching_id).value!
        events.size.should eq(1)
        events.first["matching_id"].should eq(matching_id.to_s)
        events.first["sources"].should eq("invoice:#{invoice.id}")
      end
      reopened = I.document(invoice.id)
      reopened.status.should eq("issued")
      reopened.totals.paid.should eq(BigDecimal.new(0))
      reopened.totals.amount_due.should eq(invoice.totals.total_gross)
      Inv.payments(InvoicingSpec.actor, invoice.id).should be_empty
      Inv.document_events(InvoicingSpec.actor, invoice.id).map(&.action).should contain("payment_removed")

      # Lettré de nouveau : la facture est de nouveau payée, une seule fois.
      customer_account = I.card_account(setup.customer.id)
      Acc.match_lines(I.system, [line, I.line(first, customer_account).id, I.line(second, customer_account).id]).value!
      paid = I.document(invoice.id)
      paid.status.should eq("paid")
      paid.totals.paid.should eq(invoice.totals.total_gross)
    end
  end

  it "retire le règlement quand l'écriture de banque lettrée est extournée" do
    with_active_modules(I::BOTH) do
      setup = I.setup
      invoice = InvoicingSpec.issued(setup)
      sale = I.entry("invoice:#{invoice.id}")
      bank = I.bank_receipt(setup.customer.code, "300", [customer_line_id(sale, setup)], "2026-09-20")
      I.document(invoice.id).status.should eq("partially_paid")

      InvoicingSpec.capture("payment.unmatched") do |events|
        Acc.cancel_entry(I.system, Acc::CancelEntryInput.new(bank.id)).value!
        events.size.should eq(1)
      end
      I.document(invoice.id).status.should eq("issued")
      I.document(invoice.id).totals.paid.should eq(BigDecimal.new(0))
    end
  end

  it "ne signale rien pour un lettrage sans paiement (avoir et facture), ni sans Facturation" do
    with_active_modules(I::BOTH) do
      setup = I.setup
      invoice = InvoicingSpec.issued(setup)
      credit = I.credit_note(setup, invoice.id)
      entry = I.entry("credit_note:#{credit.id}")
      matching_id = I.line(entry, I.card_account(setup.customer.id)).matching_id || raise "avoir non lettré"
      InvoicingSpec.capture("payment.unmatched") do |events|
        Acc.unmatch(I.system, matching_id).value!
        events.should be_empty
      end
      I.document(invoice.id).totals.credited.should eq(d("96"))
    end
    with_active_modules("accounting") do
      Partiduo::Events.subscribers("payment.unmatched").should be_empty
    end
  end
end

describe "Référence d'écriture et historique à comptabiliser (D-2F-006, D-2F-010)" do
  it "rend à l'historique une facture dont l'écriture est extournée, et la recomptabilise sous une pièce suffixée" do
    with_active_modules(I::BOTH) do
      setup = I.setup
      invoice = InvoicingSpec.issued(setup)
      sale = I.entry("invoice:#{invoice.id}")
      Acc.invoicing_history(I.system).should be_empty
      Acc.cancel_entry(I.system, Acc::CancelEntryInput.new(sale.id)).value!
      Partiduo::Accounting::Entry.filter(id: sale.id).first!.reversed.should be_true

      history = Acc.invoicing_history(I.system)
      history.map(&.source).should eq(["invoice:#{invoice.id}"])
      history.first.postable?.should be_true
      Acc.invoicing_history_count(I.system).should eq(1)
      posted = Acc.post_invoicing_history(I.system).value!.posted
      posted.map(&.source).should eq(["invoice:#{invoice.id}"])
      live = Acc.entries(I.system, Acc::EntryQuery.new(source: "invoice:#{invoice.id}", include_cancelled: false))
      live.size.should eq(1)
      again = live.first
      again.id.should_not eq(sale.id)
      again.receipt.should eq("#{invoice.number}-2")
      Acc.invoicing_history(I.system).should be_empty

      # Rejouer l'événement ne passe rien de plus.
      event = Partiduo::Events.journal(%w[invoice.issued]).first
      Partiduo::Accounting::Billing.post(I.system, event.name, event.payload).value!.should be_empty

      # L'encaissement se lettre avec la nouvelle écriture.
      I.bank_receipt(setup.customer.code, invoice.totals.total_gross.to_s, [customer_line_id(again, setup)])
      I.document(invoice.id).status.should eq("paid")
    end
  end

  it "écarte puis rend à l'historique un événement bloqué par une pièce saisie à la main" do
    with_active_modules(I::BOTH) do
      setup = I.setup
      Acc.post_sale(I.system, EntrySpec.document("V01", setup.customer.code, [EntrySpec.item("10", account: "706")],
        "2026-09-01", receipt: "F-2026-0001")).value!
      invoice = InvoicingSpec.issued(setup)
      I.entries("invoice:#{invoice.id}").should be_empty
      history = Acc.invoicing_history(I.system)
      history.first.errors.map(&.key).should contain("accounting.errors.entry.receipt.taken")

      event_id = history.first.event_id
      Acc.dismiss_invoicing_event(I.system, event_id, "Saisie manuelle F-2026-0001").value!
      Acc.invoicing_history(I.system).should be_empty
      Acc.invoicing_history_count(I.system).should eq(0)
      Acc.dismissed_invoicing_events(I.system).map(&.source).should eq(["invoice:#{invoice.id}"])
      Acc.dismiss_invoicing_event(I.system, event_id).error_keys.should eq(["accounting.errors.billing.already_dismissed"])

      Acc.restore_invoicing_event(I.system, event_id).value!
      Acc.invoicing_history(I.system).map(&.event_id).should eq([event_id])
      Acc.restore_invoicing_event(I.system, event_id).error_keys.should eq(["accounting.errors.billing.not_dismissed"])
      expect_raises(Partiduo::Api::NotFound) { Acc.dismiss_invoicing_event(I.system, 999_999_i64) }
      expect_raises(Partiduo::Api::Forbidden) { Acc.dismiss_invoicing_event(actor_with("accounting.entry.read"), event_id) }
    end
  end

  it "refuse d'écarter un événement comptabilisé" do
    with_active_modules(I::BOTH) do
      setup = I.setup
      InvoicingSpec.issued(setup)
      event = Partiduo::Events.journal(%w[invoice.issued]).first
      Acc.dismiss_invoicing_event(I.system, event.id).error_keys.should eq(["accounting.errors.billing.already_posted"])
    end
  end

  it "garantit en base qu'une référence n'a qu'une écriture en vigueur" do
    with_active_modules(I::BOTH) do
      setup = I.setup
      input = Acc::FinancialInput.new(ledger_id: Acc.ledger_by_code(I.system, "F01").id, date: I.date("2026-09-20"),
        source: "payment:999", lines: [Acc::PaymentLineInput.new(amount: d("10"), card: setup.customer.code)])
      first = Acc.post_financial(I.system, input).value!.first
      expect_raises(PQ::PQError, /accounting_entry_source/) { Acc.post_financial(I.system, input) }
      # Extournée, la référence se libère.
      Acc.cancel_entry(I.system, Acc::CancelEntryInput.new(first.id)).value!
      Acc.post_financial(I.system, input).success?.should be_true
      # Une écriture extournée le reste, même réenregistrée depuis un modèle relu avant l'extourne.
      InvoicingSpec.sql_error("UPDATE accounting_entry SET reversed = false WHERE id = $1", first.id).should be_nil
      Partiduo::Accounting::Entry.filter(id: first.id).first!.reversed.should be_true
    end
  end
end
