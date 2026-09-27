# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Éditions analytiques : balance simple (`Anc_Balance_Simple`), croisée
# (`Anc_Balance_Double`), par groupe (`Anc_Group`), historique
# (`Anc_Listing`), grand livre (`Anc_GrandLivre`), tableau (`Anc_Table`,
# `Anc_Acc_List`) et leurs exports CSV.

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

# Jeu commun : trois écritures ventilées et une opération diverse.
#
# | imputation              | ACTIVITÉ          | PROJET |
# | 606 D 1000 (10/03, O01) | VENTE 600, ATELIER 400 | P1 600, P2 400 |
# | 706 C 500 (20/03, O01)  | VENTE 500         | P1 500 |
# | 613 D 200 (05/04, A01)  | ATELIER 200       | —      |
# | OD 02/05                | VENTE D 100, ATELIER C 100 | P2 D 100, P1 C 100 |
private def scenario
  data = AnalyticSpec.setup
  group = Api.create_group(system, Api::GroupInput.new(data[:activity].id, "G1", "Commercial")).value!
  Api.update_post(system, data[:sale].id, Api::PostInput.new(data[:activity].id, "VENTE", "Ventes", group.id)).value!
  customer = EntrySpec.card("CUSTOMER", "Client analytique")
  e1 = AnalyticSpec.expense("1000", "2026-03-10")
  AnalyticSpec.distribute(e1, [row("600", data[:sale], data[:p1]), row("400", data[:workshop], data[:p2])]).value!
  e2 = EntrySpec.post_misc([EntrySpec.debit("410", "500"), EntrySpec.credit("706", "500")], "2026-03-20")
  AnalyticSpec.distribute(e2, [row("500", data[:sale], data[:p1])], position: 1).value!
  e3 = EntrySpec.post_misc([EntrySpec.debit("681", "200"), EntrySpec.credit("400", "200")], "2026-04-05", ledger: "A01")
  AnalyticSpec.distribute(e3, [row("200", data[:workshop])]).value!
  Api.create_misc_operation(system, Api::MiscOperationInput.new(EntrySpec.date("2026-05-02"), "Transfert", [
    Api::MiscRowInput.new(d("100"), Acc::Side::Debit, [data[:sale].id, data[:p2].id], customer.code),
    Api::MiscRowInput.new(d("100"), Acc::Side::Credit, [data[:workshop].id, data[:p1].id]),
  ])).value!
  {data: data, customer: customer}
end

