# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Analytic
    # Plan analytique (axe), héritier de `plan_analytique` : nom unique, en
    # majuscules sans espace (déclencheur `plan_analytic_ins_upd`),
    # description. Dix plans au plus (`Anc_Plan::isAppend`, D-ANA-003).
    # Modèle interne : l'interface passe par `Partiduo::Api::Analytic`.
    class Plan < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :name, :string, max_size: 100, unique: true
      field :description, :text, blank: true, default: ""

      with_timestamp_fields
    end

    # Groupe de postes d'un plan (`groupe_analytique`) : code de dix
    # caractères au plus, en majuscules sans espace, unique dans son plan
    # (D-ANA-002). Supprimer un groupe détache ses postes
    # (`group_analytique_del`).
    class Group < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :plan, :many_to_one, to: Partiduo::Analytic::Plan, related: :groups, on_delete: :cascade
      field :code, :string, max_size: 10
      field :description, :text, blank: true, default: ""

      db_unique_constraint :analytic_group_plan_code, field_names: [:plan, :code]
    end

    # Poste analytique (`poste_analytique`) : code unique dans son plan
    # (D-ANA-002), description, groupe éventuel du même plan, actif ou non
    # (`po_state`) ; un poste inactif n'est plus proposé à la ventilation.
    class Post < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :plan, :many_to_one, to: Partiduo::Analytic::Plan, related: :posts, on_delete: :cascade
      field :code, :string, max_size: 100
      field :description, :text, blank: true, default: ""
      field :group, :many_to_one, to: Partiduo::Analytic::Group, related: :posts, null: true, blank: true,
        on_delete: :set_null
      field :active, :bool, default: true

      db_unique_constraint :analytic_post_plan_code, field_names: [:plan, :code]
    end
  end
end
