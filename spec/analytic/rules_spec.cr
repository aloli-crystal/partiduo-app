# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Règles complémentaires de l'Analytique (lot 5, specs du testeur) : cas
# limites des plans, groupes, postes, paramètres et clés (`Anc_Plan`,
# `Anc_Group`, `Anc_Key::fill_table`, `check_anc_filter`), ventilation et
# opérations diverses (`Anc_Operation`, `Anc_Group_Operation`),
# permissions, module inactif et contraintes d'intégrité posées par la
# migration analytic 0001.

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

private def key_input(name : String, rows : Array({String, Array(Int64)}), ledgers : Array(Int64) = [] of Int64)
  Api::KeyInput.new(name, rows.map { |(percent, posts)| Api::KeyRowInput.new(d(percent), posts) }, "", ledgers)
end

private def balanced_misc(data, day : String = "2026-05-02") : Api::MiscOperationInput
  Api::MiscOperationInput.new(EntrySpec.date(day), "OD", [
    misc_row("10", Acc::Side::Debit, data[:sale]), misc_row("10", Acc::Side::Credit, data[:workshop]),
  ])
end

describe "Analytique : module inactif, tout le contrat (ADR-006 D2)" do
  it "refuse chaque famille de commandes et de requêtes par ModuleDisabled" do
    with_active_modules("accounting,invoicing") do
      query = Api::ReportQuery.new(1_i64)
      cross = Api::CrossBalanceQuery.new(1_i64, 2_i64)
      table = Api::TableQuery.new(1_i64)
      day = Time.utc(2026, 3, 1)
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.plan(system, 1_i64) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.check_plan(system, Api::PlanInput.new("X")) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.update_plan(system, 1_i64, Api::PlanInput.new("X")) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.delete_plan(system, 1_i64) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.groups(system) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.create_group(system, Api::GroupInput.new(1_i64, "G")) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.delete_group(system, 1_i64) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.post_by_code(system, 1_i64, "X") }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.create_post(system, Api::PostInput.new(1_i64, "X")) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.delete_post(system, 1_i64) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.update_settings(system, Api::SettingsInput.new(true, "6")) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.keys_for_ledger(system, 1_i64) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.create_key(system, key_input("K", [{"100", [1_i64]}])) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.apply_key(system, 1_i64, d("10")) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.entry_distributions(system, 1_i64) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.check_distribution(system, 1_i64, [] of Api::LineDistributionInput) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.undistributed_lines(system, day, day) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.distribution_required?(system) }
      expect_raises(Partiduo::Api::ModuleDisabled) do
        Api.post_entry(system, Acc::EntryInput.new(ledger_id: 1_i64, date: day, lines: [] of Acc::EntryLineInput),
          [] of Api::InputDistributionInput)
      end
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.misc_operations(system) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.delete_misc_operation(system, 1_i64) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.cross_balance(system, cross) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.group_balance(system, query) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.history(system, query) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.ledger(system, query) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.table(system, table) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.export_balance(system, query) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.export_table(system, table) }
    end
  end
end

