# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Accounting
    # Rapport personnalisé, héritier de `formulaire` : un nom et des lignes
    # (`ReportLine`). Écrit par `Partiduo::Api::Accounting.create_report`.
    class Report < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :name, :string, max_size: 100, unique: true
      field :created_by_id, :big_int, null: true, blank: true

      with_timestamp_fields
    end

    # Ligne d'un rapport, héritière de `form_definition` : position
    # (`fo_pos`), libellé (`fo_label`), formule (`fo_formula`, voir
    # `Formula`).
    class ReportLine < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :report, :many_to_one, to: Partiduo::Accounting::Report, related: :lines, on_delete: :cascade
      field :position, :int, default: 0
      field :label, :string, max_size: 255
      field :formula, :text
    end
  end
end
