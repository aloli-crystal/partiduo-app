# SPDX-License-Identifier: AGPL-3.0-or-later

# Outils des specs de l'Analytique (lot 5) : dossier français des écritures
# (`EntrySpec.setup`), plans et postes créés par le contrat.
module AnalyticSpec
  alias Api = Partiduo::Api::Analytic
  alias Acc = Partiduo::Api::Accounting

  def self.system : Partiduo::Api::Actor
    Partiduo::Api::Actor.system
  end

  def self.d(text : String) : BigDecimal
    BigDecimal.new(text)
  end

  def self.plan(name : String, description : String = "") : Api::PlanView
    Api.create_plan(system, Api::PlanInput.new(name, description)).value!
  end

  def self.post(plan : Api::PlanView, code : String, description : String = "", group_id : Int64? = nil,
                active : Bool = true) : Api::PostView
    Api.create_post(system, Api::PostInput.new(plan.id, code, description, group_id, active)).value!
  end

  def self.row(amount : String, *posts : Api::PostView) : Api::DistributionRowInput
    Api::DistributionRowInput.new(d(amount), posts.to_a.map(&.id))
  end

  # Dossier d'écritures, deux plans : ACTIVITE (VENTE, ATELIER) et
  # PROJET (P1, P2).
  def self.setup : NamedTuple(activity: Api::PlanView, project: Api::PlanView, sale: Api::PostView,
    workshop: Api::PostView, p1: Api::PostView, p2: Api::PostView)
    EntrySpec.setup
    activity = plan("Activité", "Axe des activités")
    project = plan("Projet")
    {
      activity: activity, project: project,
      sale: post(activity, "vente", "Ventes"), workshop: post(activity, "atelier", "Atelier"),
      p1: post(project, "p1", "Projet 1"), p2: post(project, "p2", "Projet 2"),
    }
  end

  # Opération diverse 6xx / 4xx : ligne de charge en première position.
  def self.expense(amount : String, day : String = "2026-03-15", account : String = "603") : Acc::EntryView
    EntrySpec.post_misc([EntrySpec.debit(account, amount), EntrySpec.credit("400", amount)], day)
  end

  def self.distribute(entry : Acc::EntryView, rows : Array(Api::DistributionRowInput), position : Int32 = 0)
    Api.distribute_entry(system, entry.id, [Api::LineDistributionInput.new(entry.lines[position].id, rows)])
  end

  def self.mandatory!(filter : String = "6,7") : Nil
    Api.update_settings(system, Api::SettingsInput.new(true, filter)).value!
  end
end
