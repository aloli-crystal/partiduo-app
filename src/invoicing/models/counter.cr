# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Invoicing
    # Compteur d'une série de numérotation (ADR-006 D5) : une ligne par série
    # et par année, verrouillée par `SELECT … FOR UPDATE` dans la transaction
    # d'émission, puis incrémentée. Jamais une séquence PostgreSQL : une
    # émission annulée ne laisse pas de trou. En base : le compteur ne fait
    # qu'avancer d'une unité et ne se supprime pas (déclencheur).
    #
    # `last_date` : date d'émission du dernier document de la série, pour la
    # chronologie (un document n'est pas émis à une date antérieure).
    class Counter < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :series, :string, max_size: 16
      field :year, :int
      field :last_number, :int, default: 0
      field :last_date, :date, null: true, blank: true

      db_unique_constraint :invoicing_counter_series_year, field_names: [:series, :year]
    end
  end
end
