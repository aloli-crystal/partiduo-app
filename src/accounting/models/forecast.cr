# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Accounting
    # Prévision budgétaire (`forecast`, `Anticipation`) : nom, première et
    # dernière périodes du socle (`f_start_date`, `f_end_date`). Écrite par
    # `Partiduo::Api::Accounting.create_forecast` (lot 6, D-FCT-001).
    class Forecast < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :name, :string, max_size: 255
      # Périodes du socle (`core_period`) ; clés étrangères posées par la
      # migration.
      field :start_period_id, :big_int
      field :end_period_id, :big_int
      field :created_by_id, :big_int, null: true, blank: true

      with_timestamp_fields
    end

    # Catégorie d'une prévision (`forecast_category`) : libellé, rang.
    class ForecastCategory < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :forecast, :many_to_one, to: Partiduo::Accounting::Forecast, related: :categories, on_delete: :cascade
      field :label, :string, max_size: 255
      field :position, :int, default: 0
    end

    # Élément d'une catégorie (`forecast_item` à `fi_pid = 0`) : libellé,
    # formule du réel (celle des rapports, `Formula`), montant estimé de
    # chaque période, montant ajouté à la première période
    # (`fi_amount_initial`), rang.
    class ForecastItem < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :category, :many_to_one, to: Partiduo::Accounting::ForecastCategory, related: :items, on_delete: :cascade
      field :label, :string, max_size: 255
      field :formula, :text, blank: true
      field :amount, :decimal, max_digits: 20, decimal_places: 4, default: BigDecimal.new(0)
      field :initial_amount, :decimal, max_digits: 20, decimal_places: 4, default: BigDecimal.new(0)
      field :position, :int, default: 0
    end

    # Estimation propre à une période (`forecast_item` à `fi_pid` = période,
    # même formule dans la catégorie) : remplace le montant de l'élément
    # pour cette période (D-FCT-002).
    class ForecastAmount < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :item, :many_to_one, to: Partiduo::Accounting::ForecastItem, related: :period_amounts, on_delete: :cascade
      field :period_id, :big_int
      field :amount, :decimal, max_digits: 20, decimal_places: 4

      db_unique_constraint :accounting_forecast_amount_unique, field_names: [:item, :period_id]
    end
  end
end
