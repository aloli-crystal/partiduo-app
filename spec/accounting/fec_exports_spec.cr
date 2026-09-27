# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"
require "pdf-validate"

# FEC (article A47 A-1 du LPF ; extension `noalyss-export`) et exports CSV
# et PDF des éditions.

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

private def fec_rows(file : Api::FileView, separator : Char = '|', encoding : String = "ISO-8859-15") : Array(Array(String))
  String.new(file.content, encoding).split("\r\n").reject(&.empty?).map(&.split(separator))
end

private def amount(text : String) : BigDecimal
  BigDecimal.new(text.tr(",", "."))
end

describe_module "ACCOUNTING", "FEC et exports" do
  describe ".fec" do
    it "produit un FEC conforme de l'exercice" do
      data = ReportSpec.dataset(provisioned: true)
      file = Api.fec(system).value!
      file.filename.should eq("732829320FEC20261231.txt")
      file.content_type.should eq("text/plain; charset=iso-8859-15")
      rows = fec_rows(file)
      rows.first.should eq(Partiduo::Accounting::Fec::COLUMNS)
      body = rows[1..]
      body.all? { |fields| fields.size == 18 }.should be_true
      body.map(&.[2].to_i).uniq!.should eq([1, 2, 3, 4, 5, 6])
      body.sum { |fields| amount(fields[11]) }.should eq(d("12880"))
      body.sum { |fields| amount(fields[12]) }.should eq(d("12880"))
      body.map(&.[3]).should eq(body.map(&.[3]).sort!)
      body.first[3].should eq("20260102")
      body.first[0].should eq("O01")

      sale = body.select { |fields| fields[8] == data.sale.receipt }
      customer_line = sale.find! { |fields| fields[6] == data.customer.code }
      customer_line[7].should eq("Client Alpha")
      customer_line[4].should eq(EntrySpec.card_account(data.customer))
      customer_line[11].should eq("1200,00")
      customer_line[12].should eq("0,00")
      customer_line[13].should_not be_empty
      customer_line[14].should match(/\A\d{8}\z/)
      customer_line[15].should match(/\A\d{8}\z/)
      customer_line[16].should eq("")
      sale.find! { |fields| fields[4] == "706" }[6].should eq("")
      # Lettrage identique sur le règlement.
      body.count { |fields| fields[13] == customer_line[13] }.should eq(2)
    end

    it "nomme le fichier d'après le SIREN et la clôture, en tabulation et UTF-8 à la demande" do
      ReportSpec.dataset
      file = Api.fec(system, Api::FecQuery.new(separator: Api::FecSeparator::Tab, encoding: Api::FecEncoding::Utf8)).value!
      file.filename.should eq("000000000FEC20261231.txt")
      file.content_type.should eq("text/plain; charset=utf-8")
      rows = fec_rows(file, '\t', "UTF-8")
      rows.first.size.should eq(18)
      rows.any? { |fields| fields[1] == "Opérations diverses" }.should be_true
    end

    it "reprend les écritures d'un exercice désigné et refuse des dates à cheval" do
      ReportSpec.dataset
      year = Partiduo::Api::Core.fiscal_years(system).first
      Api.fec(system, Api::FecQuery.new(fiscal_year_id: year.id)).value!.filename.should end_with("FEC20261231.txt")
      ReferentialSpec.fiscal_year(2027)
      failure = Api.fec(system, Api::FecQuery.new(date_from: date("2026-06-01"), date_to: date("2027-02-01")))
      failure.errors.map(&.key).should eq(["accounting.errors.fec.fiscal_year"])
      Api.fec(system, Api::FecQuery.new(date_to: date("2030-01-01"))).errors.map(&.key)
        .should eq(["accounting.errors.fec.fiscal_year"])
    end

    it "exige de voir tous les journaux" do
      ReportSpec.dataset
      user_id, reader = AccountingSpec.user_actor("fec@example.test", "accounting.report.read")
      Api.fec(reader).success?.should be_true
      Partiduo::Api::Auth.set_ledger_security(system, user_id, true).value!
      Partiduo::Api::Auth.set_ledger_access(system, user_id, EntrySpec.ledger("O01").id, "R").value!
      Api.fec(reader).errors.map(&.key).should eq(["accounting.errors.fec.ledgers"])
      # Les autres éditions se limitent aux journaux visibles.
      Api.trial_balance(reader).rows.map(&.number).should eq(%w[101 281 510001 681])
    end
  end

  describe ".export" do
    it "exporte chaque édition en CSV" do
      ReportSpec.dataset
      csv = Api.export(system, Api::TrialBalanceQuery.new, Api::ExportFormat::Csv)
      csv.content_type.should eq("text/csv")
      csv.filename.should eq("trial-balance-20260101-20260927.csv")
      lines = String.new(csv.content).lines
      lines.first.should eq("Compte;Libellé;Ouverture débit;Ouverture crédit;Débit;Crédit;Solde débiteur;Solde créditeur")
      lines.should contain("706;Prestations de services;0.00;0.00;0.00;1300.00;0.00;1300.00")

      {Api::AuxiliaryBalanceQuery.new, Api::AgedBalanceQuery.new, Api::GeneralLedgerQuery.new,
       Api::GeneralLedgerQuery.new(by_card: true), Api::JournalQuery.new,
       Api::FinancialStatementQuery.new(kind: Api::StatementKind::BalanceSheet),
       Api::FinancialStatementQuery.new(kind: Api::StatementKind::IncomeStatement, regime: "fr")}.each do |query|
        file = Api.export(system, query, Api::ExportFormat::Csv)
        String.new(file.content).lines.size.should be > 2
      end
      I18n.with_locale("en") do
        header = String.new(Api.export(system, Api::JournalQuery.new, Api::ExportFormat::Csv).content).lines.first
        header.should eq("Date;Document;Internal code;Account;Card;Label;Debit;Credit")
      end
    end

    it "exporte en PDF/A-2b valide" do
      ReportSpec.dataset
      {Api::TrialBalanceQuery.new, Api::GeneralLedgerQuery.new, Api::AgedBalanceQuery.new,
       Api::FinancialStatementQuery.new(kind: Api::StatementKind::BalanceSheet)}.each do |query|
        file = Api.export(system, query, Api::ExportFormat::Pdf)
        file.content_type.should eq("application/pdf")
        file.filename.should end_with(".pdf")
        String.new(file.content[0, 5]).should eq("%PDF-")
        report = PDF::Validate.bytes(file.content, profile: "pdf-a-2b")
        report.fatal_failures.map(&.rule.id).should eq([] of String)
      end
    end

    it "exporte un rapport personnalisé" do
      ReportSpec.dataset
      report = Api.create_report(system, Api::ReportDefinitionInput.new("Résultat",
        [Api::ReportLineInput.new("Résultat", "[7%-S]-[6%-s]")])).value!
      csv = Api.export_report(system, report.id, Api::ExportFormat::Csv)
      csv.filename.should start_with("r-sultat-")
      String.new(csv.content).lines.last.should eq("Résultat;[7%-S]-[6%-s];680.00")
      Api.export_report(system, report.id, Api::ExportFormat::Pdf).content.size.should be > 1000
    end

    it "protège les cellules de texte contre les formules" do
      ReportSpec.dataset
      EntrySpec.post_misc([EntrySpec.debit("681", "1"), EntrySpec.credit("281", "1")], "2026-08-01", label: "=HYPERLINK(1)")
      text = String.new(Api.export(system, Api::JournalQuery.new, Api::ExportFormat::Csv).content)
      text.should contain("'=HYPERLINK(1)")
      text.should_not contain(";=HYPERLINK")
    end
  end
end
