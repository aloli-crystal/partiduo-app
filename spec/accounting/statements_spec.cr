# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Bilan et compte de résultat (`Acc_Bilan`, formulaires FR et BE de
# NOALYSS) et rapports personnalisés (`form_definition`).

private alias Api = Partiduo::Api::Accounting

private def system
  Partiduo::Api::Actor.system
end

private def d(text : String) : BigDecimal
  BigDecimal.new(text)
end

private def date(text : String) : Time
  EntrySpec.date(text)
end

private def line!(view : Api::FinancialStatementView, code : String) : Api::FinancialStatementLineView
  view.line(code) || raise "rubrique #{code} absente"
end

private def net(view : Api::FinancialStatementView, code : String) : BigDecimal?
  line!(view, code).net
end

private def statement(kind : Api::StatementKind, regime : String? = "fr", **options) : Api::FinancialStatementView
  Api.financial_statement(system, Api::FinancialStatementQuery.new(kind: kind, regime: regime,
    date_to: date("2026-12-31")).copy_with(**options))
end

describe_module "ACCOUNTING", "Bilan et compte de résultat" do
  describe ".financial_statement (FR)" do
    it "établit un bilan équilibré et un compte de résultat qui le rejoint" do
      ReportSpec.dataset
      sheet = statement(Api::StatementKind::BalanceSheet)
      sheet.regime.should eq("fr")
      sheet.date_from.should eq(date("2026-01-01"))
      tangible = line!(sheet, "tangible")
      tangible.gross.should eq(0)
      tangible.less.should eq(d("120"))
      tangible.net.should eq(d("-120"))
      net(sheet, "trade_receivables").should eq(d("960"))
      net(sheet, "other_receivables").should eq(d("100"))
      net(sheet, "cash").should eq(d("10600"))
      net(sheet, "total_assets").should eq(d("11540"))
      net(sheet, "capital").should eq(d("10000"))
      net(sheet, "result").should eq(d("680"))
      net(sheet, "trade_payables").should eq(d("600"))
      net(sheet, "other_debts").should eq(d("260"))
      net(sheet, "total_liabilities").should eq(d("11540"))
      sheet.difference.should eq(0)
      sheet.result.should eq(d("680"))
      sheet.unmapped.should be_empty
      sheet.anomalies.should be_empty
      line!(sheet, "assets").style.should eq("heading")
      line!(sheet, "assets").net.should be_nil
      line!(sheet, "total_fixed").less.should eq(d("120"))
      line!(sheet, "total_assets").label_key.should eq("accounting.statements.fr.balance_sheet.total_assets")
      sheet.previous_from.should eq(date("2025-01-01"))
      net(sheet, "total_assets").should_not eq(line!(sheet, "total_assets").previous)
      line!(sheet, "total_assets").previous.should eq(0)

      income = statement(Api::StatementKind::IncomeStatement)
      net(income, "production_sold").should eq(d("1300"))
      net(income, "purchases_materials").should eq(d("500"))
      net(income, "depreciation").should eq(d("120"))
      net(income, "total_operating_charges").should eq(d("620"))
      net(income, "operating_result").should eq(d("680"))
      net(income, "net_result").should eq(d("680"))
      income.difference.should eq(0)
      income.unmapped.should be_empty

      statement(Api::StatementKind::BalanceSheet, compare: false).previous_from.should be_nil
    end

    it "signale les comptes non repris et les soldes à contre-sens" do
      ReportSpec.dataset
      AccountingSpec.create_account("107", "Écart d'équivalence")
      EntrySpec.post_misc([EntrySpec.debit("510001", "50"), EntrySpec.credit("107", "50")], "2026-04-01")
      EntrySpec.post_misc([EntrySpec.debit("707", "30"), EntrySpec.credit("510001", "30")], "2026-04-02")
      sheet = statement(Api::StatementKind::BalanceSheet)
      sheet.unmapped.map(&.number).should eq(%w[107])
      sheet.unmapped.first.balance.should eq(d("-50"))
      sheet.difference.should eq(d("50"))
      income = statement(Api::StatementKind::IncomeStatement)
      income.anomalies.map(&.number).should eq(%w[707])
      income.anomalies.first.kind.should eq(Api::AccountKind::Income)
    end

    it "garde un compte de banque d'un seul côté, qu'une ligne porte la fiche Banque ou non" do
      EntrySpec.setup
      supplier = EntrySpec.card("SUPPLIER", "Fournisseur Gamma")
      payment = Api.post_financial(system, Api::FinancialInput.new(ledger_id: EntrySpec.ledger("F01").id,
        date: date("2026-03-05"), lines: [Api::PaymentLineInput.new(d("-6000"), card: supplier.code)])).value!.first
      bank_line = payment.lines.find! { |line| line.card_id != supplier.id }
      bank_line.card_id.should_not be_nil
      bank = bank_line.account_number
      # À-nouveau sans fiche : 5 000 au débit ; mouvements bancaires avec la
      # fiche Banque : 6 000 au crédit. Solde net : 1 000 créditeur.
      EntrySpec.post_misc([EntrySpec.debit(bank, "5000"), EntrySpec.credit("101", "5000")], "2026-01-01")
      sheet = statement(Api::StatementKind::BalanceSheet)
      line!(sheet, "cash").gross.should eq(0)
      net(sheet, "borrowings").should eq(d("1000"))
      sheet.difference.should eq(0)
      # Même règle dans un rapport personnalisé.
      report = Api.create_report(system, Api::ReportDefinitionInput.new("Banque", [
        Api::ReportLineInput.new("Débiteur", "[#{bank}-D]"), Api::ReportLineInput.new("Créditeur", "[#{bank}-C]"),
      ])).value!
      Api.run_report(system, report.id, date("2026-01-01"), date("2026-12-31")).lines.map(&.amount)
        .should eq([d("0"), d("1000")])
    end

    it "arrête un bilan à date_to depuis le début de l'exercice, quelle que soit date_from" do
      ReportSpec.dataset
      whole = statement(Api::StatementKind::BalanceSheet)
      mid = statement(Api::StatementKind::BalanceSheet, date_from: date("2026-06-01"))
      mid.date_from.should eq(date("2026-01-01"))
      net(mid, "total_assets").should eq(net(whole, "total_assets"))
      net(mid, "capital").should eq(d("10000"))
      income = statement(Api::StatementKind::IncomeStatement, date_from: date("2026-06-01"))
      income.date_from.should eq(date("2026-06-01"))
      net(income, "production_sold").should eq(d("300"))
    end

    it "signale un état établi sur une partie des journaux" do
      ReportSpec.dataset
      user_id, reader = AccountingSpec.user_actor("sheet@example.test", "accounting.report.read")
      Api.financial_statement(reader, Api::FinancialStatementQuery.new(kind: Api::StatementKind::BalanceSheet)).partial.should be_false
      Partiduo::Api::Auth.set_ledger_security(system, user_id, true).value!
      Partiduo::Api::Auth.set_ledger_access(system, user_id, EntrySpec.ledger("O01").id, "R").value!
      query = Api::FinancialStatementQuery.new(kind: Api::StatementKind::BalanceSheet, date_to: date("2026-12-31"))
      Api.financial_statement(reader, query).partial.should be_true
      Api.export(reader, query, Api::ExportFormat::Csv).content.should_not be_empty
    end

    it "prend le régime de l'instance et refuse un régime inconnu" do
      ReportSpec.dataset
      statement(Api::StatementKind::BalanceSheet, nil).regime.should eq("fr")
      expect_raises(Partiduo::Api::NotFound) { statement(Api::StatementKind::BalanceSheet, "lu") }
      Api.statement_regimes(system).should eq(%w[fr be])
    end
  end

  describe ".financial_statement (BE)" do
    it "établit le bilan et le compte de résultats du schéma abrégé" do
      EntrySpec.setup("be")
      AccountingSpec.create_account("6100", "Loyers")
      EntrySpec.post_misc([EntrySpec.debit("550", "10000"), EntrySpec.credit("100", "10000")], "2026-01-02")
      EntrySpec.post_misc([EntrySpec.debit("400", "1210"), EntrySpec.credit("700", "1000"), EntrySpec.credit("451", "210")],
        "2026-02-01")
      EntrySpec.post_misc([EntrySpec.debit("6100", "200"), EntrySpec.credit("440", "200")], "2026-02-02")
      sheet = statement(Api::StatementKind::BalanceSheet, "be")
      net(sheet, "short_term_receivables").should eq(d("1210"))
      net(sheet, "cash").should eq(d("10000"))
      net(sheet, "total_assets").should eq(d("11210"))
      net(sheet, "contribution").should eq(d("10000"))
      net(sheet, "result_pending").should eq(d("800"))
      net(sheet, "trade_debts").should eq(d("200"))
      net(sheet, "tax_social_debts").should eq(d("210"))
      net(sheet, "total_liabilities").should eq(d("11210"))
      sheet.difference.should eq(0)
      sheet.unmapped.should be_empty

      income = statement(Api::StatementKind::IncomeStatement, "be")
      net(income, "revenue").should eq(d("1000"))
      net(income, "purchases").should eq(d("200"))
      net(income, "gross_margin").should eq(d("800"))
      net(income, "operating_result").should eq(d("800"))
      net(income, "net_result").should eq(d("800"))
      income.difference.should eq(0)
    end

    it "laisse les comptes d'affectation 69 et 79 hors du résultat de l'exercice" do
      EntrySpec.setup("be")
      AccountingSpec.create_account("6100", "Loyers")
      EntrySpec.post_misc([EntrySpec.debit("550", "10000"), EntrySpec.credit("100", "10000")], "2026-01-02")
      EntrySpec.post_misc([EntrySpec.debit("400", "1000"), EntrySpec.credit("700", "1000")], "2026-02-01")
      EntrySpec.post_misc([EntrySpec.debit("6100", "200"), EntrySpec.credit("440", "200")], "2026-02-02")
      EntrySpec.post_misc([EntrySpec.debit("693", "800"), EntrySpec.credit("140", "800")], "2026-12-31")
      income = statement(Api::StatementKind::IncomeStatement, "be")
      net(income, "net_result").should eq(d("800"))
      income.result.should eq(d("800"))
      income.difference.should eq(0)
    end
  end

  describe "rapports personnalisés" do
    it "enregistre, contrôle, calcule et efface un rapport" do
      data = ReportSpec.dataset
      input = Api::ReportDefinitionInput.new("Marge", [
        Api::ReportLineInput.new("Ventes", "[70%-S]"),
        Api::ReportLineInput.new("Charges", "[6%]"),
        Api::ReportLineInput.new("Marge", "round([70%-S]-[6%-s], 2)"),
        Api::ReportLineInput.new("Client", "{#{data.customer.code}-s}"),
        Api::ReportLineInput.new("Ventes depuis juillet", "[706%-c] FROM=07.2026"),
        Api::ReportLineInput.new("Ratio", "[681%]/[6%-s]*100"),
        Api::ReportLineInput.new("Division par zéro", "[70%]/[2%-d]"),
      ])
      Api.check_report(system, input).success?.should be_true
      report = Api.create_report(system, input).value!
      report.lines.map(&.position).should eq([1, 2, 3, 4, 5, 6, 7])
      Api.reports(system).map(&.name).should eq(%w[Marge])

      result = Api.run_report(system, report.id, date("2026-01-01"), date("2026-12-31"))
      result.lines.map(&.amount).should eq([d("1300"), d("620"), d("680"), d("960"), d("300"), d("19.35"), d("0")])

      bad = Api::ReportDefinitionInput.new("Marge", [
        Api::ReportLineInput.new("", "[70%"),
        Api::ReportLineInput.new("Analytique", "{{PA1}}"),
        Api::ReportLineInput.new("Variable", "$C1"),
        Api::ReportLineInput.new("Fonction", "sqrt(4)"),
      ])
      errors = Api.create_report(system, bad).errors
      errors.map { |error| {error.field, error.key} }.should eq([
        {"name", "accounting.errors.report.name.taken"},
        {"lines[0].label", "accounting.errors.report.label.blank"},
        {"lines[0].formula", "accounting.errors.formula.syntax"},
        {"lines[1].formula", "accounting.errors.formula.analytic"},
        {"lines[2].formula", "accounting.errors.formula.variable"},
        {"lines[3].formula", "accounting.errors.formula.function"},
      ])
      Api.check_report(system, Api::ReportDefinitionInput.new("Marge", input.lines), report.id).success?.should be_true

      long = Api::ReportDefinitionInput.new("Longue", [Api::ReportLineInput.new("Longue", "1+" * 600 + "1")])
      Api.check_report(system, long).errors.map { |error| {error.field, error.key} }
        .should eq([{"lines[0].formula", "accounting.errors.report.formula.too_long"}])
      # 100 000 parenthèses : refus sans déborder la pile.
      deep = Api::ReportDefinitionInput.new("Profonde", [Api::ReportLineInput.new("Profonde", "(" * 100_000)])
      Api.check_report(system, deep).errors.map(&.key).should eq(["accounting.errors.report.formula.too_long"])
      Api.update_report(system, report.id, deep).errors.map(&.key).should eq(["accounting.errors.report.formula.too_long"])

      updated = Api.update_report(system, report.id, Api::ReportDefinitionInput.new("Marge brute",
        [Api::ReportLineInput.new("Ventes", "[70%-S]")])).value!
      updated.lines.size.should eq(1)
      Api.report(system, report.id).name.should eq("Marge brute")

      expect_raises(Partiduo::Api::Forbidden) { Api.create_report(actor_with("accounting.report.read"), input) }
      Api.delete_report(system, report.id).success?.should be_true
      expect_raises(Partiduo::Api::NotFound) { Api.report(system, report.id) }
      EntrySpec.scalar("SELECT count(*) FROM accounting_report_line").should eq(0)
    end
  end
end
