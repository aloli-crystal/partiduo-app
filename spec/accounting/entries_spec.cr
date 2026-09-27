# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Saisie générique (`Acc_Ledger::save`, `verify_operation`) et numérotation
# des pièces ; d'après `acc_ledgerTest.php` (testSave, testVerify_Operation,
# testReverse, testGuess_pj, testIs_closed).

private alias Api = Partiduo::Api::Accounting

private def system
  Partiduo::Api::Actor.system
end

private def d(text : String) : BigDecimal
  BigDecimal.new(text)
end

describe "Écritures : module inactif (ADR-006 D2)" do
  it "refuse commandes et requêtes par ModuleDisabled" do
    with_active_modules("invoicing") do
      input = Api::EntryInput.new(ledger_id: 1_i64, date: Time.utc, lines: [] of Api::EntryLineInput)
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.post_entry(system, input) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.check_entry(system, input) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.entries(system) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.entry(system, 1_i64) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.cancel_entry(system, Api::CancelEntryInput.new(1_i64)) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.match_lines(system, [1_i64, 2_i64]) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.unmatch(system, 1_i64) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.account_statement(system, Api::StatementQuery.new(account: "410")) }
      expect_raises(Partiduo::Api::ModuleDisabled) do
        Api.post_financial(system, Api::FinancialInput.new(ledger_id: 1_i64, date: Time.utc, lines: [] of Api::PaymentLineInput))
      end
    end
  end
end