describe_module "ANALYTIC", "Analytique : éditions" do
  it "établit la balance simple d'un plan, filtrée par dates et par postes" do
    s = scenario
    plan = s[:data][:activity]
    view = Api.balance(system, Api::ReportQuery.new(plan.id))
    view.plan.name.should eq("ACTIVITÉ")
    view.partial.should be_false
    view.rows.map { |item| {item.post.code, item.group_code, item.amounts.debit, item.amounts.credit, item.amounts.balance, item.amounts.side.try(&.code)} }
      .should eq([
        {"ATELIER", nil, d("600"), d("100"), d("500"), "debit"},
        {"VENTE", "G1", d("700"), d("500"), d("200"), "debit"},
      ])
    view.total.should eq(Api::Amounts.new(d("1300"), d("600")))

    march = Api.balance(system, Api::ReportQuery.new(plan.id, EntrySpec.date("2026-03-01"), EntrySpec.date("2026-03-31")))
    march.rows.map { |item| {item.post.code, item.amounts.signed} }.should eq([{"ATELIER", d("400")}, {"VENTE", d("100")}])
    Api.balance(system, Api::ReportQuery.new(plan.id, post_from: "b")).rows.map(&.post.code).should eq(["VENTE"])
    Api.balance(system, Api::ReportQuery.new(plan.id, post_to: "atelier")).rows.map(&.post.code).should eq(["ATELIER"])
    expect_raises(Partiduo::Api::NotFound) { Api.balance(system, Api::ReportQuery.new(0_i64)) }
  end

  it "croise deux plans ligne à ligne (balance double)" do
    s = scenario
    view = Api.cross_balance(system, Api::CrossBalanceQuery.new(s[:data][:activity].id, s[:data][:project].id))
    view.rows.map { |item| {item.post.code, item.other_post.code, item.amounts.debit, item.amounts.credit} }
      .should eq([
        {"ATELIER", "P1", d("0"), d("100")},
        {"ATELIER", "P2", d("400"), d("0")},
        {"VENTE", "P1", d("600"), d("500")},
        {"VENTE", "P2", d("100"), d("0")},
      ])
    view.subtotals.map { |item| {item.post.code, item.amounts.debit, item.amounts.credit} }
      .should eq([{"ATELIER", d("400"), d("100")}, {"VENTE", d("700"), d("500")}])
    view.total.should eq(Api::Amounts.new(d("1100"), d("600")))
    only_p2 = Api.cross_balance(system, Api::CrossBalanceQuery.new(s[:data][:activity].id, s[:data][:project].id,
      other_post_from: "P2"))
    only_p2.rows.map(&.other_post.code).uniq!.should eq(["P2"])
  end

  it "range la balance par groupe, postes sans groupe en dernier" do
    s = scenario
    view = Api.group_balance(system, Api::ReportQuery.new(s[:data][:activity].id))
    view.sections.map { |section| {section.group_code, section.rows.map(&.post.code), section.total.signed} }
      .should eq([{"G1", ["VENTE"], d("200")}, {nil, ["ATELIER"], d("500")}])
    view.total.signed.should eq(d("700"))
  end

  it "liste l'historique par date et le grand livre par poste avec solde progressif" do
    s = scenario
    query = Api::ReportQuery.new(s[:data][:activity].id)
    history = Api.history(system, query)
    history.count.should eq(6)
    history.operations.map { |op| {op.date.to_s("%m-%d"), op.post.code, op.debit, op.credit} }.should eq([
      {"03-10", "VENTE", d("600"), d("0")},
      {"03-10", "ATELIER", d("400"), d("0")},
      {"03-20", "VENTE", d("0"), d("500")},
      {"04-05", "ATELIER", d("200"), d("0")},
      {"05-02", "VENTE", d("100"), d("0")},
      {"05-02", "ATELIER", d("0"), d("100")},
    ])
    history.operations.first.account_number.should eq("603")
    history.operations[3].ledger_code.should eq("A01")
    history.operations[4].kind.should eq("misc")
    history.operations[4].card_code.should eq(s[:customer].code)
    page = Api.history(system, query, offset: 4, limit: 10)
    page.operations.size.should eq(2)
    page.count.should eq(6)
    page.total.should eq(Api::Amounts.new(d("1300"), d("600")))

    ledger = Api.ledger(system, query)
    ledger.sections.map { |section| {section.post.code, section.lines.map(&.running)} }.should eq([
      {"ATELIER", [d("400"), d("600"), d("500")]},
      {"VENTE", [d("600"), d("100"), d("200")]},
    ])
    ledger.total.signed.should eq(d("700"))
  end

  it "croise postes et comptes généraux ou fiches (crédit − débit)" do
    s = scenario
    plan = s[:data][:activity]
    sale, workshop = s[:data][:sale].id, s[:data][:workshop].id
    customer_account = EntrySpec.card_account(s[:customer])
    view = Api.table(system, Api::TableQuery.new(plan.id))
    view.posts.map(&.code).should eq(["ATELIER", "VENTE"])
    view.rows.map { |item| {item.key, item.amounts} }.should eq([
      {"", {workshop => d("100")}},
      {customer_account, {sale => d("-100")}},
      {"603", {sale => d("-600"), workshop => d("-400")}},
      {"681", {workshop => d("-200")}},
      {"706", {sale => d("500")}},
    ].sort_by(&.[0]))
    view.column_totals.should eq({workshop => d("-500"), sale => d("-200")})
    view.total.should eq(d("-700"))

    cards = Api.table(system, Api::TableQuery.new(plan.id, Api::TableAxis::Card))
    found = cards.rows.find! { |item| item.key == s[:customer].code }
    found.label.should eq("Client analytique")
    found.amounts.should eq({sale => d("-100")})
  end

  it "écarte les imputations des journaux que l'acteur ne voit pas" do
    s = scenario
    user_id, actor = AccountingSpec.user_actor("analyste@example.test", "analytic.report.read")
    Partiduo::Api::Auth.set_ledger_security(system, user_id, true).value!
    Partiduo::Api::Auth.set_ledger_access(system, user_id, EntrySpec.ledger("O01").id, "R").value!
    view = Api.balance(actor, Api::ReportQuery.new(s[:data][:activity].id))
    view.partial.should be_true
    view.rows.map { |item| {item.post.code, item.amounts.signed} }.should eq([{"ATELIER", d("300")}, {"VENTE", d("200")}])
    expect_raises(Partiduo::Api::Forbidden) { Api.balance(actor_with("analytic.plan.read"), Api::ReportQuery.new(1_i64)) }
  end

  it "exporte chaque édition en CSV" do
    s = scenario
    plan = s[:data][:activity].id
    file = Api.export_balance(system, Api::ReportQuery.new(plan))
    file.filename.should eq("anc-balance-activite.csv")
    file.content_type.should eq("text/csv; charset=utf-8")
    lines = String.new(file.content).lines
    lines.first.should eq("Poste;Description;Groupe;Débit;Crédit;Solde;Sens")
    lines[1].should eq("ATELIER;Atelier;;600.00;100.00;500.00;Débit")
    lines.last.should eq("Total;;;1300.00;600.00;700.00;Débit")

    String.new(Api.export_history(system, Api::ReportQuery.new(plan)).content).lines.size.should eq(7)
    String.new(Api.export_ledger(system, Api::ReportQuery.new(plan)).content).lines[1].should end_with(";400.00;0.00;400.00")
    String.new(Api.export_group_balance(system, Api::ReportQuery.new(plan)).content).lines.size.should eq(3)
    String.new(Api.export_cross_balance(system,
      Api::CrossBalanceQuery.new(plan, s[:data][:project].id)).content).lines.size.should eq(5)
    table = String.new(Api.export_table(system, Api::TableQuery.new(plan)).content).lines
    table.first.should eq("Compte;Libellé;ATELIER;VENTE;Total")
    table.last.should eq("Total;;-500.00;-200.00;-700.00")
  end
end
