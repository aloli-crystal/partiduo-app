# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias Acc = Partiduo::Api::Accounting
private alias Inv = Partiduo::Api::Invoicing
private alias I = IntegrationSpec

private def d(text : String) : BigDecimal
  BigDecimal.new(text)
end

# ADR-006 D3, D7 : la synchronisation par événements, de bout en bout, dans
# les trois configurations de modules. Chaque groupe fixe sa configuration
# (`with_active_modules`), comme les specs de règlements de la Facturation :
# le parcours se vérifie quelle que soit la configuration de la CI.
describe "Facturation et Comptabilité actives — de bout en bout" do
  it "devis → facture émise → écriture de vente → encaissement lettré → facture payée" do
    with_active_modules(I::BOTH) do
      setup = I.setup
      quote = InvoicingSpec.issued(setup, "quote", "2026-09-10")
      draft = Inv.transform(InvoicingSpec.actor, quote.id, Inv::TransformInput.new("invoice")).value!
      invoice = InvoicingSpec.issue(draft.id, "2026-09-15")
      invoice.totals.total_gross.should eq(d("1019.76"))

      # Écriture de vente : articles au compte de leur fiche, TVA, client.
      sale = I.entry("invoice:#{invoice.id}")
      sale.ledger_code.should eq("V01")
      sale.receipt.should eq(invoice.number)
      sale.date.should eq(I.date("2026-09-15"))
      customer_account = I.card_account(setup.customer.id)
      lines = I.by_account(sale)
      lines[customer_account].should eq([{"debit", d("1019.76")}])
      lines[I.card_account(setup.item.id)].should eq([{"credit", d("800")}])
      lines[I.card_account(setup.goods.id)].should eq([{"credit", d("49.8")}])
      lines["44571"].should eq([{"credit", d("169.96")}])
      sale.lines.find! { |line| line.account_number == customer_account }.card_code.should eq(setup.customer.code)

      # Encaissement partiel puis solde, lettrés en banque.
      customer_line = I.line(sale, customer_account).id
      InvoicingSpec.capture("payment.matched") do |events|
        I.bank_receipt(setup.customer.code, "400", [customer_line], "2026-09-20")
        events.last["amounts"].should eq("invoice:#{invoice.id}=400.0")
        events.last["matched_on"].should eq("2026-09-20")
        partial = I.document(invoice.id)
        partial.status.should eq("partially_paid")
        partial.totals.paid.should eq(d("400"))

        I.bank_receipt(setup.customer.code, "619.76", [customer_line], "2026-09-25")
        events.last["amounts"].should eq("invoice:#{invoice.id}=619.76")
      end
      paid = I.document(invoice.id)
      paid.status.should eq("paid")
      paid.totals.amount_due.should eq(BigDecimal.new(0))
      Inv.payments(InvoicingSpec.actor, invoice.id).map(&.amount).should eq([d("400"), d("619.76")])
      Inv.payments(InvoicingSpec.actor, invoice.id).last.paid_on.should eq(I.date("2026-09-25"))
      Acc.entry(I.system, sale.id).lines.find! { |line| line.id == customer_line }.matching_id.should_not be_nil
      Acc.invoicing_history(I.system).should be_empty
    end
  end

  it "passe l'avoir en négatif, lettré avec sa facture ; l'encaissement du reste solde la facture" do
    with_active_modules(I::BOTH) do
      setup = I.setup
      invoice = InvoicingSpec.issued(setup)
      credit = I.credit_note(setup, invoice.id) # une heure : 80 HT, 96 TTC
      entry = I.entry("credit_note:#{credit.id}")
      entry.receipt.should eq(credit.number)
      customer_account = I.card_account(setup.customer.id)
      lines = I.by_account(entry)
      lines[customer_account].should eq([{"credit", d("96")}])
      lines[I.card_account(setup.item.id)].should eq([{"debit", d("80")}])
      lines["44571"].should eq([{"debit", d("16")}])

      sale = I.entry("invoice:#{invoice.id}")
      matching_id = I.line(entry, customer_account).matching_id || raise "avoir non lettré"
      Acc.matching(I.system, matching_id).lines.map(&.entry_id).sort!.should eq([sale.id, entry.id].sort!)

      due = I.document(invoice.id).totals.amount_due
      due.should eq(d("923.76"))
      I.bank_receipt(setup.customer.code, due.to_s, [I.line(sale, customer_account).id])
      paid = I.document(invoice.id)
      paid.status.should eq("paid")
      paid.totals.paid.should eq(d("923.76"))
      settled = I.line(Acc.entry(I.system, sale.id), customer_account).matching_id || raise "facture non lettrée"
      Acc.matching(I.system, settled).balanced?.should be_true
    end
  end

  it "extourne l'acompte sur la facture finale, dont le client ne porte que le solde" do
    with_active_modules(I::BOTH) do
      setup = I.setup
      order = InvoicingSpec.issued(setup, "order")
      deposit = Inv.transform(InvoicingSpec.actor, order.id,
        Inv::TransformInput.new("deposit_invoice", deposit_percent: d("40"))).value!
      deposit = InvoicingSpec.issue(deposit.id, "2026-09-16")
      deposit_entry = I.entry("invoice:#{deposit.id}")
      customer_account = I.card_account(setup.customer.id)
      I.bank_receipt(setup.customer.code, deposit.totals.total_gross.to_s, [I.line(deposit_entry, customer_account).id])
      I.document(deposit.id).status.should eq("paid")

      draft = Inv.transform(InvoicingSpec.actor, order.id, Inv::TransformInput.new("invoice")).value!
      invoice = InvoicingSpec.issue(draft.id, "2026-09-25")
      due = invoice.totals.amount_due
      due.should eq(invoice.totals.total_gross - deposit.totals.total_gross)
      final = I.entry("invoice:#{invoice.id}")
      final.total_debit.should eq(final.total_credit)
      final_customer = I.line(final, customer_account)
      {final_customer.side, final_customer.amount}.should eq({Acc::Side::Debit, due})
      # Ventes et TVA nettes des acomptes : le total des deux écritures reprend la facture.
      vat = ->(entry : Acc::EntryView) do
        entry.lines.select { |line| line.account_number == "44571" }
          .sum(BigDecimal.new(0)) { |line| line.side.credit? ? line.amount : -line.amount }
      end
      (vat.call(final) + vat.call(deposit_entry)).should eq(invoice.totals.total_vat)

      I.bank_receipt(setup.customer.code, due.to_s, [I.line(final, customer_account).id], "2026-10-05")
      I.document(invoice.id).status.should eq("paid")
      I.document(invoice.id).totals.paid.should eq(due)
    end
  end

  it "ne bloque pas l'émission quand l'écriture est impossible ; l'historique la propose ensuite" do
    with_active_modules(I::BOTH) do
      setup = I.setup(year: false)
      invoice = InvoicingSpec.issued(setup)
      invoice.number.should_not be_nil
      I.entries("invoice:#{invoice.id}").should be_empty

      history = Acc.invoicing_history(I.system)
      history.map(&.source).should eq(["invoice:#{invoice.id}"])
      history.first.number.should eq(invoice.number)
      history.first.amount.should eq(d("1019.76"))
      history.first.postable?.should be_false
      history.first.errors.map(&.key).should contain("accounting.errors.entry.date.no_period")

      ReferentialSpec.fiscal_year(2026)
      Acc.invoicing_history(I.system).first.postable?.should be_true
      result = Acc.post_invoicing_history(I.system).value!
      result.posted.map(&.source).should eq(["invoice:#{invoice.id}"])
      result.remaining.should be_empty
      I.entry("invoice:#{invoice.id}").receipt.should eq(invoice.number)
      Acc.invoicing_history(I.system).should be_empty
      # Rejouer une source déjà comptabilisée ne passe rien.
      Acc.post_invoicing_history(I.system).value!.posted.should be_empty
    end
  end

  it "exige l'écriture des écritures pour comptabiliser l'historique" do
    with_active_modules(I::BOTH) do
      expect_raises(Partiduo::Api::Forbidden) { Acc.invoicing_history(actor_with("accounting.entry.read")) }
      expect_raises(Partiduo::Api::Forbidden) { Acc.post_invoicing_history(actor_with("accounting.entry.read")) }
    end
  end