describe_module "ANALYTIC", "Analytique : cas limites des plans, groupes et postes" do
  it "applique la normalisation de plan_analytic_ins_upd et les longueurs maximales" do
    plan = AnalyticSpec.plan("\tax e\n")
    plan.name.should eq("AXE")
    Api.create_plan(system, Api::PlanInput.new("A" * 101)).error_keys.should eq(["analytic.errors.plan.name_too_long"])
    Api.create_post(system, Api::PostInput.new(plan.id, "P" * 101)).error_keys
      .should eq(["analytic.errors.post.code_too_long"])
    Api.create_post(system, Api::PostInput.new(plan.id, "P" * 100)).success?.should be_true
    Api.create_group(system, Api::GroupInput.new(plan.id, " ")).error_keys.should eq(["analytic.errors.group.code_required"])
    Api.create_group(system, Api::GroupInput.new(plan.id, "a b c d e f g h i j")).value!.code.should eq("ABCDEFGHIJ")
    Api.create_post(system, Api::PostInput.new(0_i64, "X")).error_keys.should eq(["analytic.errors.plan.unknown"])
    Api.create_post(system, Api::PostInput.new(plan.id, "Y", group_id: 999_999_i64)).error_keys
      .should eq(["analytic.errors.group.unknown"])
  end

  it "renomme un plan sans se heurter à lui-même ni à la limite de dix plans" do
    plans = (1..10).map { |index| AnalyticSpec.plan("Axe #{index}") }
    Api.update_plan(system, plans.first.id, Api::PlanInput.new("axe1", "Même nom")).value!.name.should eq("AXE1")
    Api.check_plan(system, Api::PlanInput.new("Axe 1"), plans.first.id).success?.should be_true
    Api.update_plan(system, plans.first.id, Api::PlanInput.new("Axe 2")).error_keys
      .should eq(["analytic.errors.plan.name_taken"])
    Api.delete_plan(system, plans.last.id).success?.should be_true
    Api.create_plan(system, Api::PlanInput.new("Nouveau")).success?.should be_true
    Api.plan(system, plans.first.id).posts_count.should eq(0)
  end

  it "garde le plan d'un groupe à la modification et refuse un code déjà pris" do
    plan = AnalyticSpec.plan("AXE")
    other = AnalyticSpec.plan("AUTRE")
    g1 = Api.create_group(system, Api::GroupInput.new(plan.id, "G1")).value!
    Api.create_group(system, Api::GroupInput.new(plan.id, "G2")).value!
    moved = Api.update_group(system, g1.id, Api::GroupInput.new(other.id, "G3", "Renommé")).value!
    moved.plan_id.should eq(plan.id)
    moved.code.should eq("G3")
    Api.update_group(system, g1.id, Api::GroupInput.new(plan.id, "g2")).error_keys
      .should eq(["analytic.errors.group.code_taken"])
    AnalyticSpec.post(plan, "P", group_id: g1.id)
    Api.group(system, g1.id).posts_count.should eq(1)
    Api.plan(system, plan.id).groups_count.should eq(2)
  end

  it "lève NotFound pour un groupe, un poste, une clé ou une opération diverse inconnus" do
    expect_raises(Partiduo::Api::NotFound) { Api.group(system, 999_999_i64) }
    expect_raises(Partiduo::Api::NotFound) { Api.post(system, 999_999_i64) }
    expect_raises(Partiduo::Api::NotFound) { Api.key(system, 999_999_i64) }
    expect_raises(Partiduo::Api::NotFound) { Api.delete_key(system, 999_999_i64) }
    expect_raises(Partiduo::Api::NotFound) { Api.misc_operation(system, 999_999_i64) }
    expect_raises(Partiduo::Api::NotFound) { Api.update_post(system, 999_999_i64, Api::PostInput.new(1_i64, "X")) }
  end

  it "retire les opérations d'un poste supprimé en période ouverte, et sa ligne de clé" do
    data = AnalyticSpec.setup
    entry = AnalyticSpec.expense("100")
    AnalyticSpec.distribute(entry, [AnalyticSpec.row("100", data[:sale], data[:p1])]).value!
    key = Api.create_key(system, key_input("K", [{"100", [data[:sale].id, data[:p1].id]}])).value!
    Api.delete_post(system, data[:sale].id).success?.should be_true
    Partiduo::Analytic::Operation.all.count.should eq(1)
    Api.key(system, key.id).rows.first.posts.map(&.code).should eq(["P1"])
    Api.posts(system, data[:activity].id).map(&.code).should eq(["ATELIER"])
  end
end

