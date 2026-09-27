# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Éditions (lot 3) : droits (`accounting.report.read` / `.write`), module
# Comptabilité inactif, journaux visibles de l'acteur (`get_ledger_sql`,
# D-ED-011) et contraintes d'intégrité des rapports personnalisés.

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

private def report_input(name : String = "Résultat") : Api::ReportDefinitionInput
  Api::ReportDefinitionInput.new(name, [Api::ReportLineInput.new("Résultat", "[7%-S]-[6%-s]")])
end

private def sheet_query : Api::FinancialStatementQuery
  Api::FinancialStatementQuery.new(kind: Api::StatementKind::BalanceSheet, regime: "fr")
end

# Chaque lecture d'édition, appelée pour `actor`.
private def each_reading(actor : Partiduo::Api::Actor, report_id : Int64, & : String, Proc(Nil) ->) : Nil
  csv = Api::ExportFormat::Csv
  {
    "trial_balance"       => -> { Api.trial_balance(actor); nil },
    "auxiliary_balance"   => -> { Api.auxiliary_balance(actor); nil },
    "aged_balance"        => -> { Api.aged_balance(actor); nil },
    "general_ledger"      => -> { Api.general_ledger(actor); nil },
    "journals"            => -> { Api.journals(actor); nil },
    "statement_regimes"   => -> { Api.statement_regimes(actor); nil },
    "financial_statement" => -> { Api.financial_statement(actor, sheet_query); nil },
    "reports"             => -> { Api.reports(actor); nil },
    "report"              => -> { Api.report(actor, report_id); nil },
    "run_report"          => -> { Api.run_report(actor, report_id); nil },
    "export_report"       => -> { Api.export_report(actor, report_id, csv); nil },
    "export trial"        => -> { Api.export(actor, Api::TrialBalanceQuery.new, csv); nil },
    "export auxiliary"    => -> { Api.export(actor, Api::AuxiliaryBalanceQuery.new, csv); nil },
    "export aged"         => -> { Api.export(actor, Api::AgedBalanceQuery.new, csv); nil },
    "export ledger"       => -> { Api.export(actor, Api::GeneralLedgerQuery.new, csv); nil },
    "export journals"     => -> { Api.export(actor, Api::JournalQuery.new, csv); nil },
    "export statement"    => -> { Api.export(actor, sheet_query, Api::ExportFormat::Pdf); nil },
    "fec"                 => -> { Api.fec(actor); nil },
  }.each { |name, call| yield name, call }
end

# Chaque écriture de rapport personnalisé, appelée pour `actor`.
private def each_writing(actor : Partiduo::Api::Actor, report_id : Int64, & : String, Proc(Nil) ->) : Nil
  {
    "check_report"  => -> { Api.check_report(actor, report_input("Autre")); nil },
    "create_report" => -> { Api.create_report(actor, report_input("Autre")); nil },
    "update_report" => -> { Api.update_report(actor, report_id, report_input("Autre")); nil },
    "delete_report" => -> { Api.delete_report(actor, report_id); nil },
  }.each { |name, call| yield name, call }
end

private def forbidden?(call : Proc(Nil)) : Bool
  call.call
  false
rescue Partiduo::Api::Forbidden
  true
end

describe "Éditions : module Comptabilité inactif" do
  it "refuse chaque édition et chaque écriture de rapport (ModuleDisabled)" do
    with_active_modules("invoicing") do
      each_reading(system, 1_i64) do |name, call|
        refused = begin
          call.call
          false
        rescue Partiduo::Api::ModuleDisabled
          true
        end
        {name, refused}.should eq({name, true})
      end
      each_writing(system, 1_i64) do |name, call|
        refused = begin
          call.call
          false
        rescue Partiduo::Api::ModuleDisabled
          true
        end
        {name, refused}.should eq({name, true})
      end
    end
  end
end

