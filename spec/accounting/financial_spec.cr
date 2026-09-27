# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Extraits financiers (`Acc_Ledger_Fin::insert`, `insert_quant_fin`,
# `e_concerned`), d'après `acc_ledger_finTest.php`.

private alias Api = Partiduo::Api::Accounting

private def system
  Partiduo::Api::Actor.system
end

private def d(text : String) : BigDecimal
  BigDecimal.new(text)
end

private def financial(lines : Array(Api::PaymentLineInput), day = "2026-03-20", **options) : Api::FinancialInput
  Api::FinancialInput.new(ledger_id: EntrySpec.ledger("F01").id, date: EntrySpec.date(day), lines: lines)
    .copy_with(**options)
end

private def sale(customer : Partiduo::Api::Cards::CardView, amount = "1000", day = "2026-03-15") : Api::EntryView
  Api.post_sale(system, EntrySpec.document("V01", customer.code, [EntrySpec.item(amount, account: "706")], day)).value!
end

private def third_party_line(view : Api::EntryView) : Api::EntryLineView
  view.lines.find! { |line| !line.card_id.nil? }
end

describe_module "ACCOUNTING", "Extraits financiers" do
  it "passe une écriture par ligne : banque contre contrepartie, pièce propre à chacune" do
    EntrySpec.setup
    customer = EntrySpec.card("CUSTOMER", "Client payeur")
    supplier = EntrySpec.card("SUPPLIER", "Fournisseur payé")
    views = Api.post_financial(system, financial([
      Api::PaymentLineInput.new(d("1200"), card: customer.code, label: "Virement client"),
      Api::PaymentLineInput.new(d("-300.50"), card: supplier.code),
      Api::PaymentLineInput.new(d("-12"), account: "646", date: EntrySpec.date("2026-03-25")),
    ], receipt: "REL-03")).value!

    views.size.should eq(3)
    views.map(&.receipt).should eq(["REL-03001", "REL-03002", "REL-03003"])
    EntrySpec.lines_by_account(views[0]).should eq({
      EntrySpec.card_account(customer) => [{"credit", d("1200")}],
      "510001"                         => [{"debit", d("1200")}],
    })
    views[0].label.should eq("Virement client")
    EntrySpec.lines_by_account(views[1])["510001"].should eq([{"credit", d("300.50")}])
    EntrySpec.lines_by_account(views[1])[EntrySpec.card_account(supplier)].should eq([{"debit", d("300.50")}])
    views[2].date.should eq(EntrySpec.date("2026-03-25"))
    views[0].lines.find! { |line| line.account_number == "510001" }.card_code
      .should eq(Partiduo::Api::Cards.card(system, ReferentialSpec.present(EntrySpec.ledger("F01").bank_card_id)).code)
  end

  it "numérote chaque ligne sur la séquence du journal sans pièce saisie" do
    EntrySpec.setup
    ledger = EntrySpec.ledger("F01")
    views = Api.post_financial(system, financial([
      Api::PaymentLineInput.new(d("5"), account: "646"), Api::PaymentLineInput.new(d("6"), account: "646"),
    ])).value!
    views.map(&.receipt).uniq!.size.should eq(2)
    EntrySpec.ledger("F01").last_receipt_number.should eq(ledger.last_receipt_number + 2)
  end

  it "lettre le paiement avec la facture et publie payment.matched (ADR-004 D5)" do
    EntrySpec.setup
    customer = EntrySpec.card("CUSTOMER", "Client")
    invoice = sale(customer)
    ReferentialSpec.capture_events("payment.matched") do |events|
      payment = Api.post_financial(system, financial([
        Api::PaymentLineInput.new(d("1200"), card: customer.code, match_line_ids: [third_party_line(invoice).id]),
      ], source: "payment:3")).value!.first
      events.size.should eq(1)
      events[0]["entry_ids"].should eq([invoice.id, payment.id].sort.join(","))
      events[0]["sources"].should eq("payment:3")
      matching = Api.matching(system, events[0]["matching_id"].to_i64)
      matching.balanced?.should be_true
      matching.lines.map(&.entry_id).sort!.should eq([invoice.id, payment.id].sort)
    end
    statement = Api.account_statement(system, Api::StatementQuery.new(card: customer.code))
    statement.remaining.should eq(d("0"))
  end

  it "refuse avec des erreurs par ligne" do
    EntrySpec.setup
    customer = EntrySpec.card("CUSTOMER", "Client")
    invoice = sale(customer)
    result = Api.post_financial(system, financial([
      Api::PaymentLineInput.new(d("0"), card: customer.code),
      Api::PaymentLineInput.new(d("10")),
      Api::PaymentLineInput.new(d("10"), account: "646", match_line_ids: [third_party_line(invoice).id]),
      Api::PaymentLineInput.new(d("10"), account: "646", match_line_ids: [999999_i64]),
    ]))
    result.errors_for("lines[0].amount").map(&.key).should eq(["accounting.errors.entry.amount_zero"])
    result.errors_for("lines[1].card").map(&.key).should eq(["accounting.errors.entry.counterpart_missing"])
    result.errors_for("lines[2].match_line_ids").map(&.key).should eq(["accounting.errors.matching.different_accounts"])
    result.errors_for("lines[3].match_line_ids").map(&.key).should eq(["accounting.errors.matching.line_not_found"])
    ReferentialSpec.expect_translated(result)
    Api.count_entries(system).should eq(1)

    Api.post_financial(system, financial([Api::PaymentLineInput.new(d("1"), account: "646")]).copy_with(
      ledger_id: EntrySpec.ledger("O01").id)).error_keys.should eq(["accounting.errors.entry.ledger.not_financial"])
    Api.post_financial(system, financial([] of Api::PaymentLineInput)).error_keys
      .should eq(["accounting.errors.entry.no_items"])
  end

  it "contrôle sans écrire (check_financial)" do
    EntrySpec.setup
    drafts = Api.check_financial(system, financial([Api::PaymentLineInput.new(d("-40"), account: "646")])).value!
    drafts.size.should eq(1)
    drafts[0].lines.map { |line| {line.account_number, line.side.code} }.should eq([{"646", "debit"}, {"510001", "credit"}])
    Api.count_entries(system).should eq(0)
  end
end
