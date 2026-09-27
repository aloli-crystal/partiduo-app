# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Ventilation des lignes d'écriture (`Anc_Operation::save_form_plan`,
# `save_update_form`, `Acc_Ledger::reverse`) et opérations diverses
# analytiques (`Anc_Group_Operation`).

private alias Api = Partiduo::Api::Analytic
private alias Acc = Partiduo::Api::Accounting

private def system
  Partiduo::Api::Actor.system
end

private def d(text : String) : BigDecimal
  BigDecimal.new(text)
end

private def row(amount : String, *posts : Api::PostView) : Api::DistributionRowInput
  Api::DistributionRowInput.new(d(amount), posts.to_a.map(&.id))
end

private def misc_row(amount : String, side : Acc::Side, *posts : Api::PostView, card : String? = nil) : Api::MiscRowInput
  Api::MiscRowInput.new(d(amount), side, posts.to_a.map(&.id), card)
end

describe_module "ANALYTIC", "Analytique : ventilation des écritures" do
  it "ventile une ligne sur plusieurs lignes et plusieurs plans, puis la reventile" do
    data = AnalyticSpec.setup
    entry = AnalyticSpec.expense("1000", account: "603")
    views = AnalyticSpec.distribute(entry, [
      row("600", data[:sale], data[:p1]),
      row("400", data[:workshop]),
    ]).value!
    views.size.should eq(1)
    view = views.first
    view.kind.should eq("entry")
    view.entry_id.should eq(entry.id)
    view.entry_line_id.should eq(entry.lines[0].id)
    view.account_number.should eq("603")
    view.ledger_code.should eq("O01")
    view.internal_code.should eq(entry.internal_code)
    view.line_amount.should eq(d("1000"))
    view.date.should eq(entry.date)
    view.rows.map { |item| {item.position, item.amount, item.side.code, item.posts.map(&.code)} }
      .should eq([{0, d("600"), "debit", ["VENTE", "P1"]}, {1, d("400"), "debit", ["ATELIER"]}])
    view.total_for(data[:activity].id).should eq(d("1000"))
    view.total_for(data[:project].id).should eq(d("600"))

    AnalyticSpec.distribute(entry, [row("1000", data[:p2])]).value!
    Api.entry_distributions(system, entry.id).first.rows.map(&.posts.map(&.code)).should eq([["P2"]])
    Partiduo::Analytic::Operation.all.count.should eq(1)

    AnalyticSpec.distribute(entry, [] of Api::DistributionRowInput).value!.should be_empty
    Api.entry_distributions(system, entry.id).should be_empty
  end

  it "refuse un total par plan supérieur au montant, un compte non ventilé, une ligne étrangère" do
    data = AnalyticSpec.setup
    entry = AnalyticSpec.expense("100")
    result = AnalyticSpec.distribute(entry, [row("80", data[:sale]), row("30", data[:workshop], data[:p1])])
    result.error_keys.should eq(["analytic.errors.distribution.exceeds"])
    result.errors.first.field.should eq("lines[0]")
    result.errors.first.params.should eq({"plan" => "ACTIVITÉ", "total" => "110.00", "amount" => "100.00"})

    AnalyticSpec.distribute(entry, [row("100", data[:sale])], position: 1).error_keys
      .should eq(["analytic.errors.distribution.account_not_analytic"])
    other = AnalyticSpec.expense("50")
    Api.distribute_entry(system, entry.id, [Api::LineDistributionInput.new(other.lines[0].id, [row("50", data[:sale])])])
      .errors.map(&.field).should eq(["lines[0].line_id"])

    AnalyticSpec.distribute(entry, [row("0", data[:sale]), row("1.00001", data[:workshop]), Api::DistributionRowInput.new(d("5"), [] of Int64)]).error_keys
      .should eq(["analytic.errors.distribution.amount_invalid", "analytic.errors.distribution.amount_scale",
                  "analytic.errors.distribution.post_required"])
    AnalyticSpec.distribute(entry, [row("10", data[:sale], data[:workshop])]).error_keys
      .should eq(["analytic.errors.distribution.plan_twice"])
    Api.check_distribution(system, entry.id,
      [Api::LineDistributionInput.new(entry.lines[0].id, [row("100", data[:sale])])]).success?.should be_true
  end

  it "refuse un poste inactif, sauf s'il est déjà imputé à la ligne" do
    data = AnalyticSpec.setup
    entry = AnalyticSpec.expense("100")
    AnalyticSpec.distribute(entry, [row("100", data[:sale])]).value!
    Api.update_post(system, data[:sale].id, Api::PostInput.new(data[:activity].id, "VENTE", active: false)).value!
    AnalyticSpec.distribute(entry, [row("60", data[:sale]), row("40", data[:sale], data[:p1])]).success?.should be_true
    other = AnalyticSpec.expense("10")
    result = AnalyticSpec.distribute(other, [row("10", data[:sale])])
    result.error_keys.should eq(["analytic.errors.distribution.post_inactive"])
    result.errors.first.params.should eq({"code" => "VENTE"})
  end

  it "exige en mode obligatoire une ventilation complète dans chaque plan" do
    data = AnalyticSpec.setup
    AnalyticSpec.mandatory!
    entry = AnalyticSpec.expense("100")
    result = AnalyticSpec.distribute(entry, [row("100", data[:sale])])
    result.error_keys.should eq(["analytic.errors.distribution.incomplete"])
    result.errors.first.params["plan"].should eq("PROJET")
    AnalyticSpec.distribute(entry, [row("100", data[:sale], data[:p1])]).success?.should be_true
    AnalyticSpec.distribute(entry, [] of Api::DistributionRowInput).error_keys
      .should eq(["analytic.errors.distribution.required"])
  end

  it "enregistre écriture et ventilation ensemble, ou rien (mode obligatoire)" do
    data = AnalyticSpec.setup
    AnalyticSpec.mandatory!
    input = EntrySpec.misc_input([EntrySpec.debit("603", "300"), EntrySpec.debit("681", "200"), EntrySpec.credit("400", "500")])
    missing = Api.post_entry(system, input, [Api::InputDistributionInput.new(0, [row("300", data[:sale], data[:p1])])])
    missing.error_keys.should eq(["analytic.errors.distribution.required"])
    missing.errors.first.field.should eq("distributions[input=1]")
    Acc.entries(system).should be_empty

    unknown = Api.post_entry(system, input, [Api::InputDistributionInput.new(7, [row("1", data[:sale])])])
    unknown.errors.map(&.field).should contain("distributions[0].input_index")
    Acc.entries(system).should be_empty

    entry = Api.post_entry(system, input, [
      Api::InputDistributionInput.new(0, [row("300", data[:sale], data[:p1])]),
      Api::InputDistributionInput.new(1, [row("150", data[:workshop], data[:p1]), row("50", data[:workshop], data[:p2])]),
    ]).value!
    Api.entry_distributions(system, entry.id).map(&.account_number).should eq(["603", "681"])

    failed = Api.post_entry(system, EntrySpec.misc_input([EntrySpec.debit("603", "1"), EntrySpec.credit("400", "2")]),
      [] of Api::InputDistributionInput)
    failed.error_keys.should eq(["accounting.errors.entry.unbalanced"])
  end

  it "ventile une facture d'achat par le rang de ses lignes saisies, sans deviner l'écriture produite" do
    data = AnalyticSpec.setup
    supplier = EntrySpec.card("SUPPLIER", "Fournisseur ventilé")
    # Ligne 0 nulle (écartée par le cœur), ligne 1 imputée : la ventilation
    # désigne la ligne saisie 1, quelle que soit sa position dans l'écriture.
    input = EntrySpec.document("A01", supplier.code, [EntrySpec.item("0", account: "604"), EntrySpec.item("100", account: "603")])
    entry = Api.post_purchase(system, input, [
      Api::InputDistributionInput.new(0, post_ids: [data[:sale].id]),
      Api::InputDistributionInput.new(1, [row("100", data[:workshop])]),
    ]).value!
    entry.lines.find! { |line| line.account_number == "603" }.input_index.should eq(1)
    views = Api.entry_distributions(system, entry.id)
    views.map { |item| {item.account_number, item.line_amount} }.should eq([{"603", d("100")}])
  end

  it "ventile la ligne entière ou par une clé, au montant de la ligne d'écriture calculé par le cœur" do
    data = AnalyticSpec.setup
    AnalyticSpec.mandatory!
    key = Api.create_key(system, Api::KeyInput.new("MOITIÉ", [
      Api::KeyRowInput.new(d("50"), [data[:sale].id, data[:p1].id]),
      Api::KeyRowInput.new(d("50"), [data[:workshop].id, data[:p2].id]),
    ])).value!
    input = EntrySpec.misc_input([EntrySpec.debit("603", "300"), EntrySpec.debit("681", "200"), EntrySpec.credit("400", "500")])
    entry = Api.post_entry(system, input, [
      Api::InputDistributionInput.new(0, post_ids: [data[:sale].id, data[:p1].id]),
      Api::InputDistributionInput.new(1, key_id: key.id),
    ]).value!
    views = Api.entry_distributions(system, entry.id)
    views.map { |item| {item.account_number, item.rows.map(&.amount)} }.should eq([{"603", [d("300")]}, {"681", [d("100"), d("100")]}])

    unknown = Api.post_entry(system, input, [
      Api::InputDistributionInput.new(0, post_ids: [data[:sale].id, data[:p1].id]),
      Api::InputDistributionInput.new(1, key_id: 999_999_i64),
    ])
    unknown.errors.map(&.key).should contain("analytic.errors.key.unknown")
  end

  it "reporte la ventilation inverse sur l'extourne d'une écriture annulée" do
    data = AnalyticSpec.setup
    entry = AnalyticSpec.expense("250")
    AnalyticSpec.distribute(entry, [row("200", data[:sale], data[:p1]), row("50", data[:workshop])]).value!
    reversal = Acc.cancel_entry(system, Acc::CancelEntryInput.new(entry.id, EntrySpec.date("2026-04-02"))).value!
    views = Api.entry_distributions(system, reversal.id)
    views.size.should eq(1)
    view = views.first
    view.entry_line_id.should eq(reversal.lines[0].id)
    view.date.should eq(EntrySpec.date("2026-04-02"))
    view.rows.map { |item| {item.amount, item.side.code, item.posts.map(&.code)} }
      .should eq([{d("200"), "credit", ["VENTE", "P1"]}, {d("50"), "credit", ["ATELIER"]}])
    balance = Api.balance(system, Api::ReportQuery.new(data[:activity].id))
    balance.rows.map(&.amounts.balance).should eq([d("0"), d("0")])
  end

  it "fige la ventilation d'une période close, en base aussi" do
    data = AnalyticSpec.setup
    entry = AnalyticSpec.expense("100")
    AnalyticSpec.distribute(entry, [row("100", data[:sale])]).value!
    Partiduo::Api::Core.close_period(system, EntrySpec.period("2026-03-15").id).value!
    AnalyticSpec.distribute(entry, [row("100", data[:workshop])]).error_keys
      .should eq(["analytic.errors.distribution.closed_period"])
    expect_raises(Exception, /période close/) do
      EntrySpec.sql_transaction { |db| db.exec("DELETE FROM analytic_operation") }
    end
    expect_raises(Exception, /période close/) do
      EntrySpec.sql_transaction { |db| db.exec("UPDATE analytic_distribution SET description = 'x'") }
    end
    Partiduo::Analytic::Operation.all.count.should eq(1)
  end

  it "garantit en base le poste du plan et un montant positif" do
    data = AnalyticSpec.setup
    entry = AnalyticSpec.expense("100")
    AnalyticSpec.distribute(entry, [row("100", data[:sale])]).value!
    expect_raises(Exception, /analytic_operation_post_plan_fk/) do
      EntrySpec.sql_transaction { |db| db.exec("UPDATE analytic_operation SET plan_id = $1", data[:project].id) }
    end
    expect_raises(Exception, /analytic_operation_amount_check/) do
      EntrySpec.sql_transaction { |db| db.exec("UPDATE analytic_operation SET amount = 0") }
    end
  end

  it "exige le droit d'écriture sur le journal et la permission de ventiler" do
    data = AnalyticSpec.setup
    entry = AnalyticSpec.expense("100")
    input = [Api::LineDistributionInput.new(entry.lines[0].id, [row("100", data[:sale])])]
    user_id, reader = AccountingSpec.user_actor("lecteur@example.test", "analytic.operation.write", "accounting.entry.read")
    Partiduo::Api::Auth.set_ledger_security(system, user_id, true).value!
    Partiduo::Api::Auth.set_ledger_access(system, user_id, EntrySpec.ledger("O01").id, "R").value!
    expect_raises(Partiduo::Api::Forbidden) { Api.distribute_entry(reader, entry.id, input) }
    expect_raises(Partiduo::Api::Forbidden) { Api.distribute_entry(actor_with("analytic.report.read"), entry.id, input) }
  end

  it "liste les lignes des comptes ventilés dont la ventilation manque" do
    data = AnalyticSpec.setup
    full = AnalyticSpec.expense("100", "2026-03-10")
    partial = AnalyticSpec.expense("90", "2026-03-11")
    AnalyticSpec.distribute(full, [row("100", data[:sale], data[:p1])]).value!
    AnalyticSpec.distribute(partial, [row("90", data[:sale])]).value!
    bare = AnalyticSpec.expense("40", "2026-03-12")
    lines = Api.undistributed_lines(system, EntrySpec.date("2026-03-01"), EntrySpec.date("2026-03-31"))
    lines.map { |line| {line.entry_id, line.account_number, line.missing_plan_ids} }.sort_by!(&.[0]).should eq([
      {partial.id, "603", [data[:project].id]},
      {bare.id, "603", [data[:activity].id, data[:project].id].sort},
    ])
  end