describe_module "ANALYTIC", "Analytique : paramètres (check_anc_filter)" do
  it "refuse un préfixe qui n'est pas fait de chiffres seulement" do
    AnalyticSpec.setup
    Api.update_settings(system, Api::SettingsInput.new(false, "6 0,7")).error_keys
      .should eq(["analytic.errors.settings.filter_invalid"])
    Api.update_settings(system, Api::SettingsInput.new(false, "6;7")).error_keys
      .should eq(["analytic.errors.settings.filter_invalid"])
    Api.update_settings(system, Api::SettingsInput.new(false, "60,60, 7")).value!.account_filter.should eq("60,7")
    Api.settings(system).prefixes.should eq(["60", "7"])
  end

  it "ne ventile plus une ligne dont le compte sort du filtre" do
    data = AnalyticSpec.setup
    Api.update_settings(system, Api::SettingsInput.new(false, "7")).value!
    entry = AnalyticSpec.expense("100")
    AnalyticSpec.distribute(entry, [row("100", data[:sale])]).error_keys
      .should eq(["analytic.errors.distribution.account_not_analytic"])
    AnalyticSpec.distribute(entry, [] of Api::DistributionRowInput).success?.should be_true
  end
end

describe_module "ANALYTIC", "Analytique : clés de répartition, cas limites" do
  it "ne produit jamais de montant négatif en répartissant quelques centimes" do
    data = AnalyticSpec.setup
    quarters = [data[:sale], data[:workshop], data[:p1], data[:p2]].map { |post| {"25", [post.id]} }
    key = Api.create_key(system, key_input("Quarts", quarters)).value!
    {"0.02", "0.03", "0.05", "1", "0.01"}.each do |amount|
      rows = Api.apply_key(system, key.id, d(amount))
      rows.all? { |item| item.amount > 0 }.should be_true
      rows.sum(BigDecimal.new(0), &.amount).should eq(d(amount))
    end
    Api.apply_key(system, key.id, d("100")).map(&.amount).should eq([d("25"), d("25"), d("25"), d("25")])
    Api.apply_key(system, key.id, d("0")).should be_empty
  end

  it "refuse un pourcentage hors bornes ou trop précis, un poste inconnu" do
    data = AnalyticSpec.setup
    sale = data[:sale].id
    Api.create_key(system, key_input("K", [{"150", [sale]}, {"-50", [data[:p1].id]}])).error_keys
      .should eq(["analytic.errors.key.percent_invalid", "analytic.errors.key.percent_invalid"])
    Api.create_key(system, key_input("K", [{"99.99999", [sale]}, {"0.00001", [data[:p1].id]}])).error_keys
      .should eq(["analytic.errors.key.percent_scale", "analytic.errors.key.percent_scale"])
    Api.create_key(system, key_input("K", [{"100", [999_999_i64]}])).error_keys.should eq(["analytic.errors.post.unknown"])
    Api.create_key(system, key_input("K" * 101, [{"100", [sale]}])).error_keys.should eq(["analytic.errors.key.name_too_long"])
    ledger = EntrySpec.ledger("A01").id
    Api.create_key(system, key_input("K", [{"100", [sale]}], [ledger, ledger])).value!.ledger_ids.should eq([ledger])
  end

  it "exige analytic.plan.write pour modifier une clé, analytic.plan.read pour la lire" do
    data = AnalyticSpec.setup
    key = Api.create_key(system, key_input("K", [{"100", [data[:sale].id]}])).value!
    reader = actor_with("analytic.plan.read")
    Api.keys(reader).size.should eq(1)
    Api.apply_key(reader, key.id, d("10")).size.should eq(1)
    expect_raises(Partiduo::Api::Forbidden) { Api.delete_key(reader, key.id) }
    expect_raises(Partiduo::Api::Forbidden) { Api.check_key(reader, key_input("K", [{"100", [data[:sale].id]}])) }
    expect_raises(Partiduo::Api::Forbidden) { Api.keys(actor_with("analytic.operation.write")) }
  end

  it "suit un journal supprimé : la clé n'y est plus proposée (cascade en base)" do
    data = AnalyticSpec.setup
    ledger = AccountingSpec.create_ledger("Achats analytiques")
    key = Api.create_key(system, key_input("K", [{"100", [data[:sale].id]}], [ledger.id])).value!
    Api.keys_for_ledger(system, ledger.id).map(&.id).should eq([key.id])
    EntrySpec.sql("DELETE FROM accounting_ledger WHERE id = $1", ledger.id)
    Api.key(system, key.id).ledger_ids.should be_empty
  end
end

