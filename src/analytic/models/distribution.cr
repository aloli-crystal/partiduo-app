# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Analytic
    # Imputation analytique : en-tête d'un groupe d'opérations (`oa_group` de
    # `operation_analytique`).
    #
    # * `kind` `entry` : ventilation d'une ligne d'écriture (`j_id`) ; la
    #   ligne, son écriture et son journal sont ceux de la Comptabilité
    #   (clés étrangères posées par la migration) ; date, pièce, compte et
    #   libellé sont recopiés à l'imputation — l'écriture est intangible
    #   (D-ANA-005) ;
    # * `kind` `misc` : opération diverse analytique (`anc_od.inc.php`), sans
    #   écriture, équilibrée par plan.
    #
    # Une imputation d'une période close ne change plus (déclencheur,
    # migration analytic 0001).
    class Distribution < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :kind, :string, max_size: 5, default: "entry"
      field :entry_id, :big_int, null: true, blank: true
      field :entry_line_id, :big_int, null: true, blank: true, unique: true
      field :ledger_id, :big_int, null: true, blank: true
      field :ledger_code, :string, max_size: 20, blank: true, default: ""
      field :internal_code, :string, max_size: 20, blank: true, default: ""
      field :receipt, :string, max_size: 40, blank: true, default: ""
      field :account_number, :string, max_size: 40, blank: true, default: ""
      field :account_label, :string, max_size: 255, blank: true, default: ""
      field :line_amount, :decimal, max_digits: 20, decimal_places: 4, null: true, blank: true
      field :date, :date
      field :description, :text, blank: true, default: ""
      field :created_by_id, :big_int, null: true, blank: true

      with_timestamp_fields
    end

    # Opération analytique (`operation_analytique`) : une ligne (`oa_row`)
    # d'une imputation pour un plan, son poste, son montant positif et son
    # sens ; fiche facultative (`f_id`, opérations diverses).
    class Operation < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :distribution, :many_to_one, to: Partiduo::Analytic::Distribution, related: :operations,
        on_delete: :cascade
      field :row, :int, default: 0
      field :plan, :many_to_one, to: Partiduo::Analytic::Plan, related: :operations, on_delete: :cascade
      field :post, :many_to_one, to: Partiduo::Analytic::Post, related: :operations, on_delete: :cascade
      field :amount, :decimal, max_digits: 20, decimal_places: 4
      field :side, :string, max_size: 6
      field :card_id, :big_int, null: true, blank: true
      field :card_code, :string, max_size: 40, blank: true, default: ""

      db_unique_constraint :analytic_operation_row_plan, field_names: [:distribution, :row, :plan]
    end

    # Paramètres de l'Analytique (`MY_ANALYTIC`, `MY_ANC_FILTER`) : ventilation
    # obligatoire ou facultative, préfixes des comptes ventilés. Une seule
    # ligne, créée à la première lecture.
    class Setting < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :mandatory, :bool, default: false
      field :account_filter, :string, max_size: 255, blank: true, default: "6,7"
      # Toujours vrai, unique : une seule ligne (migration 0002, D-ANA-017).
      field :singleton, :bool, default: true

      with_timestamp_fields
    end
  end
end
