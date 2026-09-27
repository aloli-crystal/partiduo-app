# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"
require "csv"
require "compress/zip"

private alias Api = Partiduo::Api::Invoicing

private def d(text : String) : BigDecimal
  BigDecimal.new(text)
end

private def year_2026 : {Time, Time}
  {InvoicingSpec.date("2026-01-01"), InvoicingSpec.date("2026-12-31")}
end

# ADR-006 D4 : Facturation seule, transmission au comptable.
describe_module "INVOICING", "Facturation — transmission au comptable" do
  it "exporte le journal des ventes et des encaissements en CSV, équilibré par pièce" do
    setup = InvoicingSpec.setup
    invoice = InvoicingSpec.issued(setup, lines: [InvoicingSpec.line(setup, "10"),
                                                  InvoicingSpec.line(setup, "1", vat_rate_id: setup.rates["TR55"].id)])
    credit = Api.transform(InvoicingSpec.actor, invoice.id, Api::TransformInput.new("credit_note")).value!
    Api.update_document(InvoicingSpec.actor, credit.id, InvoicingSpec.document_input(setup, "credit_note",
      credited_document_id: invoice.id, lines: [InvoicingSpec.line(setup, "1")])).value!
    InvoicingSpec.issue(credit.id, "2026-09-20")
    InvoicingSpec.issued(setup, "quote") # hors journal
    unless Partiduo::Modules.active?("ACCOUNTING")
      Api.record_payment(InvoicingSpec.actor, Api::PaymentInput.new(document_id: invoice.id, amount: d("100"),
        paid_on: InvoicingSpec.date("2026-09-25"))).value!
    end
    from, to = year_2026
    file = Api.sales_journal_csv(InvoicingSpec.actor, from, to)
    file.content_type.should eq("text/csv")
    rows = CSV.parse(String.new(file.content), separator: ';')
    rows.first.should eq(%w[journal date piece kind customer_code customer_name account auxiliary label debit credit currency])
    body = rows[1..]
    body.map(&.[2]).uniq!.should eq(["F-2026-0001", "AV-2026-0001"])
    body.group_by { |row| {row[0], row[2]} }.each_value do |movements|
      movements.sum(BigDecimal.new(0)) { |row| d(row[9]) }.should eq(movements.sum(BigDecimal.new(0)) { |row| d(row[10]) })
    end
    customer = body.find! { |row| row[0] == "VT" && row[6] == "411000" && row[2] == "F-2026-0001" }
    customer[7].should eq("CLIENT")
    d(customer[9]).should eq(invoice.totals.total_gross)
    body.count { |row| row[0] == "VT" && row[6] == "445710" && row[2] == "F-2026-0001" }.should eq(2)
    credit_customer = body.find! { |row| row[2] == "AV-2026-0001" && row[6] == "411000" }
    d(credit_customer[10]).should eq(d("96"))
    unless Partiduo::Modules.active?("ACCOUNTING")
      bank = body.select { |row| row[0] == "BQ" }
      bank.map(&.[6]).should eq(["512000", "411000"])
    end
  end

  it "exporte les ventes au format FEC (18 colonnes, ventes seules)" do
    setup = InvoicingSpec.setup
    invoice = InvoicingSpec.issued(setup)
    from, to = year_2026
    file = Api.sales_fec(InvoicingSpec.actor, from, to).value!
    file.filename.should eq("732829320FEC20261231.txt")
    lines = String.new(file.content).split("\r\n").reject(&.empty?)
    lines.first.split('|').should eq(Partiduo::Invoicing::Exports::FEC_COLUMNS)
    lines.first.split('|').size.should eq(18)
    records = lines[1..].map(&.split('|'))
    records.all? { |fields| fields.size == 18 }.should be_true
    records.map(&.[0]).uniq!.should eq(["VT"])
    records.first[3].should eq("20260915")
    records.first[6].should eq("CLIENT")
    records.sum(BigDecimal.new(0)) { |fields| d(fields[11].tr(",", ".")) }
      .should eq(records.sum(BigDecimal.new(0)) { |fields| d(fields[12].tr(",", ".")) })
    d(records.first[11].tr(",", ".")).should eq(invoice.totals.total_gross)
  end

  it "archive en ZIP les PDF Factur-X d'une période, avec un index" do
    setup = InvoicingSpec.setup
    first = InvoicingSpec.issued(setup, on: "2026-09-01")
    Partiduo::Config.travel_to(Time.utc(2026, 10, 1, 9)) { InvoicingSpec.issued(setup, on: "2026-10-01") }
    file = Api.pdf_archive(InvoicingSpec.actor, InvoicingSpec.date("2026-09-01"), InvoicingSpec.date("2026-09-30"))
    file.content_type.should eq("application/zip")
    entries = {} of String => Bytes
    Compress::Zip::Reader.open(IO::Memory.new(file.content)) do |zip|
      zip.each_entry { |entry| entries[entry.filename] = entry.io.getb_to_end }
    end
    entries.keys.sort!.should eq(["F-2026-0001.pdf", "index.csv"])
    entries["F-2026-0001.pdf"].should eq(Api.document_pdf(InvoicingSpec.actor, first.id).content)
    index = CSV.parse(String.new(entries["index.csv"]), separator: ';')
    index[1][0].should eq("F-2026-0001")
    index[1][7].should eq(Digest::SHA256.hexdigest(entries["F-2026-0001.pdf"]))
  end

  it "extourne les acomptes déduits : le client ne porte que le solde, ventes et TVA ne sont pas comptées deux fois" do
    setup = InvoicingSpec.setup
    order = InvoicingSpec.issued(setup, "order", on: "2026-09-10")
    deposit = Api.transform(InvoicingSpec.actor, order.id,
      Api::TransformInput.new("deposit_invoice", deposit_percent: d("40"))).value!
    deposit = InvoicingSpec.issue(deposit.id, "2026-09-12")
    final = Api.transform(InvoicingSpec.actor, order.id, Api::TransformInput.new("invoice")).value!
    final = InvoicingSpec.issue(final.id, "2026-09-20")
    final.totals.prepaid.should eq(deposit.totals.total_gross)
    accounts = Partiduo::Invoicing::Configuration.accounts
    from, to = year_2026

    rows = CSV.parse(String.new(Api.sales_journal_csv(InvoicingSpec.actor, from, to).content), separator: ';')[1..]
      .select { |row| row[0] == "VT" }
    rows.group_by(&.[2]).each_value do |movements|
      movements.sum(BigDecimal.new(0)) { |row| d(row[9]) }.should eq(movements.sum(BigDecimal.new(0)) { |row| d(row[10]) })
    end
    balance = ->(account : String, piece : String?) do
      rows.select { |row| row[6] == account && (piece.nil? || row[2] == piece) }
        .sum(BigDecimal.new(0)) { |row| d(row[9]) - d(row[10]) }
    end
    balance.call(accounts[:customer], final.number).should eq(final.totals.total_gross - deposit.totals.total_gross)
    # Sur l'ensemble du journal : ce que la facture finale porte, une seule fois.
    balance.call(accounts[:customer], nil).should eq(final.totals.total_gross)
    balance.call(accounts[:sales], nil).should eq(-final.totals.total_net)
    balance.call(accounts[:vat], nil).should eq(-final.totals.total_vat)
    reversal = rows.select { |row| row[2] == final.number && row[9] != "0.00" && row[6] != accounts[:customer] }
    reversal.map(&.[6]).sort!.should eq([accounts[:sales], accounts[:vat]].sort!)
    reversal.all?(&.[8].includes?(deposit.number.to_s)).should be_true

    records = String.new(Api.sales_fec(InvoicingSpec.actor, from, to).value!.content).split("\r\n").reject(&.empty?)[1..]
      .map(&.split('|'))
    amount = ->(text : String) { d(text.tr(",", ".")) }
    fec_balance = ->(account : String) do
      records.select { |fields| fields[4] == account }.sum(BigDecimal.new(0)) { |fields| amount.call(fields[11]) - amount.call(fields[12]) }
    end
    fec_balance.call(accounts[:customer]).should eq(final.totals.total_gross)
    fec_balance.call(accounts[:sales]).should eq(-final.totals.total_net)
    fec_balance.call(accounts[:vat]).should eq(-final.totals.total_vat)
  end

  it "neutralise les formules dans les cellules texte du CSV" do
    setup = InvoicingSpec.setup
    customers = Partiduo::Api::Cards.category_by_code(Partiduo::Api::Actor.system, "CUSTOMER") || raise "CUSTOMER absente"
    formula = Partiduo::Api::Cards.create_card(Partiduo::Api::Actor.system, Partiduo::Api::Cards::CardInput.new(
      category_id: customers.id, name: "=HYPERLINK(\"http://x.test\")", code: "FORMULE",
      address: Partiduo::Api::Cards::AddressInput.new(line1: "1 rue", postcode: "44000", city: "Nantes",
        country_code: "FR"))).value!
    InvoicingSpec.issued(setup, customer_card_id: formula.id)
    from, to = year_2026
    rows = CSV.parse(String.new(Api.sales_journal_csv(InvoicingSpec.actor, from, to).content), separator: ';')[1..]
    rows.map(&.[5]).uniq!.should eq(["'=HYPERLINK(\"http://x.test\")"])
    rows.all?(&.[8].starts_with?("Facture ")).should be_true
    Partiduo::Invoicing::Exports.cell("+33 1 23").should eq("'+33 1 23")
    Partiduo::Invoicing::Exports.cell("-5").should eq("'-5")
    Partiduo::Invoicing::Exports.cell("@SUM(A1)").should eq("'@SUM(A1)")
    Partiduo::Invoicing::Exports.cell("Client").should eq("Client")
  end

  it "convertit en devise de tenue les documents en devise étrangère du FEC, ou refuse sans cours" do
    setup = InvoicingSpec.setup
    system = Partiduo::Api::Actor.system
    Partiduo::Api::Core.create_currency(system, Partiduo::Api::Core::CurrencyInput.new(code: "USD", name: "Dollar",
      rate: d("1.2"), valid_from: InvoicingSpec.date("2026-01-01"))).value!
    invoice = InvoicingSpec.issued(setup, currency_code: "USD", lines: [InvoicingSpec.line(setup, "1", unit_price: d("100.01")),
                                                                        InvoicingSpec.line(setup, "1", unit_price: d("33.33"))])
    from, to = year_2026
    records = String.new(Api.sales_fec(InvoicingSpec.actor, from, to).value!.content).split("\r\n").reject(&.empty?)[1..]
      .map(&.split('|'))
    amount = ->(text : String) { d(text.tr(",", ".")) }
    records.sum(BigDecimal.new(0)) { |fields| amount.call(fields[11]) }
      .should eq(records.sum(BigDecimal.new(0)) { |fields| amount.call(fields[12]) })
    customer = records.find! { |fields| fields[6] == "CLIENT" }
    amount.call(customer[16]).should eq(invoice.totals.total_gross) # 160,01 USD
    customer[17].should eq("USD")
    sales = records.select { |fields| fields[4] == "706000" }
    sales.sum(BigDecimal.new(0)) { |fields| amount.call(fields[12]) }.should eq(d("111.12")) # 133,34 / 1,2
    records.all? { |fields| fields[17] == "USD" }.should be_true

    Partiduo::Api::Core.create_currency(system, Partiduo::Api::Core::CurrencyInput.new(code: "GBP", name: "Livre",
      rate: d("0.9"), valid_from: InvoicingSpec.date("2026-12-01"))).value!
    InvoicingSpec.issued(setup, on: "2026-09-16", currency_code: "GBP")
    result = Api.sales_fec(InvoicingSpec.actor, from, to)
    result.error_keys.should eq(["invoicing.errors.export.currency_rate"])
    result.errors.first.params["code"].should eq("GBP")
    ReferentialSpec.expect_translated(result)
  end

  it "exige la permission de transmission" do
    InvoicingSpec.setup
    from, to = year_2026
    expect_raises(Partiduo::Api::Forbidden) { Api.sales_fec(actor_with("invoicing.invoice.read"), from, to) }
  end