describe_module "ANALYTIC", "Analytique : ventilation, cas limites" do
  it "accepte une ventilation partielle en mode facultatif, refuse une ligne citée deux fois" do
    data = AnalyticSpec.setup
    entry = AnalyticSpec.expense("100")
    view = AnalyticSpec.distribute(entry, [row("30.1234", data[:sale])]).value!.first
    view.total_for(data[:activity].id).should eq(d("30.1234"))
    view.total_for(data[:project].id).should eq(d("0"))
    line = entry.lines[0].id
    twice = Api.distribute_entry(system, entry.id, [
      Api::LineDistributionInput.new(line, [row("10", data[:sale])]),
      Api::LineDistributionInput.new(line, [row("10", data[:workshop])]),
    ])
    twice.error_keys.should eq(["analytic.errors.distribution.line_twice"])
    twice.errors.first.field.should eq("lines[1].line_id")
    AnalyticSpec.distribute(entry, [Api::DistributionRowInput.new(d("5"), [999_999_i64])]).error_keys
      .should eq(["analytic.errors.post.unknown"])
    Api.entry_distributions(system, entry.id).first.rows.first.amount.should eq(d("30.1234"))
  end

  it "ventile une ligne au crédit (vente) : les opérations portent le sens de la ligne" do
    data = AnalyticSpec.setup
    entry = EntrySpec.post_misc([EntrySpec.debit("410", "80"), EntrySpec.credit("706", "80")])
    view = AnalyticSpec.distribute(entry, [row("80", data[:sale], data[:p2])], position: 1).value!.first
    view.rows.first.side.code.should eq("credit")
    balance = Api.balance(system, Api::ReportQuery.new(data[:project].id))
    balance.rows.map { |item| {item.post.code, item.amounts.credit, item.amounts.side.try(&.code)} }
      .should eq([{"P2", d("80"), "credit"}])
  end

  it "rouvre la ventilation quand la période close est rouverte" do
    data = AnalyticSpec.setup
    entry = AnalyticSpec.expense("100")
    period = EntrySpec.period("2026-03-15")
    Partiduo::Api::Core.close_period(system, period.id).value!
    AnalyticSpec.distribute(entry, [row("100", data[:sale])]).error_keys
      .should eq(["analytic.errors.distribution.closed_period"])
    Partiduo::Api::Core.reopen_period(system, period.id).value!
    AnalyticSpec.distribute(entry, [row("100", data[:sale])]).success?.should be_true
  end

  it "fige aussi une imputation dont l'exercice est clos" do
    data = AnalyticSpec.setup
    entry = AnalyticSpec.expense("100")
    AnalyticSpec.distribute(entry, [row("100", data[:sale])]).value!
    Api.create_misc_operation(system, balanced_misc(data)).value!
    Partiduo::Api::Core.close_fiscal_year(system, EntrySpec.period("2026-03-15").fiscal_year_id).value!
    AnalyticSpec.distribute(entry, [row("100", data[:workshop])]).error_keys
      .should eq(["analytic.errors.distribution.closed_period"])
    Api.delete_post(system, data[:sale].id).error_keys.should eq(["analytic.errors.post.closed_period"])
    expect_raises(Exception, /période close/) do
      EntrySpec.sql_transaction { |db| db.exec("DELETE FROM analytic_distribution") }
    end
    Partiduo::Analytic::Distribution.all.count.should eq(2)
  end

  it "n'exige rien d'une écriture non ventilable, même en mode obligatoire" do
    AnalyticSpec.setup
    AnalyticSpec.mandatory!("6")
    input = EntrySpec.misc_input([EntrySpec.debit("410", "50"), EntrySpec.credit("706", "50")])
    entry = Api.post_entry(system, input, [] of Api::InputDistributionInput).value!
    Api.entry_distributions(system, entry.id).should be_empty
    Api.undistributed_lines(system, EntrySpec.date("2026-01-01"), EntrySpec.date("2026-12-31")).should be_empty
  end

  it "laisse passer l'écriture en mode facultatif et la signale ensuite comme à ventiler" do
    data = AnalyticSpec.setup
    input = EntrySpec.misc_input([EntrySpec.debit("603", "70"), EntrySpec.credit("400", "70")])
    entry = Api.post_entry(system, input, [] of Api::InputDistributionInput).value!
    lines = Api.undistributed_lines(system, EntrySpec.date("2026-03-01"), EntrySpec.date("2026-03-31"))
    lines.map { |line| {line.entry_id, line.position, line.amount} }.should eq([{entry.id, 0, d("70")}])
    Api.undistributed_lines(system, EntrySpec.date("2026-04-01"), EntrySpec.date("2026-04-30")).should be_empty
    AnalyticSpec.distribute(entry, [row("70", data[:sale], data[:p1])]).value!
    Api.undistributed_lines(system, EntrySpec.date("2026-03-01"), EntrySpec.date("2026-03-31")).should be_empty
  end

  it "enregistre une facture de vente ventilée (post_sale), rien si la ventilation dépasse" do
    data = AnalyticSpec.setup
    customer = EntrySpec.card("CUSTOMER", "Client ventilé")
    input = EntrySpec.document("V01", customer.code, [EntrySpec.item("200", account: "706")])
    draft = Acc.check_document(system, input).value!
    position = draft.lines.index! { |line| line.account_number == "706" }
    too_much = Api.post_sale(system, input, [Api::InputDistributionInput.new(position, [row("250", data[:sale])])])
    too_much.error_keys.should eq(["analytic.errors.distribution.exceeds"])
    too_much.errors.first.field.should eq("distributions[0]")
    Acc.entries(system).should be_empty
    entry = Api.post_sale(system, input, [Api::InputDistributionInput.new(position, [row("200", data[:sale])])]).value!
    Api.entry_distributions(system, entry.id).first.rows.first.side.code.should eq("credit")
  end

  it "exige analytic.operation.write pour enregistrer une écriture ventilée" do
    AnalyticSpec.setup
    input = EntrySpec.misc_input([EntrySpec.debit("603", "10"), EntrySpec.credit("400", "10")])
    expect_raises(Partiduo::Api::Forbidden) do
      Api.post_entry(actor_with("accounting.entry.post", "accounting.entry.read"), input, [] of Api::InputDistributionInput)
    end
    Acc.entries(system).should be_empty
  end

  it "n'ouvre la ventilation d'une écriture qu'aux acteurs qui la voient" do
    data = AnalyticSpec.setup
    entry = AnalyticSpec.expense("100")
    AnalyticSpec.distribute(entry, [row("100", data[:sale])]).value!
    user_id, actor = AccountingSpec.user_actor("aveugle@example.test", "analytic.report.read", "accounting.entry.read")
    Partiduo::Api::Auth.set_ledger_security(system, user_id, true).value!
    Partiduo::Api::Auth.set_ledger_access(system, user_id, EntrySpec.ledger("A01").id, "R").value!
    expect_raises(Partiduo::Api::NotFound) { Api.entry_distributions(actor, entry.id) }
    expect_raises(Partiduo::Api::Forbidden) { Api.entry_distributions(actor_with("accounting.entry.read"), entry.id) }
  end

  it "ne reporte rien sur l'extourne d'une écriture non ventilée" do
    AnalyticSpec.setup
    entry = AnalyticSpec.expense("40")
    reversal = Acc.cancel_entry(system, Acc::CancelEntryInput.new(entry.id, EntrySpec.date("2026-04-02"))).value!
    Api.entry_distributions(system, reversal.id).should be_empty
    Partiduo::Analytic::Distribution.all.count.should eq(0)
  end
