# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Rapprochement bancaire (`compta_fin_rec.inc.php`, D-REC-001), par le
# contrat et en SQL direct pour la base.

private alias Api = Partiduo::Api::Accounting

private def system
  Partiduo::Api::Actor.system
end

private def d(text : String) : BigDecimal
  BigDecimal.new(text)
end

private def f01 : Int64
  EntrySpec.ledger("F01").id
end

# Trois opérations en banque : +1 200, -300,50, -12.
private def statement_lines : Array(Api::EntryView)
  EntrySpec.setup
  customer = EntrySpec.card("CUSTOMER", "Client payeur")
  Api.post_financial(system, Api::FinancialInput.new(ledger_id: f01, date: EntrySpec.date("2026-03-20"), lines: [
    Api::PaymentLineInput.new(d("1200"), card: customer.code),
    Api::PaymentLineInput.new(d("-300.50"), account: "646"),
    Api::PaymentLineInput.new(d("-12"), account: "646"),
  ], receipt: "REL-03")).value!
end

private def reconcile(ids : Array(Int64), reference = "R-001", start : String? = nil, finish : String? = nil)
  Api.reconcile(system, Api::ReconcileInput.new(ledger_id: f01, reference: reference, entry_ids: ids,
    start_balance: start.try { |value| d(value) }, end_balance: finish.try { |value| d(value) }))
end

describe_module "ACCOUNTING", "Rapprochement bancaire" do
  it "liste les opérations non rapprochées et leur montant pour la banque" do
    entries = statement_lines
    view = Api.reconciliation(system, f01)
    view.ledger_code.should eq("F01")
    view.account_number.should eq("510001")
    view.unreconciled.map(&.amount).should eq([d("1200"), d("-300.5"), d("-12")])
    view.unreconciled.map(&.entry_id).should eq(entries.map(&.id))
    view.balance.should eq(d("887.5"))
    view.reconciled_balance.should eq(d("0"))
    view.unreconciled_balance.should eq(d("887.5"))
    view.statements.should be_empty
  end

  it "rapproche un relevé dont le total égale l'écart des soldes" do
    entries = statement_lines
    statement = reconcile([entries[0].id, entries[1].id], start: "100", finish: "999.5").value!
    statement.reference.should eq("R-001")
    statement.amount.should eq(d("899.5"))
    statement.entry_count.should eq(2)

    view = Api.reconciliation(system, f01)
    view.unreconciled.map(&.entry_id).should eq([entries[2].id])
    view.reconciled_balance.should eq(d("899.5"))
    view.unreconciled_balance.should eq(d("-12"))
    view.statements.map(&.reference).should eq(["R-001"])

    detail = Api.bank_statement(system, statement.id)
    detail.lines.map(&.statement_reference).uniq!.should eq(["R-001"])
    EntrySpec.scalar("SELECT count(*) FROM accounting_entry WHERE statement_id = $1", statement.id).should eq(2)
  end

  it "refuse un total qui ne tombe pas juste, un numéro pris et une opération déjà rapprochée" do
    entries = statement_lines
    result = reconcile([entries[0].id], start: "0", finish: "1000")
    result.error_keys.should eq(["accounting.errors.reconciliation.mismatch"])
    result.errors.first.params.should eq({"expected" => "1000.00", "selected" => "1200.00", "difference" => "200.00"})
    # Soldes égaux ou absents : pas de contrôle (NOALYSS).
    reconcile([entries[0].id], start: "50", finish: "50").success?.should be_true
    reconcile([entries[1].id]).error_keys.should eq(["accounting.errors.reconciliation.reference.taken"])
    reconcile([entries[0].id], "R-002").error_keys.should eq(["accounting.errors.reconciliation.entries.invalid"])
    reconcile([] of Int64, "R-003").error_keys.should eq(["accounting.errors.reconciliation.entries.blank"])
    reconcile([entries[1].id], " ").error_keys.should eq(["accounting.errors.reconciliation.reference.blank"])
    sale = EntrySpec.post_misc([EntrySpec.debit("646", "5"), EntrySpec.credit("510001", "5")])
    reconcile([sale.id], "R-004").error_keys.should eq(["accounting.errors.reconciliation.entries.invalid"])
  end

  it "annule un rapprochement ; les opérations redeviennent à rapprocher" do
    entries = statement_lines
    statement = reconcile(entries.map(&.id)).value!
    Api.reconciliation(system, f01).unreconciled.should be_empty
    Api.unreconcile(system, statement.id).success?.should be_true
    Api.reconciliation(system, f01).unreconciled.size.should eq(3)
    expect_raises(Partiduo::Api::NotFound) { Api.bank_statement(system, statement.id) }
  end

  it "rapproche aussi en période close, sans toucher aux montants" do
    entries = statement_lines
    Partiduo::Api::Core.close_period(system, EntrySpec.period("2026-03-20").id).value!
    reconcile([entries[0].id]).success?.should be_true
    expect_raises(Exception, /période close/) do
      EntrySpec.sql_transaction { |db| db.exec("UPDATE accounting_entry SET amount = amount + 1 WHERE id = $1", entries[0].id) }
    end
  end

  it "réserve le rapprochement aux journaux financiers et au droit de lettrer" do
    statement_lines
    expect_raises(Partiduo::Api::NotFound) { Api.reconciliation(system, EntrySpec.ledger("O01").id) }
    reader = Partiduo::Api::Actor.user(1_i64, ["accounting.entry.read"], level: 3)
    expect_raises(Partiduo::Api::Forbidden) { Api.reconcile(reader, Api::ReconcileInput.new(f01, "X", [1_i64])) }
    Partiduo::Modules["ACCOUNTING"].menus.map(&.route).should contain("accounting:reconciliation")
  end
end
