# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Éditions (lot 3) : règles d'origine et cas limites — solde d'ouverture
# limité à l'exercice (D-ED-001), bornes de comptes (D-ED-002), tranches
# de la balance âgée (D-ED-003), cohérence balance / grand livre / journaux,
# colonne N-1 des états, rapports personnalisés (`Acc_Report`,
# `Impress::check_formula` et ses tests PHPUnit), FEC et formats d'export.

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

private def fec_body(file : Api::FileView, encoding : String = "ISO-8859-15") : Array(Array(String))
  String.new(file.content, encoding).split("\r\n").reject(&.empty?).map(&.split('|'))[1..]
end

describe Partiduo::Accounting::Formula do
  # `ImpressTest::test_check_formula` : ce que l'application d'origine admet ou refuse et
  # que Partiduo sait calculer.
  it "suit check_formula d'origine pour les références de comptes et de fiches" do
    {"1", "(45+5)", "round([45])", "[45%]", "[50]*[51%]", "[50]*9", "[50]*9.0", "[50%]*9.0 FROM=01.2004",
     "[50%]*9.0FROM=01.2004", "[45ABC]*1", "[4511-s]", "{TEL}", "{TEL}*45", "{TEL-s}*45", "{1TEL-s}*45",
     "{1TEL}*45"}.each do |text|
      {text, Partiduo::Accounting::Formula.check(text).try(&.key)}.should eq({text, nil})
      next if text.includes?("FROM")
      {text, Partiduo::Accounting::Formula.check("#{text}*#{text}+#{text}").try(&.key)}.should eq({text, nil})
    end
    {"system", "unlink", "ls -1", %(<script>document.location="https://yahoo.fr";</script>),
     "{T*EL-s}*45", "{T+EL-s}*45", "{T/EL-s}*45", "{T EL}", "{(TEL)}"}.each do |text|
      {text, Partiduo::Accounting::Formula.check(text).nil?}.should eq({text, false})
    end
  end
end

