# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Core
    # Devise, héritière de `currency` (NOALYSS 8) : code ISO 4217, nom,
    # nombre de décimales. Une seule devise est la devise *de tenue* du dossier
    # (`base`, l'euro créé au provisionnement, `currency.id = 0` de NOALYSS) :
    # elle n'a pas de cours et ne se modifie pas.
    class Currency < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :code, :string, max_size: 3, unique: true
      field :name, :string, max_size: 80
      field :decimals, :int, default: 2
      field :base, :bool, default: false

      with_timestamp_fields
    end

    # Cours d'une devise étrangère à partir d'une date, héritier de
    # `currency_history` : nombre d'unités de la devise de tenue pour une unité
    # de la devise (`ch_value numeric(20,8) > 0`).
    class CurrencyRate < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :currency, :many_to_one, to: Partiduo::Core::Currency, related: :rates, on_delete: :cascade
      field :valid_from, :date
      field :rate, :decimal, max_digits: 20, decimal_places: 8

      with_timestamp_fields

      db_unique_constraint :core_currency_rate_unique, field_names: [:currency, :valid_from]
    end
  end
end