end

describe_module "ANALYTIC", "Analytique : opérations diverses" do
  it "enregistre une opération équilibrée dans chaque plan, avec fiche" do
    data = AnalyticSpec.setup
    customer = EntrySpec.card("CUSTOMER", "Client analytique")
    input = Api::MiscOperationInput.new(EntrySpec.date("2026-05-02"), " Transfert de coûts ", [
      misc_row("120", Acc::Side::Debit, data[:sale], data[:p1], card: customer.code),
      misc_row("120", Acc::Side::Credit, data[:workshop], data[:p2]),
    ])
    view = Api.create_misc_operation(system, input).value!
    view.misc?.should be_true
    view.description.should eq("Transfert de coûts")
    view.entry_id.should be_nil
    view.rows.map { |item| {item.side.code, item.posts.map(&.code), item.card_code} }
      .should eq([{"debit", ["VENTE", "P1"], customer.code}, {"credit", ["ATELIER", "P2"], nil}])
    Api.misc_operations(system, EntrySpec.date("2026-05-01"), EntrySpec.date("2026-05-31")).map(&.id).should eq([view.id])
    Api.misc_operations(system, EntrySpec.date("2026-06-01")).should be_empty
    Api.misc_operation(system, view.id).rows.size.should eq(2)

    updated = Api.update_misc_operation(system, view.id, input.copy_with(description: "Autre")).value!
    updated.id.should eq(view.id)
    updated.description.should eq("Autre")
    Api.delete_misc_operation(system, view.id).success?.should be_true
    expect_raises(Partiduo::Api::NotFound) { Api.misc_operation(system, view.id) }
  end

  it "refuse une opération déséquilibrée, sans description, hors période ou en période close" do
    data = AnalyticSpec.setup
    unbalanced = Api::MiscOperationInput.new(EntrySpec.date("2026-05-02"), "OD", [
      misc_row("100", Acc::Side::Debit, data[:sale], data[:p1]),
      misc_row("90", Acc::Side::Credit, data[:workshop], data[:p2]),
    ])
    result = Api.create_misc_operation(system, unbalanced)
    result.error_keys.should eq(["analytic.errors.misc.unbalanced", "analytic.errors.misc.unbalanced"])
    result.errors.first.params["difference"].should eq("10.00")

    Api.create_misc_operation(system, unbalanced.copy_with(description: " ", rows: [] of Api::MiscRowInput))
      .error_keys.should eq(["analytic.errors.misc.description_required", "analytic.errors.misc.rows_required"])
    Api.create_misc_operation(system, Api::MiscOperationInput.new(EntrySpec.date("2031-01-01"), "OD", [
      misc_row("10", Acc::Side::Debit, data[:sale]), misc_row("10", Acc::Side::Credit, data[:workshop]),
    ])).error_keys.should eq(["analytic.errors.misc.no_period"])
    Api.create_misc_operation(system, Api::MiscOperationInput.new(EntrySpec.date("2026-05-02"), "OD", [
      misc_row("10", Acc::Side::Debit, data[:sale], card: "INCONNU"), misc_row("10", Acc::Side::Credit, data[:workshop]),
    ])).error_keys.should eq(["analytic.errors.misc.card_unknown"])

    balanced = Api::MiscOperationInput.new(EntrySpec.date("2026-05-02"), "OD", [
      misc_row("10", Acc::Side::Debit, data[:sale]), misc_row("10", Acc::Side::Credit, data[:workshop]),
    ])
    view = Api.create_misc_operation(system, balanced).value!
    Partiduo::Api::Core.close_period(system, EntrySpec.period("2026-05-02").id).value!
    Api.create_misc_operation(system, balanced).error_keys.should eq(["analytic.errors.distribution.closed_period"])
    Api.delete_misc_operation(system, view.id).error_keys.should eq(["analytic.errors.distribution.closed_period"])
    Api.update_misc_operation(system, view.id, balanced).error_keys.should contain("analytic.errors.distribution.closed_period")
  end

  it "refuse toute ventilation sans plan analytique" do
    EntrySpec.setup
    entry = AnalyticSpec.expense("10")
    Api.distribute_entry(system, entry.id, [Api::LineDistributionInput.new(entry.lines[0].id,
      [Api::DistributionRowInput.new(d("10"), [1_i64])])]).error_keys.should eq(["analytic.errors.distribution.no_plan"])
  end
end