end

describe "Facturation seule — de bout en bout" do
  it "facture → règlement → payée, sans écriture ; l'historique reste consigné au socle" do
    with_active_modules("invoicing") do
      setup = I.setup(year: false)
      invoice = InvoicingSpec.issued(setup)
      I.record_payment(invoice.id, "19.76")
      I.document(invoice.id).status.should eq("partially_paid")
      I.record_payment(invoice.id, "1000", "2026-09-22")
      paid = I.document(invoice.id)
      paid.status.should eq("paid")
      paid.totals.amount_due.should eq(BigDecimal.new(0))

      journal = Partiduo::Events.journal(Partiduo::Events::JOURNALED)
      journal.map(&.name).should eq(%w[invoice.issued payment.recorded payment.recorded])
      journal.first.payload["source"].should eq("invoice:#{invoice.id}")
      expect_raises(Partiduo::Api::ModuleDisabled) { Acc.invoicing_history(I.system) }
    end
  end
end

describe "Comptabilité seule — de bout en bout" do
  it "vente saisie → encaissement lettré → payment.matched sans abonné de la Facturation" do
    with_active_modules("accounting") do
      EntrySpec.setup
      customer = EntrySpec.card("CUSTOMER", "Client Compta SARL")
      sale = Acc.post_sale(I.system, EntrySpec.document("V01", customer.code, [EntrySpec.item("100", account: "706")],
        day: "2026-03-15", source: "fec:V-12")).value!
      account = EntrySpec.card_account(customer)
      InvoicingSpec.capture("payment.matched") do |events|
        I.bank_receipt(customer.code, "120", [I.line(sale, account).id], "2026-03-31")
        events.size.should eq(1)
        events.first["sources"].split(',').should contain("fec:V-12")
        events.first["amounts"].should eq("fec:V-12=120.0")
        events.first["matched_on"].should eq("2026-03-31")
      end
      Partiduo::Events.subscribers("payment.matched").should_not contain("INVOICING")
      Partiduo::Events.subscribers("invoice.issued").should eq(["ACCOUNTING"])
      expect_raises(Partiduo::Api::ModuleDisabled) { Inv.documents(InvoicingSpec.actor) }
    end
  end
