# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# TVA exigible à l'encaissement au prorata des encaissements partiels
# (DECISIONS D-TVA-004 révisée, D-R5-005).

private alias Api = Partiduo::Api::Accounting

private def system
  Partiduo::Api::Actor.system
end

private def d(text : String) : BigDecimal
  BigDecimal.new(text)
end

# Dossier français, taux de services exigible à l'encaissement (`SERV`)
# retenu seul dans la ligne 08.
private def on_payment_customer : Partiduo::Api::Cards::CardView
  VatReturnSpec.setup("fr")
  customer = VatReturnSpec.card("CUSTOMER", "Client Durand")
  services = ReferentialSpec.vat_rate("SERV", "20", label: "Services à l'encaissement", sale_on_payment: true)
  Api.set_vat_rate_accounts(system, Api::VatRateAccountsInput.new(services.id, "445661", "44571")).value!
  %w[08.base 08.tax].each do |box|
    source = box.ends_with?("base") ? "base" : "collected"
    Api.set_vat_box_rules(system, "fr", box, [Api::VatBoxRuleInput.new(vat_rate_code: "SERV", ledger_kind: "sale", source: source)]).value!
  end
  customer
end

private def customer_line(entry : Api::EntryView, customer : Partiduo::Api::Cards::CardView) : Int64
  entry.lines.find! { |line| line.card_id == customer.id && line.vat_role.nil? }.id
end

private def payment(customer : Partiduo::Api::Cards::CardView, amount : String, day : String, match : Array(Int64) = [] of Int64) : Int64
  entry = Api.post_financial(system, Api::FinancialInput.new(ledger_id: EntrySpec.ledger("F01").id,
    date: EntrySpec.date(day), lines: [Api::PaymentLineInput.new(d(amount), card: customer.code, match_line_ids: match)])).value!.first
  customer_line(entry, customer)
end

private def box08(month : Int32) : {BigDecimal, BigDecimal}
  view = Api.preview_vat_return(system, VatReturnSpec.input("fr_ca3", "month", month)).value!
  {view.amount("08.base"), view.amount("08.tax")}
end

describe_module "ACCOUNTING", "TVA à l'encaissement : prorata des encaissements partiels" do
  it "déclare chaque encaissement partiel au mois où il est reçu, sans reste" do
    customer = on_payment_customer
    invoice = VatReturnSpec.sale(customer, [EntrySpec.item("1000", "SERV", account: "706")], "2026-03-10")
    line = customer_line(invoice, customer)
    payment(customer, "300", "2026-04-08", [line])
    payment(customer, "900", "2026-05-20", [line])

    box08(3).should eq({d("0"), d("0")})
    box08(4).should eq({d("250"), d("50")})
    box08(5).should eq({d("750"), d("150")})
    box08(6).should eq({d("0"), d("0")})
    # Sur le trimestre : l'opération entière, une fois payée.
    q2 = Api.preview_vat_return(system, VatReturnSpec.input("fr_ca3", "quarter", 2)).value!
    {q2.amount("08.base"), q2.amount("08.tax")}.should eq({d("1000"), d("200")})
  end

  it "règle les factures d'un même lettrage dans l'ordre chronologique" do
    customer = on_payment_customer
    first = VatReturnSpec.sale(customer, [EntrySpec.item("1000", "SERV", account: "706")], "2026-02-10")
    second = VatReturnSpec.sale(customer, [EntrySpec.item("500", "SERV", account: "706")], "2026-03-05")
    april = payment(customer, "1500", "2026-04-15")
    may = payment(customer, "300", "2026-05-15")
    Api.match_lines(system, [customer_line(first, customer), customer_line(second, customer), april, may]).value!
      .balanced?.should be_true

    # Avril : la première facture entière (1 200 TTC), la moitié de la
    # seconde (300 sur 600) ; mai : le reste de la seconde.
    box08(4).should eq({d("1250"), d("250")})
    box08(5).should eq({d("250"), d("50")})
  end

  it "ne rend rien exigible avant l'opération et garde l'acompte reçu d'avance au mois de la facture" do
    customer = on_payment_customer
    advance = payment(customer, "600", "2026-01-20")
    invoice = VatReturnSpec.sale(customer, [EntrySpec.item("1000", "SERV", account: "706")], "2026-02-10")
    Api.match_lines(system, [customer_line(invoice, customer), advance]).value!
    box08(1).should eq({d("0"), d("0")})
    box08(2).should eq({d("500"), d("100")})
  end

  it "laisse l'exigibilité à l'opération inchangée" do
    customer = on_payment_customer
    invoice = VatReturnSpec.sale(customer, [EntrySpec.item("1000", "SERV", account: "706")], "2026-03-10")
    payment(customer, "300", "2026-04-08", [customer_line(invoice, customer)])
    view = Api.preview_vat_return(system, VatReturnSpec.input("fr_ca3", "month", 3, exigibility: "operation")).value!
    view.amount("08.base").should eq(d("1000"))
  end
end