describe_module "ACCOUNTING", "Écritures (jrn, jrnx)" do
  describe ".post_entry" do
    it "enregistre une opération diverse équilibrée, numérote la pièce et calcule la période" do
      EntrySpec.setup
      ledger = EntrySpec.ledger("O01")
      view = EntrySpec.post_misc([EntrySpec.debit("681", "1250.50"), EntrySpec.credit("641", "1250.50")],
        label: "Dotation", due_date: EntrySpec.date("2026-04-30"))

      view.ledger_code.should eq("O01")
      view.ledger_kind.misc?.should be_true
      view.receipt.should eq(ledger.next_receipt)
      view.internal_code.should eq("O#{view.id.to_s(16).upcase.rjust(6, '0')}")
      view.date.should eq(EntrySpec.date("2026-03-15"))
      view.due_date.should eq(EntrySpec.date("2026-04-30"))
      view.period_id.should eq(EntrySpec.period("2026-03-15").id)
      view.amount.should eq(d("1250.50"))
      view.total_debit.should eq(view.total_credit)
      view.currency_code.should eq("EUR")
      view.currency_rate.should eq(d("1"))
      view.lines.map { |line| {line.account_number, line.side.code, line.amount} }
        .should eq([{"681", "debit", d("1250.50")}, {"641", "credit", d("1250.50")}])
      Api.ledger(system, ledger.id).last_receipt_number.should eq(ledger.last_receipt_number + 1)
      Api.entry(system, view.id).should eq(view)
    end

    it "accepte une pièce saisie, refuse un doublon dans le journal (update_receipt)" do
      EntrySpec.setup
      lines = [EntrySpec.debit("681", "10"), EntrySpec.credit("641", "10")]
      first = EntrySpec.post_misc(lines, receipt: "OD-MANUEL")
      first.receipt.should eq("OD-MANUEL")
      EntrySpec.ledger("O01").last_receipt_number.should eq(0) # pièce saisie : compteur inchangé

      result = Api.post_entry(system, EntrySpec.misc_input(lines, receipt: " OD-MANUEL "))
      result.errors_for("receipt").map(&.key).should eq(["accounting.errors.entry.receipt.taken"])
      # Dans un autre journal, la même pièce est admise.
      Api.post_entry(system, EntrySpec.misc_input(lines, ledger: "A01", receipt: "OD-MANUEL")).success?.should be_true
    end

    it "impute la ligne d'une fiche sur son compte et cite la fiche (qc_<i>, jrnx.j_qcode)" do
      EntrySpec.setup
      supplier = EntrySpec.card("SUPPLIER", "Fournitures Martin")
      view = EntrySpec.post_misc([EntrySpec.debit("603", "80"), EntrySpec.credit("", "80", supplier.code)])
      line = view.lines[1]
      line.card_id.should eq(supplier.id)
      line.card_code.should eq(supplier.code)
      line.account_number.should eq(EntrySpec.card_account(supplier))
    end

    it "refuse ligne par ligne, avec des clés i18n (verify_operation)" do
      EntrySpec.setup
      customers = ReferentialSpec.present(Partiduo::Api::Cards.category_by_code(system, "CUSTOMER"))
      disabled = ReferentialSpec.card(customers.id, "Ancien client", enabled: false)
      input = EntrySpec.misc_input([
        EntrySpec.debit("999999", "10"),
        EntrySpec.debit("60", "10"),
        EntrySpec.debit("", "10", "INCONNU"),
        EntrySpec.debit("", "10", disabled.code),
        EntrySpec.credit("641", "40.00001"),
        EntrySpec.line("", Api::Side::Credit, "0"),
      ])

      result = Api.post_entry(system, input)

      result.errors_for("lines[0].account").map(&.key).should eq(["accounting.errors.entry.account.not_found"])
      result.errors_for("lines[1].account").map(&.key).should eq(["accounting.errors.entry.account.not_direct_use"])
      result.errors_for("lines[2].card").map(&.key).should eq(["accounting.errors.entry.card.not_found"])
      result.errors_for("lines[3].card").map(&.key).should eq(["accounting.errors.entry.card.disabled"])
      result.errors_for("lines[4].amount").map(&.key).should eq(["accounting.errors.entry.too_many_decimals"])
      result.errors_for("lines[5].account").map(&.key).should eq(["accounting.errors.entry.account_missing"])
      result.errors_for("lines[5].amount").map(&.key).should eq(["accounting.errors.entry.amount_not_positive"])
      result.errors_for("base").map(&.key).should eq(["accounting.errors.entry.unbalanced"])
      ReferentialSpec.expect_translated(result)
      Api.entries(system).should be_empty
    end

    it "refuse une date hors exercice ou d'une période close (Periode::is_closed)" do
      EntrySpec.setup
      lines = [EntrySpec.debit("681", "10"), EntrySpec.credit("641", "10")]
      Api.post_entry(system, EntrySpec.misc_input(lines, "2031-01-01")).errors_for("date").map(&.key)
        .should eq(["accounting.errors.entry.date.no_period"])

      Partiduo::Api::Core.close_period(system, EntrySpec.period("2026-02-10").id).value!
      result = Api.post_entry(system, EntrySpec.misc_input(lines, "2026-02-10"))
      result.errors_for("date").map(&.key).should eq(["accounting.errors.entry.date.period_closed"])
      result.errors_for("date").first.params["date"].should eq("2026-02-10")
      ReferentialSpec.expect_translated(result)
    end

    it "refuse un journal désactivé et une pièce jointe inconnue" do
      EntrySpec.setup
      ledger = EntrySpec.ledger("O01")
      Api.update_ledger(system, ledger.id, AccountingSpec.ledger_input(ledger.name, Api::LedgerKind::Misc,
        code: "O01", enabled: false)).value!
      lines = [EntrySpec.debit("681", "10"), EntrySpec.credit("641", "10")]
      result = Api.post_entry(system, EntrySpec.misc_input(lines, attachment_id: 424242_i64))
      result.error_keys.sort.should eq(["accounting.errors.entry.attachment.not_found", "accounting.errors.entry.ledger.disabled"])
    end

    it "exige le droit d'écriture sur le journal (check_jrn = W) et la permission" do
      EntrySpec.setup
      ledger = EntrySpec.ledger("O01")
      user_id, actor = AccountingSpec.user_actor("reader@example.com", "accounting.entry.post", "accounting.entry.read")
      Partiduo::Api::Auth.set_ledger_security(system, user_id, true).value!
      Partiduo::Api::Auth.set_ledger_access(system, user_id, ledger.id, "R").value!
      input = EntrySpec.misc_input([EntrySpec.debit("681", "10"), EntrySpec.credit("641", "10")])

      expect_raises(Partiduo::Api::Forbidden) { Api.post_entry(actor, input) }
      expect_raises(Partiduo::Api::Forbidden) { Api.post_entry(actor_with("accounting.entry.read"), input) }
      Partiduo::Api::Auth.set_ledger_access(system, user_id, ledger.id, "W").value!
      Api.post_entry(actor, input).success?.should be_true
    end

    it "convertit une écriture en devise au cours du socle et reporte l'écart d'arrondi" do
      EntrySpec.setup
      Partiduo::Api::Core.create_currency(system, Partiduo::Api::Core::CurrencyInput.new(
        code: "USD", name: "Dollar", decimals: 2, rate: d("1.1"), valid_from: EntrySpec.date("2026-01-01"))).value!
      view = EntrySpec.post_misc([
        EntrySpec.debit("681", "10"), EntrySpec.debit("603", "10"), EntrySpec.debit("646", "10"),
        EntrySpec.credit("641", "30"),
      ], currency_code: "USD")

      view.currency_code.should eq("USD")
      view.currency_rate.should eq(d("1.1"))
      # 10 / 1,1 = 9,09 (×3 = 27,27) ; 30 / 1,1 = 27,27 : équilibre sans écart.
      view.lines.map(&.amount).should eq([d("9.09"), d("9.09"), d("9.09"), d("27.27")])
      view.lines.map(&.currency_amount).should eq([d("10"), d("10"), d("10"), d("30")])

      view = EntrySpec.post_misc([EntrySpec.debit("681", "20"), EntrySpec.credit("641", "10"), EntrySpec.credit("646", "10")],
        currency_code: "USD", currency_rate: d("3"))
      # 20 / 3 = 6,67 ; 10 / 3 = 3,33 (×2 = 6,66) : écart reporté sur le crédit.
      view.total_debit.should eq(view.total_credit)
      view.lines.map(&.amount).should eq([d("6.67"), d("3.34"), d("3.33")])

      no_rate = Api.post_entry(system, EntrySpec.misc_input([EntrySpec.debit("681", "1"), EntrySpec.credit("641", "1")],
        "2026-01-01", currency_code: "USD"))
      no_rate.success?.should be_true
      Partiduo::Api::Core.create_currency(system, Partiduo::Api::Core::CurrencyInput.new(
        code: "GBP", name: "Livre", decimals: 2, rate: d("0.9"), valid_from: EntrySpec.date("2026-06-01"))).value!
      Api.post_entry(system, EntrySpec.misc_input([EntrySpec.debit("681", "1"), EntrySpec.credit("641", "1")],
        currency_code: "GBP")).error_keys.should eq(["accounting.errors.entry.currency_rate.missing"])
    end

    it "publie entry.posted dans la transaction, avec la source" do
      EntrySpec.setup
      ReferentialSpec.capture_events("entry.posted") do |events|
        view = EntrySpec.post_misc([EntrySpec.debit("681", "10"), EntrySpec.credit("641", "10")], source: "invoice:42")
        events.size.should eq(1)
        events[0]["entry_id"].should eq(view.id.to_s)
        events[0]["source"].should eq("invoice:42")
        events[0]["ledger_code"].should eq("O01")
      end
    end

    it "n'écrit rien et ne consomme pas de numéro si un abonné lève" do
      EntrySpec.setup
      manifest = Partiduo::Modules["CORE"]
      previous = manifest.subscriptions["entry.posted"]?.try(&.dup)
      manifest.on("entry.posted") { |_| raise "abonné en échec" }
      begin
        expect_raises(Exception, /abonné en échec/) do
          EntrySpec.post_misc([EntrySpec.debit("681", "10"), EntrySpec.credit("641", "10")])
        end
      ensure
        previous ? (manifest.subscriptions["entry.posted"] = previous) : manifest.subscriptions.delete("entry.posted")
      end
      Api.count_entries(system).should eq(0)
      EntrySpec.ledger("O01").last_receipt_number.should eq(0)
    end
  end

  describe ".check_entry" do
    it "applique les règles de post_entry sans écrire ni réserver de pièce" do
      EntrySpec.setup
      input = EntrySpec.misc_input([EntrySpec.debit("681", "100"), EntrySpec.credit("641", "100")])
      draft = Api.check_entry(system, input).value!
      draft.balanced?.should be_true
      draft.receipt.should eq(EntrySpec.ledger("O01").next_receipt)
      draft.period_id.should eq(EntrySpec.period("2026-03-15").id)
      draft.lines.map(&.account_number).should eq(["681", "641"])
      Api.count_entries(system).should eq(0)
      EntrySpec.ledger("O01").last_receipt_number.should eq(0)

      bad = input.copy_with(lines: [EntrySpec.debit("681", "100"), EntrySpec.credit("641", "90")])
      Api.check_entry(system, bad).error_keys.should eq(["accounting.errors.entry.unbalanced"])
    end

    it "accepte une ligne par fiche sans compte (CheckEntryInput)" do
      input = Api::CheckEntryInput.new([EntrySpec.debit("", "10", "CLIENT1"), EntrySpec.credit("641", "10")])
      Api.check_entry(actor_with("accounting.entry.post"), input).value!.balanced?.should be_true
    end
  end

  describe "référentiel mouvementé" do
    it "refuse d'effacer un journal mouvementé, d'en changer le type ou la devise, de renuméroter un compte" do
      EntrySpec.setup
      EntrySpec.post_misc([EntrySpec.debit("681", "10"), EntrySpec.credit("641", "10")])
      ledger = EntrySpec.ledger("O01")
      Api.delete_ledger(system, ledger.id).error_keys.should eq(["accounting.errors.ledger.in_use"])
      Partiduo::Api::Core.create_currency(system, Partiduo::Api::Core::CurrencyInput.new(
        code: "USD", name: "Dollar", decimals: 2, rate: d("1.1"), valid_from: EntrySpec.date("2026-01-01"))).value!
      result = Api.update_ledger(system, ledger.id, AccountingSpec.ledger_input(ledger.name, Api::LedgerKind::Purchase,
        code: "O01", currency_code: "USD"))
      result.error_keys.sort.should eq(["accounting.errors.ledger.currency_code.in_use", "accounting.errors.ledger.kind.in_use"])

      account = Api.account(system, "681")
      Api.update_account(system, account.id, Api::AccountInput.new("6811", account.label)).error_keys
        .should eq(["accounting.errors.account.number.in_use"])
      Api.update_account(system, account.id, Api::AccountInput.new("681", "Dotations")).success?.should be_true
    end
  end
end
