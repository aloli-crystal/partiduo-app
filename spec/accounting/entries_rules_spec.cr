# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Lot 2F — cas limites des écritures, repris des règles NOALYSS :
# `Acc_Operation::update_receipt` (pièce déjà prise : numéro suivant),
# `Acc_Ledger_Sale::insert` (avoirs, devise), `Acc_Ledger::reverse`
# (extourne dans une autre période), `Acc_Ledger_Fin::insert` (lignes
# concernées d'un autre compte), et refus d'un module inactif pour chaque
# appel du contrat des écritures.

private alias Api = Partiduo::Api::Accounting

private def system
  Partiduo::Api::Actor.system
end

private def d(text : String) : BigDecimal
  BigDecimal.new(text)
end

private def od_lines(amount = "10") : Array(Api::EntryLineInput)
  [EntrySpec.debit("681", amount), EntrySpec.credit("641", amount)]
end

private def sale(customer, amount = "100", day = "2026-03-15", **options) : Api::EntryView
  Api.post_sale(system, EntrySpec.document("V01", customer.code, [EntrySpec.item(amount, account: "706")], day,
    **options)).value!
end

describe "Écritures : chaque appel du contrat refuse un module inactif (ADR-006 D2)" do
  it "lève ModuleDisabled, y compris pour les requêtes de contrôle et l'historique de facturation" do
    with_active_modules("invoicing") do
      document = Api::DocumentInput.new(ledger_id: 1_i64, date: Time.utc, third_party: "C",
        lines: [] of Api::DocumentLineInput)
      financial = Api::FinancialInput.new(ledger_id: 1_i64, date: Time.utc, lines: [] of Api::PaymentLineInput)
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.post_purchase(system, document) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.post_sale(system, document) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.check_document(system, document) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.check_financial(system, financial) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.check_matching(system, [1_i64, 2_i64]) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.matching(system, 1_i64) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.count_entries(system) }
      expect_raises(Partiduo::Api::ModuleDisabled) do
        Api.check_entry(system, Api::CheckEntryInput.new([] of Api::EntryLineInput))
      end
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.invoicing_history(system) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.post_invoicing_history(system) }
    end
  end
end

