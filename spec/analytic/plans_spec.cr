# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Plans, groupes, postes et paramètres (`Anc_Plan`, `Anc_Group`,
# `Anc_Account_Table`, `anc_groupTest.php`, déclencheurs
# `plan_analytic_ins_upd`, `poste_analytique_ins_upd`).

private alias Api = Partiduo::Api::Analytic

private def system
  Partiduo::Api::Actor.system
end

describe "Analytique : module inactif (ADR-006 D2)" do
  it "refuse commandes et requêtes par ModuleDisabled" do
    with_active_modules("invoicing") do
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.plans(system) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.create_plan(system, Api::PlanInput.new("AXE")) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.posts(system) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.keys(system) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.settings(system) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.balance(system, Api::ReportQuery.new(1_i64)) }
      expect_raises(Partiduo::Api::ModuleDisabled) do
        Api.distribute_entry(system, 1_i64, [] of Api::LineDistributionInput)
      end
      expect_raises(Partiduo::Api::ModuleDisabled) do
        Api.create_misc_operation(system, Api::MiscOperationInput.new(Time.utc, "OD", [] of Api::MiscRowInput))
      end
    end
  end

  it "est inactive avec la Comptabilité seule" do
    with_active_modules("accounting") do
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.plans(system) }
    end
  end
end

