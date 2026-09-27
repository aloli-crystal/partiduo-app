# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Analytic
    # Clé de répartition (`key_distribution`) : nom, description, lignes
    # (pourcentage et un poste par plan) et journaux où elle est proposée.
    class Key < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :name, :string, max_size: 100
      field :description, :text, blank: true, default: ""

      with_timestamp_fields
    end

    # Ligne d'une clé (`key_distribution_detail`) : rang et pourcentage.
    class KeyRow < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :key, :many_to_one, to: Partiduo::Analytic::Key, related: :rows, on_delete: :cascade
      field :position, :int, default: 0
      field :percent, :decimal, max_digits: 20, decimal_places: 4
    end

    # Poste d'une ligne de clé pour un plan (`key_distribution_activity`) ;
    # un plan sans poste n'a pas de ligne ici.
    class KeyRowPost < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :row, :many_to_one, to: Partiduo::Analytic::KeyRow, related: :posts, on_delete: :cascade
      field :plan, :many_to_one, to: Partiduo::Analytic::Plan, related: :key_row_posts, on_delete: :cascade
      field :post, :many_to_one, to: Partiduo::Analytic::Post, related: :key_row_posts, on_delete: :cascade

      db_unique_constraint :analytic_key_row_post_plan, field_names: [:row, :plan]
    end

    # Journal où la clé est proposée (`key_distribution_ledger`) ;
    # `ledger_id` : journal de la Comptabilité (`accounting_ledger`, clé
    # étrangère posée par la migration).
    class KeyLedger < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :key, :many_to_one, to: Partiduo::Analytic::Key, related: :ledgers, on_delete: :cascade
      field :ledger_id, :big_int

      db_unique_constraint :analytic_key_ledger_unique, field_names: [:key, :ledger_id]
    end
  end
end