describe_module "ACCOUNTING", "Éditions : droits et journaux visibles" do
  describe "permissions" do
    it "exige accounting.report.read pour chaque édition, avant toute recherche" do
      ReportSpec.dataset
      report = Api.create_report(system, report_input).value!
      without = actor_with("accounting.entry.read", "accounting.report.write")
      each_reading(without, report.id) do |name, call|
        {name, forbidden?(call)}.should eq({name, true})
      end
      # Droit vérifié avant l'existence : pas de fuite par NotFound.
      expect_raises(Partiduo::Api::Forbidden) { Api.report(without, 999_999_i64) }
      expect_raises(Partiduo::Api::Forbidden) { Api.run_report(without, 999_999_i64) }

      _, reader = AccountingSpec.user_actor("editions@example.test", "accounting.report.read")
      each_reading(reader, report.id) do |name, call|
        {name, forbidden?(call)}.should eq({name, false})
      end
    end

    it "exige accounting.report.write pour contrôler, créer, modifier et effacer un rapport" do
      ReportSpec.dataset
      report = Api.create_report(system, report_input).value!
      reader = actor_with("accounting.report.read")
      each_writing(reader, report.id) do |name, call|
        {name, forbidden?(call)}.should eq({name, true})
      end
      Api.report(system, report.id).name.should eq("Résultat")
      expect_raises(Partiduo::Api::Forbidden) { Api.delete_report(reader, 999_999_i64) }

      _, writer = AccountingSpec.user_actor("rapports@example.test", "accounting.report.write")
      created = Api.create_report(writer, report_input("Du rédacteur")).value!
      Partiduo::Accounting::Report.get!(id: created.id).created_by_id.should_not be_nil
      # Écrire n'emporte pas lire.
      expect_raises(Partiduo::Api::Forbidden) { Api.report(writer, created.id) }
      Api.delete_report(writer, created.id).success?.should be_true
    end
  end

  describe "journaux visibles" do
    it "ne lit que les journaux visibles, même quand la requête en cite d'autres" do
      data = ReportSpec.dataset
      user_id, reader = AccountingSpec.user_actor("o01@example.test", "accounting.report.read")
      Partiduo::Api::Auth.set_ledger_security(system, user_id, true).value!
      Partiduo::Api::Auth.set_ledger_access(system, user_id, EntrySpec.ledger("O01").id, "R").value!
      sales = EntrySpec.ledger("V01").id

      Api.trial_balance(reader, Api::TrialBalanceQuery.new(ledger_ids: [sales])).rows.should be_empty
      Api.trial_balance(reader).total.debit.should eq(d("10120"))
      Api.auxiliary_balance(reader).rows.should be_empty
      Api.aged_balance(reader).rows.should be_empty
      Api.aged_balance(reader, Api::AgedBalanceQuery.new(card: data.customer.code)).rows.should be_empty
      Api.general_ledger(reader).sections.map(&.key).should eq(%w[101 281 510001 681])
      Api.general_ledger(reader, Api::GeneralLedgerQuery.new(by_card: true)).sections.should be_empty
      journals = Api.journals(reader, Api::JournalQuery.new(ledger_ids: [sales, EntrySpec.ledger("O01").id]))
      journals.ledgers.map(&.ledger_code).should eq(%w[O01])
      journals.entries.should eq(2)

      income = Api.financial_statement(reader, Api::FinancialStatementQuery.new(
        kind: Api::StatementKind::IncomeStatement, regime: "fr", date_to: date("2026-12-31")))
      income.result.should eq(d("-120"))
      income.line("production_sold").try(&.net).should eq(0)

      report = Api.create_report(system, report_input).value!
      Api.run_report(reader, report.id, date("2026-01-01"), date("2026-12-31")).lines.first.amount.should eq(d("-120"))
      Api.run_report(system, report.id, date("2026-01-01"), date("2026-12-31")).lines.first.amount.should eq(d("680"))

      # Les exports suivent la même règle.
      csv = String.new(Api.export(reader, Api::JournalQuery.new, Api::ExportFormat::Csv).content)
      csv.should_not contain("Facture 1")
    end
  end

  describe "intégrité des rapports personnalisés en base" do
    it "refuse deux rapports du même nom, même hors du contrat" do
      ReportSpec.dataset
      Api.create_report(system, report_input).value!
      expect_raises(Exception, /accounting_report_name_key|unique/i) do
        EntrySpec.sql("INSERT INTO accounting_report (name, created_at, updated_at) VALUES ('Résultat', now(), now())")
      end
      # Le contrat compare le nom débarrassé de ses blancs.
      Api.create_report(system, report_input("  Résultat ")).errors.map(&.key)
        .should eq(["accounting.errors.report.name.taken"])
    end

    it "refuse une ligne sans rapport et un rapport effacé qui garderait ses lignes" do
      ReportSpec.dataset
      report = Api.create_report(system, report_input).value!
      expect_raises(Exception, /foreign key|violates/i) do
        EntrySpec.sql_transaction do |db|
          db.exec("INSERT INTO accounting_report_line (position, label, formula, report_id) VALUES (1, 'x', '1', 999999)")
        end
      end
      expect_raises(Exception, /foreign key|violates/i) do
        EntrySpec.sql_transaction do |db|
          db.exec("DELETE FROM accounting_report WHERE id = $1", report.id)
        end
      end
      Api.report(system, report.id).lines.size.should eq(1)
      # Par le contrat, les lignes partent avec le rapport.
      Api.delete_report(system, report.id).success?.should be_true
      EntrySpec.scalar("SELECT count(*) FROM accounting_report_line WHERE report_id = $1", report.id).should eq(0)
    end

    it "garde le rapport intact quand une modification est refusée" do
      ReportSpec.dataset
      report = Api.create_report(system, report_input).value!
      Api.create_report(system, report_input("Autre")).value!
      failure = Api.update_report(system, report.id, Api::ReportDefinitionInput.new("Autre",
        [Api::ReportLineInput.new("Cassée", "[70%")]))
      failure.errors.map(&.field).should eq(%w[name lines[0].formula])
      kept = Api.report(system, report.id)
      kept.name.should eq("Résultat")
      kept.lines.map(&.formula).should eq(["[7%-S]-[6%-s]"])
      expect_raises(Partiduo::Api::NotFound) { Api.update_report(system, 999_999_i64, report_input("Neuf")) }
      expect_raises(Partiduo::Api::NotFound) { Api.delete_report(system, 999_999_i64) }
      expect_raises(Partiduo::Api::NotFound) { Api.run_report(system, 999_999_i64) }
      expect_raises(Partiduo::Api::NotFound) { Api.export_report(system, 999_999_i64, Api::ExportFormat::Csv) }
    end
  end
end