end

describe_module "ANALYTIC", "Analytique : opérations diverses, cas limites" do
  it "exige l'équilibre plan par plan, pas globalement" do
    data = AnalyticSpec.setup
    input = Api::MiscOperationInput.new(EntrySpec.date("2026-05-02"), "OD", [
      misc_row("50", Acc::Side::Debit, data[:sale], data[:p1]),
      misc_row("50", Acc::Side::Credit, data[:workshop]),
    ])
    result = Api.create_misc_operation(system, input)
    result.error_keys.should eq(["analytic.errors.misc.unbalanced"])
    result.errors.first.params["plan"].should eq("PROJET")
  end

  it "refuse un poste inactif, sauf s'il figurait déjà dans l'opération modifiée" do
    data = AnalyticSpec.setup
    view = Api.create_misc_operation(system, balanced_misc(data)).value!
    Api.update_post(system, data[:sale].id, Api::PostInput.new(data[:activity].id, "VENTE", active: false)).value!
    Api.create_misc_operation(system, balanced_misc(data)).error_keys.should eq(["analytic.errors.distribution.post_inactive"])
    Api.update_misc_operation(system, view.id, balanced_misc(data).copy_with(description: "Modifiée")).success?.should be_true
  end

  it "refuse de déplacer une opération dans une période close" do
    data = AnalyticSpec.setup
    view = Api.create_misc_operation(system, balanced_misc(data, "2026-05-02")).value!
    Partiduo::Api::Core.close_period(system, EntrySpec.period("2026-03-15").id).value!
    Api.update_misc_operation(system, view.id, balanced_misc(data, "2026-03-15")).error_keys
      .should eq(["analytic.errors.distribution.closed_period"])
    Api.misc_operation(system, view.id).date.should eq(EntrySpec.date("2026-05-02"))
  end

  it "exige analytic.operation.write pour écrire, analytic.report.read pour lire" do
    data = AnalyticSpec.setup
    view = Api.create_misc_operation(system, balanced_misc(data)).value!
    reader = actor_with("analytic.report.read")
    Api.misc_operations(reader).map(&.id).should eq([view.id])
    expect_raises(Partiduo::Api::Forbidden) { Api.create_misc_operation(reader, balanced_misc(data)) }
    expect_raises(Partiduo::Api::Forbidden) { Api.delete_misc_operation(reader, view.id) }
    expect_raises(Partiduo::Api::Forbidden) { Api.misc_operations(actor_with("analytic.operation.write")) }
  end

  it "ne confond pas une opération diverse avec la ventilation d'une écriture" do
    data = AnalyticSpec.setup
    entry = AnalyticSpec.expense("100")
    distribution = AnalyticSpec.distribute(entry, [row("100", data[:sale])]).value!.first
    expect_raises(Partiduo::Api::NotFound) { Api.misc_operation(system, distribution.id) }
    expect_raises(Partiduo::Api::NotFound) { Api.delete_misc_operation(system, distribution.id) }
  end
