# SPDX-License-Identifier: AGPL-3.0-or-later

require "./ledger"

module Partiduo
  module Accounting
    # Relevé bancaire rapproché (successeur de `jrn.jr_pj_number` pour les
    # journaux financiers, `compta_fin_rec.inc.php`) : numéro, soldes de début
    # et de fin, pièce jointe du socle. Les écritures rapprochées le citent
    # (`Entry#statement_id`). Modèle interne : on n'écrit un relevé que par
    # `Partiduo::Api::Accounting.reconcile`.
    class BankStatement < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :ledger, :many_to_one, to: Partiduo::Accounting::Ledger, related: :bank_statements
      field :reference, :string, max_size: 40
      field :start_balance, :decimal, max_digits: 20, decimal_places: 4, null: true, blank: true
      field :end_balance, :decimal, max_digits: 20, decimal_places: 4, null: true, blank: true
      # Pièce jointe du socle (`core_attachment`) ; clé étrangère posée par la migration.
      field :attachment_id, :big_int, null: true, blank: true
      field :created_by_id, :big_int, null: true, blank: true
      field :created_at, :date_time, auto_now_add: true

      # Déclaré en dernier (B-REF-001).
      db_unique_constraint :accounting_bank_statement_unique, field_names: [:ledger, :reference]
    end
  end
end