end

describe_module "INVOICING", "Facturation — paramètres" do
  it "contrôle et enregistre les paramètres" do
    InvoicingSpec.setup
    actor = InvoicingSpec.actor
    defaults = Api.settings(actor)
    defaults.payment_terms_days.should eq(30)
    bad = defaults.to_input.copy_with(payment_terms_days: 400, late_penalty_rate: d("-1"), iban: "FR00 1234",
      reminder1_days: 30, reminder2_days: 10, sales_journal_code: "ventes", customer_account: "411-000",
      default_operation_category: "autre", sender_email: "x")
    result = Api.check_settings(actor, bad)
    result.errors.map(&.field).sort!.should eq(%w[customer_account default_operation_category iban late_penalty_rate
      payment_terms_days reminder1_days sales_journal_code sender_email])
    ReferentialSpec.expect_translated(result)
    Api.update_settings(actor, bad).failure?.should be_true
    saved = Api.update_settings(actor, defaults.to_input.copy_with(payment_terms_days: 45,
      iban: "fr76 3000 6000 0112 3456 7890 189", bic: "agrifrpp")).value!
    saved.iban.should eq("FR7630006000011234567890189")
    saved.bic.should eq("AGRIFRPP")
    Api.settings(actor).payment_terms_days.should eq(45)
    expect_raises(Partiduo::Api::Forbidden) { Api.update_settings(actor_with("invoicing.invoice.read"), saved.to_input) }
  end
end