end

describe_module "ANALYTIC", "Analytique : éditions, cas limites" do
  it "rend des éditions vides sans imputation, et un historique paginé borné" do
    data = AnalyticSpec.setup
    query = Api::ReportQuery.new(data[:activity].id)
    Api.balance(system, query).rows.should be_empty
    Api.balance(system, query).total.should eq(Api::Amounts.zero)
    Api.group_balance(system, query).sections.should be_empty
    Api.ledger(system, query).sections.should be_empty
    Api.table(system, Api::TableQuery.new(data[:activity].id)).rows.should be_empty
    Api.cross_balance(system, Api::CrossBalanceQuery.new(data[:activity].id, data[:project].id)).rows.should be_empty

    entry = AnalyticSpec.expense("100")
    AnalyticSpec.distribute(entry, [row("100", data[:sale])]).value!
    Api.history(system, query, offset: 50).operations.should be_empty
    Api.history(system, query, offset: -3).operations.size.should eq(1)
    Api.history(system, query, limit: 0).count.should eq(1)
    Api.cross_balance(system, Api::CrossBalanceQuery.new(data[:activity].id, data[:project].id)).rows.should be_empty
  end

  it "donne un solde sans sens à un poste soldé" do
    data = AnalyticSpec.setup
    Api.create_misc_operation(system, Api::MiscOperationInput.new(EntrySpec.date("2026-05-02"), "OD", [
      misc_row("10", Acc::Side::Debit, data[:sale]), misc_row("10", Acc::Side::Credit, data[:sale]),
    ])).value!
    view = Api.balance(system, Api::ReportQuery.new(data[:activity].id))
    view.rows.first.amounts.balance.should eq(d("0"))
    view.rows.first.amounts.side.should be_nil
  end

  it "protège les cellules de texte des formules dans les exports" do
    data = AnalyticSpec.setup
    Api.create_misc_operation(system, balanced_misc(data).copy_with(description: "=SOMME(A1)")).value!
    content = String.new(Api.export_history(system, Api::ReportQuery.new(data[:activity].id)).content)
    content.should contain("'=SOMME(A1)")
  end
