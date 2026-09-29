# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Écritures de fin d'exercice (`Operation_Closing`, `Operation_Opening`,
# D-CLO-001) : clôture des comptes 6 et 7, réouverture (à-nouveaux) de
# l'exercice suivant, par le contrat.

private alias Api = Partiduo::Api::Accounting

private def system
  Partiduo::Api::Actor.system
end

private def d(text : String) : BigDecimal
  BigDecimal.new(text)
end

private def year(value : Int32) : Partiduo::Api::Core::FiscalYearView
  Partiduo::Api::Core.fiscal_years(system).find! { |item| item.year == value }
end

# Exercice 2025 : capital 10 000, ventes 1 500, achats 400 à un fournisseur.
private def book_2025 : Partiduo::Api::Cards::CardView
  EntrySpec.setup(year: 2025)
  ReferentialSpec.fiscal_year(2026)
  supplier = EntrySpec.card("SUPPLIER", "Fournisseur Durand")
  EntrySpec.post_misc([EntrySpec.debit("510001", "10000"), EntrySpec.credit("101", "10000")], "2025-01-02")
  EntrySpec.post_misc([EntrySpec.debit("510001", "1500"), EntrySpec.credit("706", "1500")], "2025-06-10")
  EntrySpec.post_misc([EntrySpec.debit("646", "400"), EntrySpec.credit("", "400", card: supplier.code)], "2025-07-01")
  supplier
end

private def input(fiscal_year : Int32, **options) : Api::ClosingInput
  Api::ClosingInput.new(fiscal_year_id: year(fiscal_year).id, ledger_id: EntrySpec.ledger("O01").id).copy_with(**options)
end

