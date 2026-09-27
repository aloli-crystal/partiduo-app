# SPDX-License-Identifier: AGPL-3.0-or-later

# Rapprochement bancaire, successeur du numéro de relevé porté par `jrn`
# (`jr_pj_number` mis à jour par `compta_fin_rec.inc.php`) : un relevé
# (`accounting_bank_statement`) par journal financier, avec ses soldes de
# début et de fin et sa pièce jointe ; chaque écriture rapprochée le cite
# (`accounting_entry.statement_id`). Le numéro est unique dans un journal.
# Rapprocher ne touche ni la date ni les montants : permis en période close
# (`accounting_entry_period_guard`), comme la pièce. DECISIONS D-REC-001.
class Migration::Accounting::V0008 < Marten::Migration
  depends_on :accounting, "0007_forecasts"
  depends_on :core, "0003_period_guard_fiscal_year_move"

  def plan
    create_table :accounting_bank_statement do
      column :id, :big_int, primary_key: true, auto: true
      column :ledger_id, :reference, to_table: :accounting_ledger, to_column: :id
      column :reference, :string, max_size: 40
      column :start_balance, :decimal, max_digits: 20, decimal_places: 4, null: true
      column :end_balance, :decimal, max_digits: 20, decimal_places: 4, null: true
      column :attachment_id, :big_int, null: true
      column :created_by_id, :big_int, null: true
      column :created_at, :date_time
    end

    add_unique_constraint :accounting_bank_statement, :accounting_bank_statement_unique, [:ledger_id, :reference]
    add_column :accounting_entry, :statement_id, :big_int, null: true

    execute(
      "ALTER TABLE accounting_entry ADD CONSTRAINT accounting_entry_statement_fk " \
      "FOREIGN KEY (statement_id) REFERENCES accounting_bank_statement (id)",
      "ALTER TABLE accounting_entry DROP CONSTRAINT IF EXISTS accounting_entry_statement_fk"
    )
    execute(
      "ALTER TABLE accounting_bank_statement ADD CONSTRAINT accounting_bank_statement_attachment_fk " \
      "FOREIGN KEY (attachment_id) REFERENCES core_attachment (id)",
      "ALTER TABLE accounting_bank_statement DROP CONSTRAINT IF EXISTS accounting_bank_statement_attachment_fk"
    )
    execute(
      "ALTER TABLE accounting_bank_statement ADD CONSTRAINT accounting_bank_statement_reference_check " \
      "CHECK (btrim(reference) <> '')",
      "ALTER TABLE accounting_bank_statement DROP CONSTRAINT IF EXISTS accounting_bank_statement_reference_check"
    )
    execute(
      "CREATE INDEX accounting_entry_statement ON accounting_entry (statement_id) WHERE statement_id IS NOT NULL",
      "DROP INDEX IF EXISTS accounting_entry_statement"
    )
  end
end