describe_module "ACCOUNTING", "Écritures — cas limites (lot 2F)" do
  describe "numérotation des pièces" do
    it "saute un numéro déjà pris par une pièce saisie (update_receipt : « try another seq »)" do
      EntrySpec.setup
      ledger = EntrySpec.ledger("O01")
      manual = EntrySpec.post_misc(od_lines, receipt: ledger.next_receipt)
      manual.receipt.should eq(ledger.next_receipt)

      draft = Api.check_entry(system, EntrySpec.misc_input(od_lines)).value!
      automatic = EntrySpec.post_misc(od_lines)
      draft.receipt.should eq(automatic.receipt)
      automatic.receipt.should_not eq(manual.receipt)
      automatic.receipt.should eq(Partiduo::Accounting::Receipts.format(ledger.receipt_prefix, ledger.receipt_padding,
        ledger.last_receipt_number + 2))
      Api.count_entries(system).should eq(2)
    end

    it "refuse une pièce de plus de 40 caractères et une source de plus de 100" do
      EntrySpec.setup
      result = Api.post_entry(system, EntrySpec.misc_input(od_lines, receipt: "P" * 41, source: "s" * 101))
      result.errors_for("receipt").map(&.key).should eq(["accounting.errors.entry.receipt.too_long"])
      result.errors_for("source").map(&.key).should eq(["accounting.errors.entry.source.too_long"])
      ReferentialSpec.expect_translated(result)
      Api.count_entries(system).should eq(0)
    end
  end

  describe "écriture générique" do
    it "refuse une écriture d'une seule ligne et un montant négatif" do
      EntrySpec.setup
      single = Api.post_entry(system, EntrySpec.misc_input([EntrySpec.debit("681", "10")]))
      single.error_keys.should contain("accounting.errors.entry.too_few_lines")
      negative = Api.post_entry(system, EntrySpec.misc_input([EntrySpec.debit("681", "-10"), EntrySpec.credit("641", "-10")]))
      negative.errors_for("lines[0].amount").map(&.key).should eq(["accounting.errors.entry.amount_not_positive"])
      negative.errors_for("lines[1].amount").map(&.key).should eq(["accounting.errors.entry.amount_not_positive"])
    end

    it "garde le compte saisi quand une fiche est aussi donnée, et cite la fiche" do
      EntrySpec.setup
      supplier = EntrySpec.card("SUPPLIER", "Fournisseur divers")
      view = EntrySpec.post_misc([EntrySpec.debit("603", "15"), EntrySpec.credit("641", "15", supplier.code)])
      view.lines[1].account_number.should eq("641")
      view.lines[1].card_code.should eq(supplier.code)
    end

    it "admet quatre décimales et arrondit la devise de tenue au centime" do
      EntrySpec.setup
      view = EntrySpec.post_misc([EntrySpec.debit("681", "10.1234"), EntrySpec.credit("641", "10.1234")])
      view.amount.should eq(d("10.1234"))
    end
  end

  describe "factures et avoirs" do
    it "passe un avoir de vente avec TVA : client au crédit, produit et TVA au débit" do
      EntrySpec.setup
      customer = EntrySpec.card("CUSTOMER", "Client remboursé")
      view = Api.post_sale(system, EntrySpec.document("V01", customer.code, [EntrySpec.item("-100", account: "706")])).value!
      lines = EntrySpec.lines_by_account(view)
      lines["706"].should eq([{"debit", d("100")}])
      lines["44571"].should eq([{"debit", d("20.00")}])
      lines[EntrySpec.card_account(customer)].should eq([{"credit", d("120.00")}])
      view.amount.should eq(d("120.00"))
    end

    it "compense les lignes positives et négatives d'une même facture" do
      EntrySpec.setup
      customer = EntrySpec.card("CUSTOMER", "Client remisé")
      view = Api.post_sale(system, EntrySpec.document("V01", customer.code, [
        EntrySpec.item("200", account: "706"), EntrySpec.item("-50", account: "709"),
      ])).value!
      lines = EntrySpec.lines_by_account(view)
      lines["706"].should eq([{"credit", d("200")}])
      lines["709"].should eq([{"debit", d("50")}])
      lines["44571"].should eq([{"credit", d("30.00")}])
      lines[EntrySpec.card_account(customer)].should eq([{"debit", d("180.00")}])
    end

    it "accepte un taux à 0 % sans compte de TVA (export) et refuse une TVA saisie sans taux" do
      EntrySpec.setup
      customer = EntrySpec.card("CUSTOMER", "Client export")
      view = Api.post_sale(system, EntrySpec.document("V01", customer.code, [EntrySpec.item("300", "EXP", account: "706")])).value!
      view.lines.size.should eq(2)
      view.lines.find! { |line| line.account_number == "706" }.vat_rate_code.should eq("EXP")
      view.amount.should eq(d("300"))

      result = Api.post_sale(system, EntrySpec.document("V01", customer.code, [
        EntrySpec.item("100", nil, account: "706", vat_amount: d("20")),
      ]))
      result.errors_for("lines[0].vat_rate").map(&.key).should eq(["accounting.errors.entry.vat_rate.required"])
      ReferentialSpec.expect_translated(result)
    end

    it "refuse une facture sans ligne utile ni tiers, et un taux inconnu" do
      EntrySpec.setup
      result = Api.post_sale(system, EntrySpec.document("V01", " ", [EntrySpec.item("100", "XX", account: "706")]))
      result.errors_for("third_party").map(&.key).should eq(["accounting.errors.entry.third_party.required"])
      result.errors_for("lines[0].vat_rate").map(&.key).should eq(["accounting.errors.entry.vat_rate.not_found"])
      customer = EntrySpec.card("CUSTOMER", "Client vide")
      Api.post_sale(system, EntrySpec.document("V01", customer.code, [EntrySpec.item("0", account: "706")]))
        .error_keys.should eq(["accounting.errors.entry.no_items"])
    end

    it "convertit une vente en devise, TVA comprise, en restant équilibrée" do
      EntrySpec.setup
      customer = EntrySpec.card("CUSTOMER", "Customer Inc")
      Partiduo::Api::Core.create_currency(system, Partiduo::Api::Core::CurrencyInput.new(
        code: "USD", name: "Dollar", decimals: 2, rate: d("1.1"), valid_from: EntrySpec.date("2026-01-01"))).value!
      view = Api.post_sale(system, EntrySpec.document("V01", customer.code, [EntrySpec.item("100", account: "706")],
        currency_code: "USD", currency_rate: d("3"))).value!
      view.currency_code.should eq("USD")
      view.total_debit.should eq(view.total_credit)
      client = view.lines.find! { |line| line.card_id == customer.id }
      client.currency_amount.should eq(d("120.00"))
      client.amount.should eq(d("40.00"))
      view.lines.find! { |line| line.account_number == "706" }.amount.should eq(d("33.33"))
      view.lines.find! { |line| line.account_number == "44571" }.amount.should eq(d("6.67"))
    end

    it "calcule dans check_document exactement ce que post_sale enregistre" do
      EntrySpec.setup
      customer = EntrySpec.card("CUSTOMER", "Client contrôlé")
      input = EntrySpec.document("V01", customer.code, [
        EntrySpec.item("0", account: "706", quantity: d("3"), unit_price: d("33.333")),
        EntrySpec.item("12.5", "TR55", account: "706"),
      ])
      draft = Api.check_document(system, input).value!
      view = Api.post_sale(system, input).value!
      draft.lines.map { |line| {line.account_number, line.side, line.amount} }
        .should eq(view.lines.map { |line| {line.account_number, line.side, line.amount} })
      draft.receipt.should eq(view.receipt)
      draft.total_including_vat.should eq(view.amount)
      draft.total_excluding_vat.should eq(d("112.50"))
    end
  end

  describe "extraits financiers" do
    it "refuse de lettrer une ligne d'un autre compte, sans rien écrire" do
      EntrySpec.setup
      customer = EntrySpec.card("CUSTOMER", "Client A")
      other = EntrySpec.card("CUSTOMER", "Client B")
      invoice = sale(other)
      line_id = invoice.lines.find! { |line| line.card_id == other.id }.id
      before = Api.count_entries(system)
      result = Api.post_financial(system, Api::FinancialInput.new(ledger_id: EntrySpec.ledger("F01").id,
        date: EntrySpec.date("2026-03-20"),
        lines: [Api::PaymentLineInput.new(d("120"), account: "706", match_line_ids: [line_id])]))
      result.errors_for("lines[0].match_line_ids").map(&.key).should eq(["accounting.errors.matching.different_accounts"])
      unknown = Api.post_financial(system, Api::FinancialInput.new(ledger_id: EntrySpec.ledger("F01").id,
        date: EntrySpec.date("2026-03-20"),
        lines: [Api::PaymentLineInput.new(d("120"), card: customer.code, match_line_ids: [987654_i64])]))
      unknown.errors_for("lines[0].match_line_ids").map(&.key).should eq(["accounting.errors.matching.line_not_found"])
      Api.count_entries(system).should eq(before)
    end

    it "refuse un journal qui n'est pas financier et une ligne sans contrepartie" do
      EntrySpec.setup
      Api.post_financial(system, Api::FinancialInput.new(ledger_id: EntrySpec.ledger("V01").id,
        date: EntrySpec.date("2026-03-20"), lines: [Api::PaymentLineInput.new(d("1"), account: "646")]))
        .error_keys.should eq(["accounting.errors.entry.ledger.not_financial"])
      result = Api.post_financial(system, Api::FinancialInput.new(ledger_id: EntrySpec.ledger("F01").id,
        date: EntrySpec.date("2026-03-20"), lines: [Api::PaymentLineInput.new(d("0"))]))
      result.errors_for("lines[0].card").map(&.key).should eq(["accounting.errors.entry.counterpart_missing"])
      result.errors_for("lines[0].amount").map(&.key).should eq(["accounting.errors.entry.amount_zero"])
      Api.post_financial(system, Api::FinancialInput.new(ledger_id: EntrySpec.ledger("F01").id,
        date: EntrySpec.date("2026-03-20"), lines: [] of Api::PaymentLineInput))
        .error_keys.should eq(["accounting.errors.entry.no_items"])
    end

    it "garde la pièce de l'extrait telle quelle pour une seule ligne" do
      EntrySpec.setup
      views = Api.post_financial(system, Api::FinancialInput.new(ledger_id: EntrySpec.ledger("F01").id,
        date: EntrySpec.date("2026-03-20"), receipt: "REL-9",
        lines: [Api::PaymentLineInput.new(d("-15"), account: "646")])).value!
      views.map(&.receipt).should eq(["REL-9"])
      EntrySpec.lines_by_account(views[0])["646"].should eq([{"debit", d("15")}])
    end
  end

  describe "annulation" do
    it "extourne dans une période ouverte une écriture d'une période close, et lettre en période close" do
      EntrySpec.setup
      customer = EntrySpec.card("CUSTOMER", "Client annulé")
      invoice = sale(customer, "100", "2026-02-10")
      Partiduo::Api::Core.close_period(system, EntrySpec.period("2026-02-10").id).value!

      Api.cancel_entry(system, Api::CancelEntryInput.new(invoice.id)).error_keys
        .should eq(["accounting.errors.entry.date.period_closed"])

      events = [] of Partiduo::Events::Event
      reversal = nil
      ReferentialSpec.capture_events("entry.cancelled") do |received|
        reversal = Api.cancel_entry(system, Api::CancelEntryInput.new(invoice.id, EntrySpec.date("2026-03-01"), "Annulation")).value!
        events.concat(received)
      end
      reversal = ReferentialSpec.present(reversal)
      reversal.date.should eq(EntrySpec.date("2026-03-01"))
      reversal.label.should eq("Annulation")
      reversal.reversal_of_id.should eq(invoice.id)
      reversal.lines.find! { |line| line.card_id == customer.id }.side.credit?.should be_true
      events.map(&.["reversal_entry_id"]).should eq([reversal.id.to_s])

      original = Api.entry(system, invoice.id)
      original.cancelled?.should be_true
      original.lines.all? { |line| !line.matching_id.nil? }.should be_true
      Api.entries(system, Api::EntryQuery.new(include_cancelled: false)).should be_empty
    end

    it "extourne une écriture en devise avec ses montants d'origine" do
      EntrySpec.setup
      Partiduo::Api::Core.create_currency(system, Partiduo::Api::Core::CurrencyInput.new(
        code: "USD", name: "Dollar", decimals: 2, rate: d("1.1"), valid_from: EntrySpec.date("2026-01-01"))).value!
      view = EntrySpec.post_misc([EntrySpec.debit("681", "20"), EntrySpec.credit("641", "20")], currency_code: "USD",
        currency_rate: d("3"))
      reversal = Api.cancel_entry(system, Api::CancelEntryInput.new(view.id)).value!
      reversal.currency_rate.should eq(d("3"))
      reversal.lines.map(&.amount).should eq(view.lines.map(&.amount))
      reversal.lines.map(&.currency_amount).should eq(view.lines.map(&.currency_amount))
    end

    it "refuse l'annulation d'une écriture d'un journal non inscriptible, NotFound pour une inconnue" do
      EntrySpec.setup
      view = EntrySpec.post_misc(od_lines)
      user_id, actor = AccountingSpec.user_actor("annule@example.com", "accounting.entry.cancel", "accounting.entry.read")
      Partiduo::Api::Auth.set_ledger_security(system, user_id, true).value!
      Partiduo::Api::Auth.set_ledger_access(system, user_id, EntrySpec.ledger("O01").id, "R").value!
      expect_raises(Partiduo::Api::Forbidden) { Api.cancel_entry(actor, Api::CancelEntryInput.new(view.id)) }
      expect_raises(Partiduo::Api::NotFound) { Api.cancel_entry(system, Api::CancelEntryInput.new(987654_i64)) }
      Api.entry(system, view.id).cancelled?.should be_false
    end
  end

  describe "lettrage" do
    it "réunit un lettrage partiel et un nouveau paiement en un seul lettrage équilibré" do
      EntrySpec.setup
      customer = EntrySpec.card("CUSTOMER", "Client en deux fois")
      invoice = sale(customer)
      client_line = invoice.lines.find! { |line| line.card_id == customer.id }.id
      f01 = EntrySpec.ledger("F01").id
      first = Api.post_financial(system, Api::FinancialInput.new(ledger_id: f01, date: EntrySpec.date("2026-03-20"),
        lines: [Api::PaymentLineInput.new(d("70"), card: customer.code, match_line_ids: [client_line])])).value!.first
      partial = ReferentialSpec.present(Api.entry(system, invoice.id).lines.find! { |line| line.id == client_line }.matching_id)
      Api.matching(system, partial).balanced?.should be_false
      Api.matching(system, partial).difference.should eq(d("50.00"))

      second = Api.post_financial(system, Api::FinancialInput.new(ledger_id: f01, date: EntrySpec.date("2026-03-25"),
        lines: [Api::PaymentLineInput.new(d("50"), card: customer.code)])).value!.first
      second_line = second.lines.find! { |line| line.card_id == customer.id }.id
      matching = Api.match_lines(system, [client_line, second_line]).value!
      matching.balanced?.should be_true
      matching.lines.map(&.entry_id).sort!.should eq([invoice.id, first.id, second.id].sort)
      expect_raises(Partiduo::Api::NotFound) { Api.matching(system, partial) }
    end

    it "refuse des lignes d'un seul côté, de comptes différents, inconnues ou trop peu nombreuses" do
      EntrySpec.setup
      customer = EntrySpec.card("CUSTOMER", "Client lettré")
      a = sale(customer)
      b = sale(customer, "50")
      line = ->(view : Api::EntryView) { view.lines.find! { |item| item.card_id == customer.id }.id }
      product = ->(view : Api::EntryView) { view.lines.find! { |item| item.account_number == "706" }.id }

      Api.match_lines(system, [line.call(a), line.call(b)]).error_keys.should eq(["accounting.errors.matching.one_side"])
      Api.match_lines(system, [line.call(a), product.call(a)]).error_keys
        .should eq(["accounting.errors.matching.different_accounts"])
      Api.match_lines(system, [line.call(a), 987654_i64]).error_keys.should eq(["accounting.errors.matching.line_not_found"])
      result = Api.match_lines(system, [line.call(a), line.call(a)])
      result.error_keys.should eq(["accounting.errors.matching.too_few_lines"])
      ReferentialSpec.expect_translated(result)
      Api.check_matching(system, [line.call(a), line.call(b)]).error_keys.should eq(["accounting.errors.matching.one_side"])
      expect_raises(Partiduo::Api::NotFound) { Api.unmatch(system, 987654_i64) }
    end

    it "refuse de lettrer une ligne d'un journal que l'acteur ne peut pas lire" do
      EntrySpec.setup
      customer = EntrySpec.card("CUSTOMER", "Client caché")
      invoice = sale(customer)
      payment = Api.post_financial(system, Api::FinancialInput.new(ledger_id: EntrySpec.ledger("F01").id,
        date: EntrySpec.date("2026-03-20"), lines: [Api::PaymentLineInput.new(d("120"), card: customer.code)])).value!.first
      ids = [invoice, payment].map(&.lines.find! { |line| line.card_id == customer.id }.id)
      user_id, actor = AccountingSpec.user_actor("lettreur@example.com", "accounting.matching.write", "accounting.entry.read")
      Partiduo::Api::Auth.set_ledger_security(system, user_id, true).value!
      Partiduo::Api::Auth.set_ledger_access(system, user_id, EntrySpec.ledger("F01").id, "R").value!
      expect_raises(Partiduo::Api::Forbidden) { Api.match_lines(actor, ids) }
      expect_raises(Partiduo::Api::Forbidden) { Api.check_matching(actor, ids) }
      Partiduo::Api::Auth.set_ledger_access(system, user_id, EntrySpec.ledger("V01").id, "R").value!
      Api.match_lines(actor, ids).value!.balanced?.should be_true
    end
  end

  describe "consultation d'un compte ou d'un tiers" do
    it "range l'échu aux bornes 0, 1, 30, 31, 60 et 61 jours" do
      EntrySpec.setup
      customer = EntrySpec.card("CUSTOMER", "Client âgé")
      {"2026-04-30", "2026-04-29", "2026-03-31", "2026-03-30", "2026-03-01", "2026-02-28"}.each do |due|
        sale(customer, "100", "2026-02-01", due_date: EntrySpec.date(due))
      end
      statement = Api.account_statement(system, Api::StatementQuery.new(card: customer.code,
        as_of: EntrySpec.date("2026-04-30")))
      statement.ageing.not_due.should eq(d("120.00"))
      statement.ageing.days_1_30.should eq(d("240.00"))
      statement.ageing.days_31_60.should eq(d("240.00"))
      statement.ageing.over_60.should eq(d("120.00"))
      statement.overdue.should eq(d("600.00"))
      statement.lines.count(&.overdue).should eq(5)
    end

    it "arrête le reste dû à date_to : un paiement lettré après cette date n'y compte pas" do
      EntrySpec.setup
      customer = EntrySpec.card("CUSTOMER", "Client au 31 mars")
      invoice = sale(customer, "100", "2026-03-10")
      client_line = invoice.lines.find! { |line| line.card_id == customer.id }.id
      Api.post_financial(system, Api::FinancialInput.new(ledger_id: EntrySpec.ledger("F01").id,
        date: EntrySpec.date("2026-04-10"),
        lines: [Api::PaymentLineInput.new(d("120"), card: customer.code, match_line_ids: [client_line])])).value!

      march = Api.account_statement(system, Api::StatementQuery.new(card: customer.code,
        date_to: EntrySpec.date("2026-03-31"), as_of: EntrySpec.date("2026-03-31")))
      march.balance.should eq(d("120.00"))
      march.remaining.should eq(d("120.00"))
      march.lines.map(&.entry_id).should eq([invoice.id])

      now = Api.account_statement(system, Api::StatementQuery.new(card: customer.code, as_of: EntrySpec.date("2026-04-30")))
      now.balance.should eq(d("0.00"))
      now.remaining.should eq(d("0"))
    end

    it "exige un compte ou une fiche, et ne lit que les journaux visibles" do
      EntrySpec.setup
      customer = EntrySpec.card("CUSTOMER", "Client discret")
      sale(customer)
      expect_raises(ArgumentError) { Api.account_statement(system, Api::StatementQuery.new) }
      user_id, actor = AccountingSpec.user_actor("consulte@example.com", "accounting.entry.read")
      Partiduo::Api::Auth.set_ledger_security(system, user_id, true).value!
      hidden = Api.account_statement(actor, Api::StatementQuery.new(card: customer.code))
      hidden.lines.should be_empty
      hidden.balance.should eq(d("0"))
      expect_raises(Partiduo::Api::Forbidden) do
        Api.account_statement(actor_with("accounting.entry.post"), Api::StatementQuery.new(card: customer.code))
      end
    end
  end
end
