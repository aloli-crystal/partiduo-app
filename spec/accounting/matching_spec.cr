# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Lettrage (`Lettering::insert_couple`, `save`), d'après `letteringTest.php`
# et `acc_letterTest.php`.

private alias Api = Partiduo::Api::Accounting

private def system
  Partiduo::Api::Actor.system
end

private def d(text : String) : BigDecimal
  BigDecimal.new(text)
end

private def customer_line(view : Api::EntryView, card_id : Int64) : Api::EntryLineView
  view.lines.find! { |line| line.card_id == card_id }
end

private def invoice(customer, amount = "100", day = "2026-03-15") : Api::EntryView
  Api.post_sale(system, EntrySpec.document("V01", customer.code, [EntrySpec.item(amount, account: "706")], day)).value!
end

private def payment(customer, amount : String, day = "2026-03-20") : Api::EntryView
  Api.post_financial(system, Api::FinancialInput.new(ledger_id: EntrySpec.ledger("F01").id, date: EntrySpec.date(day),
    lines: [Api::PaymentLineInput.new(d(amount), card: customer.code)])).value!.first
end

describe_module "ACCOUNTING", "Lettrage" do
  it "lettre une facture et son paiement, publie payment.matched, puis délettre" do
    EntrySpec.setup
    customer = EntrySpec.card("CUSTOMER", "Client")
    sale = invoice(customer)
    paid = payment(customer, "120")
    ids = [customer_line(sale, customer.id).id, customer_line(paid, customer.id).id]

    matching = nil
    ReferentialSpec.capture_events("payment.matched") do |events|
      matching = Api.match_lines(system, ids).value!
      events.map(&.["matching_id"]).should eq([ReferentialSpec.present(matching).id.to_s])
    end
    matching = ReferentialSpec.present(matching)
    matching.balanced?.should be_true
    matching.code.should eq(Partiduo::Accounting::Matchings.code(matching.id))
    matching.account_number.should eq(EntrySpec.card_account(customer))
    matching.lines.map(&.ledger_kind).sort_by!(&.value).should eq([Api::LedgerKind::Sale, Api::LedgerKind::Financial])
    Api.entry(system, sale.id).lines.find! { |line| line.card_id == customer.id }.matching_code.should eq(matching.code)

    Api.unmatch(system, matching.id).value!
    Api.entry(system, sale.id).lines.all?(&.matching_id.nil?).should be_true
    expect_raises(Partiduo::Api::NotFound) { Api.matching(system, matching.id) }
  end

  it "admet un lettrage partiel puis le complète (paiement en deux fois)" do
    EntrySpec.setup
    customer = EntrySpec.card("CUSTOMER", "Client")
    sale = invoice(customer)
    first = payment(customer, "50")
    second = payment(customer, "70", "2026-03-28")

    partial = Api.match_lines(system, [customer_line(sale, customer.id).id, customer_line(first, customer.id).id]).value!
    partial.balanced?.should be_false
    partial.difference.should eq(d("70.00"))

    full = Api.match_lines(system, [customer_line(second, customer.id).id, customer_line(sale, customer.id).id]).value!
    full.balanced?.should be_true
    full.lines.size.should eq(3)
    expect_raises(Partiduo::Api::NotFound) { Api.matching(system, partial.id) }
  end

  it "ne publie pas payment.matched sans paiement ni facture" do
    EntrySpec.setup
    first = EntrySpec.post_misc([EntrySpec.debit("681", "10"), EntrySpec.credit("641", "10")])
    second = EntrySpec.post_misc([EntrySpec.debit("641", "10"), EntrySpec.credit("646", "10")])
    ReferentialSpec.capture_events("payment.matched") do |events|
      Api.match_lines(system, [first.lines[1].id, second.lines[0].id]).value!
      events.should be_empty
    end
  end

  it "refuse avec des erreurs sous line_ids" do
    EntrySpec.setup
    customer = EntrySpec.card("CUSTOMER", "Client")
    sale = invoice(customer)
    other = invoice(customer)
    line = customer_line(sale, customer.id)

    Api.match_lines(system, [line.id]).error_keys.should eq(["accounting.errors.matching.too_few_lines"])
    Api.match_lines(system, [line.id, line.id]).error_keys.should eq(["accounting.errors.matching.too_few_lines"])
    Api.match_lines(system, [line.id, 999999_i64]).error_keys.should eq(["accounting.errors.matching.line_not_found"])
    Api.match_lines(system, [line.id, sale.lines[0].id]).error_keys.should eq(["accounting.errors.matching.different_accounts"])
    Api.match_lines(system, [line.id, customer_line(other, customer.id).id]).error_keys
      .should eq(["accounting.errors.matching.one_side"])
    result = Api.check_matching(system, [line.id, 999999_i64])
    result.errors_for("line_ids").map(&.key).should eq(["accounting.errors.matching.line_not_found"])
    ReferentialSpec.expect_translated(result)
  end

  it "lettre dans une période close" do
    EntrySpec.setup
    customer = EntrySpec.card("CUSTOMER", "Client")
    sale = invoice(customer, "100", "2026-01-15")
    paid = payment(customer, "120", "2026-01-20")
    Partiduo::Api::Core.close_period(system, EntrySpec.period("2026-01-15").id).value!
    Api.match_lines(system, [customer_line(sale, customer.id).id, customer_line(paid, customer.id).id]).success?.should be_true
  end

  it "exige la permission accounting.matching.write" do
    expect_raises(Partiduo::Api::Forbidden) { Api.match_lines(actor_with("accounting.entry.read"), [1_i64, 2_i64]) }
    expect_raises(Partiduo::Api::Forbidden) { Api.unmatch(actor_with("accounting.entry.read"), 1_i64) }
  end

  it "code les lettrages en lettres" do
    {1_i64 => "A", 26_i64 => "Z", 27_i64 => "AA", 52_i64 => "AZ", 53_i64 => "BA", 703_i64 => "AAA"}.each do |id, code|
      Partiduo::Accounting::Matchings.code(id).should eq(code)
    end
  end
end