end

describe "Activation tardive de la Comptabilité (ADR-006 D2)" do
  it "propose puis comptabilise l'historique des factures, avoirs et règlements, sans double compte" do
    setup, invoice, credit = with_active_modules("invoicing") do
      prepared = I.setup(year: false)
      issued = InvoicingSpec.issued(prepared)
      I.record_payment(issued.id, "500", "2026-09-18")
      credited = I.credit_note(prepared, issued.id, "1", "2026-09-19")
      I.document(issued.id).totals.amount_due.should eq(d("423.76"))
      {prepared, issued, credited}
    end

    with_active_modules(I::BOTH) do
      # Référentiel comptable chargé à l'activation, puis l'exercice.
      Acc.load_initial_data(I.system, "fr", "fr").value!
      ReferentialSpec.fiscal_year(2026)

      history = Acc.invoicing_history(I.system)
      history.map(&.event).should eq(%w[invoice.issued payment.recorded credit_note.issued])
      history.all?(&.postable?).should be_true
      history[1].amount.should eq(d("500"))
      I.entries("invoice:#{invoice.id}").should be_empty # essai à blanc

      result = Acc.post_invoicing_history(I.system).value!
      result.posted.size.should eq(3)
      result.remaining.should be_empty

      customer_account = I.card_account(setup.customer.id)
      sale = I.entry("invoice:#{invoice.id}")
      I.line(sale, customer_account).amount.should eq(d("1019.76"))
      payment = I.entry(result.posted[1].source)
      payment.ledger_code.should eq("F01")
      paid_line = I.line(payment, customer_account)
      {paid_line.side, paid_line.amount}.should eq({Acc::Side::Credit, d("500")})
      # Règlement et avoir lettrés avec la facture.
      matching_id = I.line(Acc.entry(I.system, sale.id), customer_account).matching_id || raise "facture non lettrée"
      matching = Acc.matching(I.system, matching_id)
      matching.lines.size.should eq(3)
      matching.difference.should eq(d("423.76"))

      # Rien n'est compté deux fois par la Facturation.
      I.document(invoice.id).totals.paid.should eq(d("500"))
      I.document(invoice.id).status.should eq("partially_paid")

      # Le reste arrive en banque, lettré : la facture est payée.
      I.bank_receipt(setup.customer.code, "423.76", [I.line(sale, customer_account).id], "2026-10-02")
      done = I.document(invoice.id)
      done.status.should eq("paid")
      done.totals.paid.should eq(d("923.76"))
      Acc.invoicing_history(I.system).should be_empty
      credit.number.should_not be_nil
    end
  end

  it "comptabilise un règlement en espèces au journal de caisse quand il existe" do
    with_active_modules(I::BOTH) do
      I.setup
      cash = Partiduo::Api::Cards.create_card(I.system, Partiduo::Api::Cards::CardInput.new(
        category_id: (Partiduo::Api::Cards.category_by_code(I.system, "BANK") || raise "BANK absente").id,
        name: "Caisse")).value!
      AccountingSpec.create_account("531", "Caisse du siège", "53")
      Acc.assign_card_account(I.system, Acc::AssignCardAccountInput.new(cash.id, "531")).value!
      ledger = Acc.create_ledger(I.system, Acc::LedgerInput.new(name: "Caisse", kind: Acc::LedgerKind::Financial,
        bank_card: cash.code)).value!
      Partiduo::Accounting::Billing.financial_ledger("cash").try(&.code).should eq(ledger.code)
      Partiduo::Accounting::Billing.financial_ledger("transfer").try(&.code).should eq("F01")
    end
  end
end