describe_module "ACCOUNTING", "Éditions : règles et cas limites" do
  describe ".trial_balance" do
    it "limite le solde d'ouverture à l'exercice de date_from (D-ED-001)" do
      ReportSpec.dataset
      ReferentialSpec.fiscal_year(2025)
      EntrySpec.post_misc([EntrySpec.debit("510001", "400"), EntrySpec.credit("101", "400")], "2025-06-01")

      view = Api.trial_balance(system, Api::TrialBalanceQuery.new(date_from: date("2026-03-01"), date_to: date("2026-06-30")))
      capital = view.rows.find!(&.number.==("101"))
      capital.opening.credit.should eq(d("10000"))
      capital.closing.credit.should eq(d("10000"))

      previous = Api.trial_balance(system, Api::TrialBalanceQuery.new(date_to: date("2025-12-31")))
      previous.date_from.should eq(date("2025-01-01"))
      previous.rows.map(&.number).should eq(%w[101 510001])
      previous.total.debit.should eq(d("400"))

      # Hors de tout exercice : du 1ᵉʳ janvier à date_to, rien à éditer.
      empty = Api.trial_balance(system, Api::TrialBalanceQuery.new(date_to: date("2030-06-30")))
      empty.date_from.should eq(date("2030-01-01"))
      empty.rows.should be_empty
      empty.total.debit.should eq(0)
      empty.summary.result.should eq(0)
    end

    it "rend une balance vide quand date_from dépasse date_to" do
      ReportSpec.dataset
      view = Api.trial_balance(system, Api::TrialBalanceQuery.new(date_from: date("2026-07-01"), date_to: date("2026-06-30")))
      view.rows.should be_empty
      view.classes.should be_empty
      view.delta.should eq(0)
    end

    it "fait couvrir à account_to ses sous-comptes (D-ED-002)" do
      data = ReportSpec.dataset
      customer_account = EntrySpec.card_account(data.customer)
      view = Api.trial_balance(system, Api::TrialBalanceQuery.new(account_from: "4", account_to: "4"))
      numbers = view.rows.map(&.number)
      numbers.should contain(customer_account)
      numbers.all?(&.starts_with?('4')).should be_true
      Api.trial_balance(system, Api::TrialBalanceQuery.new(account_to: "2")).rows.map(&.number).should eq(%w[101 281])
      Api.trial_balance(system, Api::TrialBalanceQuery.new(account_from: "7")).rows.map(&.number).should eq(%w[706])
    end

    it "totalise les classes colonne par colonne et laisse les classes 8 et 9 hors synthèse" do
      ReportSpec.dataset
      view = Api.trial_balance(system, Api::TrialBalanceQuery.new(date_to: date("2026-12-31")))
      view.classes.each do |klass|
        rows = view.rows.select(&.number.starts_with?(klass.number))
        klass.debit.should eq(rows.sum(BigDecimal.new(0), &.debit))
        klass.closing.debit.should eq(rows.sum(BigDecimal.new(0), &.closing.debit))
        klass.closing.credit.should eq(rows.sum(BigDecimal.new(0), &.closing.credit))
      end
      # Balance équilibrée : la synthèse 1-5 compense exactement le résultat.
      (view.summary.balance_sheet + view.summary.expenses + view.summary.income).should eq(0)
    end
  end

  describe "cohérence des éditions" do
    it "donne au grand livre et aux journaux les chiffres de la balance" do
      ReportSpec.dataset
      query_to = date("2026-12-31")
      balance = Api.trial_balance(system, Api::TrialBalanceQuery.new(date_to: query_to))
      ledger = Api.general_ledger(system, Api::GeneralLedgerQuery.new(date_to: query_to))
      ledger.sections.map(&.key).should eq(balance.rows.map(&.number))
      balance.rows.each do |row|
        section = ledger.sections.find!(&.key.==(row.number))
        section.total_debit.should eq(row.debit)
        section.total_credit.should eq(row.credit)
        section.closing_balance.should eq(row.closing.signed)
        section.lines.last.balance.should eq(section.closing_balance)
      end
      journals = Api.journals(system, Api::JournalQuery.new(date_to: query_to))
      journals.total_debit.should eq(balance.total.debit)
      journals.ledgers.each do |item|
        item.entries.each { |entry| entry.debit.should eq(entry.credit) }
        item.months.sum(BigDecimal.new(0), &.debit).should eq(item.total_debit)
        item.accounts.sum(BigDecimal.new(0), &.credit).should eq(item.total_credit)
        item.months.map(&.key).should eq(item.months.map(&.key).sort!)
      end
      by_card = Api.general_ledger(system, Api::GeneralLedgerQuery.new(by_card: true, date_to: query_to))
      auxiliary = Api.auxiliary_balance(system, Api::AuxiliaryBalanceQuery.new(date_to: query_to))
      by_card.sections.map(&.key).should eq(auxiliary.rows.map(&.card_code))
      auxiliary.rows.each do |row|
        by_card.sections.find!(&.key.==(row.card_code)).closing_balance.should eq(row.closing.signed)
      end
    end

    it "liste un journal sans écriture de la période, à zéro" do
      ReportSpec.dataset
      empty = AccountingSpec.create_ledger("Achats import", Api::LedgerKind::Purchase)
      view = Api.journals(system, Api::JournalQuery.new(ledger_ids: [empty.id]))
      view.ledgers.map(&.ledger_id).should eq([empty.id])
      view.ledgers.first.entries.should be_empty
      view.ledgers.first.total_debit.should eq(0)
      view.entries.should eq(0)
      Api.journals(system, Api::JournalQuery.new(ledger_ids: [] of Int64)).ledgers.should be_empty
    end
  end

  describe ".aged_balance" do
    it "classe à l'échéance : non échu, 1-30, 31-60, plus de 60 jours (ADR-005 D9)" do
      EntrySpec.setup
      card = EntrySpec.card("CUSTOMER", "Client Échéances")
      # Échéances à 0, 1, 30, 31, 60 et 61 jours du 27 septembre 2026.
      {"2026-09-27" => "10", "2026-09-26" => "20", "2026-08-28" => "30", "2026-08-27" => "40",
       "2026-07-29" => "50", "2026-07-28" => "60"}.each do |due, amount|
        Api.post_sale(system, EntrySpec.document("V01", card.code, [EntrySpec.item(amount, account: "706")],
          "2026-07-01", due_date: date(due))).value!
      end
      view = Api.aged_balance(system, Api::AgedBalanceQuery.new(as_of: date("2026-09-27")))
      row = view.rows.find!(&.card_id.==(card.id))
      row.items.map(&.days).sort!.should eq([0, 1, 30, 31, 60, 61])
      row.ageing.not_due.should eq(d("12"))
      row.ageing.days_1_30.should eq(d("60"))
      row.ageing.days_31_60.should eq(d("108"))
      row.ageing.over_60.should eq(d("72"))
      row.remaining.should eq(d("252"))
      row.overdue.should eq(d("240"))
      view.ageing.should eq(row.ageing)

      # Avant toute écriture : rien d'ouvert.
      Api.aged_balance(system, Api::AgedBalanceQuery.new(as_of: date("2026-06-30"))).rows.should be_empty
    end

    it "écarte un tiers entièrement lettré" do
      EntrySpec.setup
      card = EntrySpec.card("CUSTOMER", "Client soldé")
      sale = Api.post_sale(system, EntrySpec.document("V01", card.code, [EntrySpec.item("100", account: "706")],
        "2026-05-01", due_date: date("2026-05-31"))).value!
      Api.post_financial(system, Api::FinancialInput.new(ledger_id: EntrySpec.ledger("F01").id,
        date: date("2026-06-01"), lines: [Api::PaymentLineInput.new(d("120"), card: card.code,
        match_line_ids: [sale.lines.find! { |line| line.card_id == card.id }.id])])).value!
      Api.aged_balance(system).rows.should be_empty
      # Arrêtée avant le règlement, la créance reste ouverte et échue.
      before = Api.aged_balance(system, Api::AgedBalanceQuery.new(as_of: date("2026-05-31")))
      before.rows.first.remaining.should eq(d("120"))
      before.rows.first.overdue.should eq(0)
    end
  end

  describe ".financial_statement" do
    it "chiffre la colonne N-1 sur les mêmes dates un an plus tôt" do
      ReportSpec.dataset
      ReferentialSpec.fiscal_year(2025)
      EntrySpec.post_misc([EntrySpec.debit("6061", "50"), EntrySpec.credit("510001", "50")], "2025-05-01")
      income = Api.financial_statement(system, Api::FinancialStatementQuery.new(
        kind: Api::StatementKind::IncomeStatement, regime: "FR", date_to: date("2026-12-31")))
      income.regime.should eq("fr")
      income.previous_from.should eq(date("2025-01-01"))
      income.previous_to.should eq(date("2025-12-31"))
      income.line("purchases_materials").try(&.previous).should eq(d("50"))
      income.line("net_result").try(&.previous).should eq(d("-50"))
      income.line("net_result").try(&.net).should eq(d("680"))
      # Le résultat de l'état ne porte que sur la période.
      income.result.should eq(d("680"))
    end
  end

  describe "rapports personnalisés" do
    it "contrôle le nom, le nombre de lignes et les libellés" do
      EntrySpec.setup
      line = Api::ReportLineInput.new("Ventes", "[70%]")
      {
        Api::ReportDefinitionInput.new("   ", [line])                                                => {"name", "accounting.errors.report.name.blank"},
        Api::ReportDefinitionInput.new("x" * 101, [line])                                            => {"name", "accounting.errors.report.name.too_long"},
        Api::ReportDefinitionInput.new("Vide", [] of Api::ReportLineInput)                           => {"lines", "accounting.errors.report.lines.blank"},
        Api::ReportDefinitionInput.new("Trop", Array.new(501) { line })                              => {"lines", "accounting.errors.report.lines.too_many"},
        Api::ReportDefinitionInput.new("Long", [Api::ReportLineInput.new("y" * 256, "[70%]")])       => {"lines[0].label", "accounting.errors.report.label.too_long"},
        Api::ReportDefinitionInput.new("Rubrique", [Api::ReportLineInput.new("Renvoi", "$TOTAL+1")]) => {"lines[0].formula", "accounting.errors.formula.variable"},
        Api::ReportDefinitionInput.new("Vide formule", [Api::ReportLineInput.new("Rien", "  ")])     => {"lines[0].formula", "accounting.errors.formula.empty"},
      }.each do |input, expected|
        Api.check_report(system, input).errors.map { |error| {error.field, error.key} }.should eq([expected])
      end
      Api.check_report(system, Api::ReportDefinitionInput.new("x" * 100, Array.new(500) { line })).success?.should be_true
      Partiduo::Accounting::Report.all.count.should eq(0)
    end

    it "enregistre nom, libellés et formules sans leurs blancs, lignes dans l'ordre" do
      EntrySpec.setup
      report = Api.create_report(system, Api::ReportDefinitionInput.new("  Charges  ", [
        Api::ReportLineInput.new(" Achats ", " [60%-s] "),
        Api::ReportLineInput.new("Services", "[61%-s]+[62%-s]"),
      ])).value!
      report.name.should eq("Charges")
      report.lines.map { |item| {item.position, item.label, item.formula} }
        .should eq([{1, "Achats", "[60%-s]"}, {2, "Services", "[61%-s]+[62%-s]"}])
      # Un nom en d'autres capitales est un autre rapport (unicité exacte,
      # comme la contrainte en base).
      Api.create_report(system, Api::ReportDefinitionInput.new("charges", [Api::ReportLineInput.new("A", "1")]))
        .success?.should be_true
      Api.reports(system).map(&.name).sort!.should eq(%w[Charges charges])
    end

    it "calcule sur la période par défaut, avec FROM et des fiches inconnues à zéro" do
      data = ReportSpec.dataset
      report = Api.create_report(system, Api::ReportDefinitionInput.new("Cas limites", [
        Api::ReportLineInput.new("Ventes", "[706-c]"),
        Api::ReportLineInput.new("Après la période", "[706-c] FROM=10.2026"),
        Api::ReportLineInput.new("Fiche inconnue", "{ELECTR}+{ELECTR-c}"),
        Api::ReportLineInput.new("Fiche en capitales libres", "{#{data.customer.code.downcase}-d}"),
        Api::ReportLineInput.new("Valeur absolue", "[706]"),
        Api::ReportLineInput.new("Arrondi", "round(1/3, 2)*3"),
      ])).value!
      result = Api.run_report(system, report.id)
      result.date_from.should eq(date("2026-01-01"))
      result.date_to.should eq(date("2026-09-27"))
      result.lines.map(&.amount).should eq([d("1300"), d("0"), d("0"), d("1560"), d("1300"), d("0.99")])
      later = Api.run_report(system, report.id, date("2026-07-01"), date("2026-12-31"))
      later.lines.first.amount.should eq(d("300"))
    end
  end

  describe "rapports personnalisés : libellés" do
    it "remplace [606-T] et [606-t] par l'intitulé du premier compte du préfixe (Impress::parse_formula)" do
      ReportSpec.dataset
      report = Api.create_report(system, Api::ReportDefinitionInput.new("Intitulés", [
        Api::ReportLineInput.new("[6061-T] / [6061-t]", "[6061-s]"),
        Api::ReportLineInput.new("Inconnu : [999-T]", "1"),
        Api::ReportLineInput.new("Brut [606]", "1"),
      ])).value!
      report.lines.first.label.should eq("[6061-T] / [6061-t]")
      labels = Api.run_report(system, report.id, date("2026-01-01"), date("2026-12-31")).lines.map(&.label)
      labels.should eq(["FOURNITURES NON STOCKABLES / fournitures non stockables", "Inconnu : ", "Brut [606]"])
    end
  end

  describe ".fec" do
    it "numérote les écritures en continu, extournes comprises, sans zone vide obligatoire" do
      ReportSpec.dataset
      entry = EntrySpec.post_misc([EntrySpec.debit("681", "10"), EntrySpec.credit("281", "10")], "2026-08-01",
        label: "Loyer | mars")
      Api.cancel_entry(system, Api::CancelEntryInput.new(entry_id: entry.id, date: date("2026-08-02"))).value!
      body = fec_body(Api.fec(system).value!)
      body.all? { |fields| fields.size == 18 }.should be_true
      body.map(&.[2].to_i).uniq!.should eq((1..8).to_a)
      body.none? { |fields| fields[8].empty? || fields[10].empty? || fields[5].empty? }.should be_true
      body.any? { |fields| fields[10] == "Loyer   mars" }.should be_true
      debit = body.sum(BigDecimal.new(0)) { |fields| d(fields[11].tr(",", ".")) }
      credit = body.sum(BigDecimal.new(0)) { |fields| d(fields[12].tr(",", ".")) }
      debit.should eq(credit)
      body.all? { |fields| fields[11] =~ /\A\d+,\d{2}\z/ && fields[12] =~ /\A\d+,\d{2}\z/ }.should be_true
    end

    it "part de date_from dans l'exercice et garde la clôture dans le nom" do
      ReportSpec.dataset
      file = Api.fec(system, Api::FecQuery.new(date_from: date("2026-07-01"))).value!
      file.filename.should eq("000000000FEC20261231.txt")
      body = fec_body(file)
      body.map(&.[3]).all? { |day| day >= "20260701" }.should be_true
      body.first[2].should eq("1")
      expect_raises(Partiduo::Api::NotFound) { Api.fec(system, Api::FecQuery.new(fiscal_year_id: 999_999_i64)) }
      Api.fec(system, Api::FecQuery.new(date_from: date("2026-08-01"), date_to: date("2026-07-01"))).errors.map(&.key)
        .should eq(["accounting.errors.fec.fiscal_year"])
    end

    it "encode en ISO 8859-15 sans perdre d'octet sur un long texte (B-ED-001)" do
      bytes = Partiduo::Accounting::Fec.iso("€œŒŠšŽžŸ’…Ω¤é")
      bytes.to_a.should eq([0xA4, 0xBD, 0xBC, 0xA6, 0xA8, 0xB4, 0xB8, 0xBE, 0x27, 0x2E, 0x2E, 0x2E, 0x3F, 0x3F, 0xE9].map(&.to_u8))
      text = "Opérations diverses — fournitures à 5 € ; " * 5_000
      String.new(Partiduo::Accounting::Fec.iso(text), "ISO-8859-15")
        .should eq(text.gsub("—", "-"))
    end
  end

  describe "formats d'export" do
    it "écrit les montants selon la langue du PDF et au point décimal dans le CSV" do
      out = Partiduo::Accounting::ReportOutput
      out.format_amount(d("-1234567.5"), "fr").should eq("-1 234 567,50")
      out.format_amount(d("-1234567.5"), "en").should eq("-1,234,567.50")
      out.format_amount(d("1234567.5"), "nl").should eq("1.234.567,50")
      out.format_amount(d("0.005"), "fr").should eq("0,01")
      out.plain(d("-0.5")).should eq("-0.50")
      out.plain(d("12")).should eq("12.00")
      {"=1+1", "+33", "-x", "@SUM", "\tx", "\rx"}.each { |text| out.csv_text(text).should eq("'#{text}") }
      out.csv_text("Libellé").should eq("Libellé")
      out.format_date(date("2026-03-05"), "fr").should eq("05/03/2026")
      out.format_date(date("2026-03-05"), "nl").should eq("05-03-2026")
    end
  end
end