describe_module "ANALYTIC", "Analytique : plans, groupes, postes" do
  it "normalise le nom d'un plan, refuse un doublon, un nom vide et un onzième plan" do
    plan = AnalyticSpec.plan("  Axe principal ", "Description")
    plan.name.should eq("AXEPRINCIPAL")
    plan.description.should eq("Description")

    Api.create_plan(system, Api::PlanInput.new("axe Principal")).error_keys.should eq(["analytic.errors.plan.name_taken"])
    Api.create_plan(system, Api::PlanInput.new("  ")).error_keys.should eq(["analytic.errors.plan.name_required"])

    2.upto(10) { |index| AnalyticSpec.plan("Axe #{index}") }
    Api.plans(system).size.should eq(10)
    result = Api.create_plan(system, Api::PlanInput.new("Onze"))
    result.error_keys.should eq(["analytic.errors.plan.limit"])
    result.errors.first.params.should eq({"max" => "10"})
    Api.check_plan(system, Api::PlanInput.new("Onze")).failure?.should be_true

    updated = Api.update_plan(system, plan.id, Api::PlanInput.new("Axe 1", "Nouvelle")).value!
    updated.name.should eq("AXE1")
    Api.plan(system, plan.id).description.should eq("Nouvelle")
  end

  it "gère les groupes d'un plan (insert, load, remove de anc_groupTest)" do
    plan = AnalyticSpec.plan("AXE2")
    other = AnalyticSpec.plan("AXE3")
    group = Api.create_group(system, Api::GroupInput.new(plan.id, "g 1", "Group 1")).value!
    group.code.should eq("G1")
    Api.groups(system, plan.id).map(&.code).should eq(["G1"])
    Api.group(system, group.id).description.should eq("Group 1")

    Api.create_group(system, Api::GroupInput.new(plan.id, "G1")).error_keys.should eq(["analytic.errors.group.code_taken"])
    Api.create_group(system, Api::GroupInput.new(other.id, "G1")).success?.should be_true
    Api.create_group(system, Api::GroupInput.new(plan.id, "ABCDEFGHIJK")).error_keys
      .should eq(["analytic.errors.group.code_too_long"])
    Api.create_group(system, Api::GroupInput.new(0_i64, "X")).error_keys.should eq(["analytic.errors.plan.unknown"])

    post = AnalyticSpec.post(plan, "p", group_id: group.id)
    post.group_code.should eq("G1")
    Api.delete_group(system, group.id).success?.should be_true
    Api.post(system, post.id).group_id.should be_nil
    Api.groups(system, plan.id).should be_empty
  end

  it "normalise le code d'un poste, unique dans son plan, groupe du même plan" do
    plan = AnalyticSpec.plan("AXE")
    other = AnalyticSpec.plan("AUTRE")
    post = AnalyticSpec.post(plan, " ma'r <ke>ting ", "Marketing")
    post.code.should eq("MARKETING")
    post.plan_name.should eq("AXE")
    post.active.should be_true
    post.operations_count.should eq(0)

    Api.create_post(system, Api::PostInput.new(plan.id, "marketing")).error_keys.should eq(["analytic.errors.post.code_taken"])
    Api.create_post(system, Api::PostInput.new(other.id, "marketing")).success?.should be_true
    Api.create_post(system, Api::PostInput.new(plan.id, "<'>")).error_keys.should eq(["analytic.errors.post.code_required"])
    foreign = Api.create_group(system, Api::GroupInput.new(other.id, "G")).value!
    Api.create_post(system, Api::PostInput.new(plan.id, "X", group_id: foreign.id)).error_keys
      .should eq(["analytic.errors.post.group_plan"])

    updated = Api.update_post(system, post.id, Api::PostInput.new(other.id, "mkt", "M", active: false)).value!
    updated.plan_id.should eq(plan.id)
    updated.code.should eq("MKT")
    updated.active.should be_false
    Api.posts(system, plan.id, active_only: true).should be_empty
    Api.post_by_code(system, plan.id, "mkt").try(&.id).should eq(post.id)
    Api.post_by_code(system, plan.id, "absent").should be_nil
    Api.posts(system).map(&.code).sort!.should eq(["MARKETING", "MKT"])
  end

  it "supprime un poste et un plan avec leurs imputations, sauf en période close" do
    data = AnalyticSpec.setup
    entry = AnalyticSpec.expense("100")
    AnalyticSpec.distribute(entry, [AnalyticSpec.row("100", data[:sale], data[:p1])]).value!
    Api.post(system, data[:sale].id).operations_count.should eq(1)

    Api.delete_post(system, data[:p1].id).success?.should be_true
    Api.entry_distributions(system, entry.id).first.rows.first.posts.map(&.code).should eq(["VENTE"])

    Partiduo::Api::Core.close_period(system, EntrySpec.period("2026-03-15").id).value!
    Api.delete_post(system, data[:sale].id).error_keys.should eq(["analytic.errors.post.closed_period"])
    Api.delete_plan(system, data[:activity].id).error_keys.should eq(["analytic.errors.plan.closed_period"])
    Api.delete_plan(system, data[:project].id).success?.should be_true
    Api.plans(system).map(&.name).should eq(["ACTIVITÉ"])
  end

  it "retire une imputation devenue vide avec son plan" do
    data = AnalyticSpec.setup
    entry = AnalyticSpec.expense("80")
    AnalyticSpec.distribute(entry, [AnalyticSpec.row("80", data[:p2])]).value!
    Api.delete_plan(system, data[:project].id).success?.should be_true
    Api.entry_distributions(system, entry.id).should be_empty
    Partiduo::Analytic::Distribution.all.count.should eq(0)
  end

  it "exige les permissions du module" do
    reader = actor_with("analytic.plan.read")
    Api.plans(reader).should be_empty
    expect_raises(Partiduo::Api::Forbidden) { Api.create_plan(reader, Api::PlanInput.new("X")) }
    expect_raises(Partiduo::Api::Forbidden) { Api.plans(actor_with("analytic.report.read")) }
    expect_raises(Partiduo::Api::NotFound) { Api.plan(system, 999_i64) }
  end
end

describe_module "ANALYTIC", "Analytique : paramètres (MY_ANALYTIC, MY_ANC_FILTER)" do
  it "facultatif sur les classes 6 et 7 par défaut ; filtre de chiffres seulement" do
    settings = Api.settings(system)
    settings.mandatory.should be_false
    settings.prefixes.should eq(["6", "7"])
    settings.analytic_account?("603").should be_true
    settings.analytic_account?("400").should be_false

    Api.update_settings(system, Api::SettingsInput.new(true, "6a")).error_keys
      .should eq(["analytic.errors.settings.filter_invalid"])
    updated = Api.update_settings(system, Api::SettingsInput.new(true, " 60, 61 ,,")).value!
    updated.account_filter.should eq("60,61")
    updated.mandatory.should be_true
    Api.settings(system).analytic_account?("615").should be_true
    Api.settings(system).analytic_account?("706").should be_false

    everything = Api.update_settings(system, Api::SettingsInput.new(false, "")).value!
    everything.analytic_account?("400").should be_true
    expect_raises(Partiduo::Api::Forbidden) do
      Api.update_settings(actor_with("analytic.plan.read"), Api::SettingsInput.new(false, ""))
    end
  end
end