end

describe_module "ANALYTIC", "Analytique : intégrité en base (migration analytic 0001)" do
  it "accorde analytic.operation.write au profil ACCOUNTANT" do
    Partiduo::Api::Auth.ensure_default_profiles(system)
    count = EntrySpec.scalar(<<-SQL).as(Int64)
      SELECT count(*) FROM auth_profile_permission pp JOIN auth_profile p ON p.id = pp.profile_id
      WHERE p.code = 'ACCOUNTANT' AND pp.permission = 'analytic.operation.write'
      SQL
    count.should eq(1)
  end

  it "refuse en base les noms à espace, les doublons de code et les pourcentages hors bornes" do
    data = AnalyticSpec.setup
    expect_raises(Exception, /analytic_plan_name_check/) do
      EntrySpec.sql_transaction { |db| db.exec("INSERT INTO analytic_plan (name, description, created_at, updated_at) VALUES ('A B', '', now(), now())") }
    end
    expect_raises(Exception, /analytic_post_plan_code/) do
      EntrySpec.sql_transaction do |db|
        db.exec("INSERT INTO analytic_post (plan_id, code, description, active) VALUES ($1, 'VENTE', '', true)",
          data[:activity].id)
      end
    end
    key = Api.create_key(system, key_input("K", [{"100", [data[:sale].id]}])).value!
    expect_raises(Exception, /analytic_key_row_percent_check/) do
      EntrySpec.sql_transaction { |db| db.exec("UPDATE analytic_key_row SET percent = 101 WHERE key_id = $1", key.id) }
    end
    expect_raises(Exception, /analytic_key_row_post_plan_fk/) do
      EntrySpec.sql_transaction { |db| db.exec("UPDATE analytic_key_row_post SET plan_id = $1", data[:project].id) }
    end
  end

  it "garde une ventilation par ligne et protège la ligne ventilée" do
    data = AnalyticSpec.setup
    entry = AnalyticSpec.expense("100")
    AnalyticSpec.distribute(entry, [row("100", data[:sale])]).value!
    expect_raises(Exception, /entry_line_id|unique/i) do
      EntrySpec.sql_transaction do |db|
        db.exec(<<-SQL, entry.id, entry.lines[0].id, entry.ledger_id)
          INSERT INTO analytic_distribution (kind, entry_id, entry_line_id, ledger_id, date, created_at, updated_at)
          VALUES ('entry', $1, $2, $3, '2026-03-15', now(), now())
          SQL
      end
    end
    expect_raises(Exception, /analytic_distribution_kind_check/) do
      EntrySpec.sql_transaction { |db| db.exec("UPDATE analytic_distribution SET kind = 'misc'") }
    end
    expect_raises(Exception, /analytic_operation_side_check/) do
      EntrySpec.sql_transaction { |db| db.exec("UPDATE analytic_operation SET side = 'both'") }
    end
    expect_raises(Exception, /analytic_operation_row_plan/) do
      EntrySpec.sql_transaction do |db|
        db.exec(<<-SQL, data[:workshop].id, data[:activity].id)
          INSERT INTO analytic_operation (distribution_id, row, plan_id, post_id, amount, side, card_code)
          SELECT distribution_id, row, $2, $1, 1, 'debit', '' FROM analytic_operation
          SQL
      end
    end
    expect_raises(Exception, /analytic_distribution_line_fk/) do
      EntrySpec.sql_transaction { |db| db.exec("DELETE FROM accounting_entry_line WHERE id = $1", entry.lines[0].id) }
    end
    Api.entry_distributions(system, entry.id).size.should eq(1)
  end
end