describe_module "ACCOUNTING", "Fin d'exercice : clôture et réouverture" do
  it "propose la clôture des comptes 6 et 7, le résultat au compte de bénéfice" do
    book_2025
    proposal = Api.closing_proposal(system, year(2025).id)
    proposal.kind.should eq("closing")
    proposal.date.should eq(EntrySpec.date("2025-12-31"))
    proposal.profit_account.should eq("120")
    lines = proposal.lines.map { |line| {line.account, line.side.code, line.amount} }
    lines.should eq([{"646", "credit", d("400")}, {"706", "debit", d("1500")}, {"120", "credit", d("1100")}])
    proposal.result.should eq(d("1100"))
    proposal.debit.should eq(proposal.credit)
    proposal.result_account_missing.should be_false
    proposal.posted?.should be_false
  end

  it "passe la clôture une seule fois, dans un journal d'opérations diverses" do
    book_2025
    Api.post_closing_entry(system, input(2025, ledger_id: EntrySpec.ledger("A01").id)).error_keys
      .should eq(["accounting.errors.closing.ledger_kind"])
    entry = Api.post_closing_entry(system, input(2025)).value!
    entry.date.should eq(EntrySpec.date("2025-12-31"))
    entry.source.should eq("closing:#{year(2025).id}")
    entry.label.should eq("Écriture de clôture de l'exercice 2025")
    Api.closing_proposal(system, year(2025).id).posted_entry_id.should eq(entry.id)
    Api.post_closing_entry(system, input(2025)).error_keys.should eq(["accounting.errors.closing.already_posted"])

    # Classes 6 et 7 soldées : plus rien à clôturer.
    Api.closing_proposal(system, year(2025).id).lines.should be_empty
  end

  it "reprend les soldes de bilan par compte et par fiche au premier jour de l'exercice suivant" do
    supplier = book_2025
    Api.post_closing_entry(system, input(2025)).value!
    proposal = Api.opening_proposal(system, year(2026).id)
    proposal.kind.should eq("opening")
    proposal.source_fiscal_year_id.should eq(year(2025).id)
    proposal.date.should eq(EntrySpec.date("2026-01-01"))
    rows = proposal.lines.map { |line| {line.account, line.card_code, line.side.code, line.amount} }
    rows.should contain({"101", nil, "credit", d("10000")})
    rows.should contain({"120", nil, "credit", d("1100")})
    rows.should contain({"510001", nil, "debit", d("11500")})
    rows.should contain({EntrySpec.card_account(supplier), supplier.code, "credit", d("400")})
    proposal.lines.none?(&.result).should be_true

    entry = Api.post_opening_entry(system, input(2026)).value!
    entry.date.should eq(EntrySpec.date("2026-01-01"))
    entry.lines.find! { |line| line.card_id == supplier.id }.amount.should eq(d("400"))
    Api.post_opening_entry(system, input(2026)).error_keys.should eq(["accounting.errors.closing.already_posted"])

    # La balance de 2026 reprend les soldes de fin 2025.
    balance = Api.trial_balance(system, Api::TrialBalanceQuery.new(date_from: EntrySpec.date("2026-01-01"),
      date_to: EntrySpec.date("2026-12-31")))
    balance.rows.find! { |row| row.number == "510001" }.closing.debit.should eq(d("11500"))
  end

  it "porte au compte de résultat le résultat que la clôture n'a pas soldé" do
    book_2025
    proposal = Api.opening_proposal(system, year(2026).id)
    result = proposal.lines.find!(&.result)
    {result.account, result.side.code, result.amount}.should eq({"120", "credit", d("1100")})
    proposal.debit.should eq(proposal.credit)
    Api.post_opening_entry(system, input(2026)).success?.should be_true
  end

  it "trouve 120 et 129 dans le plan FR initial (amendement D-CLO-003)" do
    EntrySpec.setup(year: 2025)
    EntrySpec.post_misc([EntrySpec.debit("646", "250"), EntrySpec.credit("510001", "250")], "2025-03-01")
    proposal = Api.closing_proposal(system, year(2025).id)
    {proposal.profit_account, proposal.loss_account}.should eq({"120", "129"})
    proposal.lines.last.account_label.should eq("Résultat de l'exercice (perte)")
    proposal.result_account_missing.should be_false
    Api.post_closing_entry(system, input(2025)).success?.should be_true
  end

  it "signale un compte de résultat absent et une perte au compte de perte" do
    EntrySpec.setup(year: 2025)
    # Compte retiré du plan (instance antérieure à l'amendement D-CLO-003).
    Api.delete_account(system, Api.account(system, "129").id).success?.should be_true
    EntrySpec.post_misc([EntrySpec.debit("646", "250"), EntrySpec.credit("510001", "250")], "2025-03-01")
    proposal = Api.closing_proposal(system, year(2025).id)
    proposal.lines.last.should eq(Api::ClosingLineView.new(account: "129", account_label: "", card_id: nil, card_code: nil,
      card_name: nil, card_disabled: false, side: Api::Side::Debit, amount: d("250"), result: true))
    proposal.result.should eq(d("-250"))
    proposal.result_account_missing.should be_true
    Api.post_closing_entry(system, input(2025)).error_keys.should eq(["accounting.errors.entry.account.not_found"])

    # Autre compte choisi par l'utilisateur.
    AccountingSpec.create_account("1190", "Report à nouveau (perte)", "1")
    Api.post_closing_entry(system, input(2025, loss_account: "1190")).success?.should be_true
  end

  it "refuse la réouverture sans exercice précédent, un exercice clos, et un acteur sans droit" do
    EntrySpec.setup(year: 2026)
    Api.post_opening_entry(system, input(2026)).error_keys.should eq(["accounting.errors.closing.no_previous"])
    Api.opening_proposal(system, year(2026).id).lines.should be_empty

    EntrySpec.post_misc([EntrySpec.debit("646", "10"), EntrySpec.credit("510001", "10")])
    Partiduo::Api::Core.close_fiscal_year(system, year(2026).id).value!
    Api.post_closing_entry(system, input(2026)).error_keys.should contain("accounting.errors.closing.fiscal_year_closed")

    reader = Partiduo::Api::Actor.user(1_i64, ["accounting.entry.read"], level: 3)
    expect_raises(Partiduo::Api::Forbidden) { Api.closing_proposal(reader, year(2026).id) }
  end
end
