# SPDX-License-Identifier: AGPL-3.0-or-later

# Paramétrage des écritures du module liberal (ADR-007 D6) : compte par
# nature, par rubrique de la 2035-A ou par catégorie d'immobilisation.
# DECISIONS D-LIB-003.
class Migration::Accounting::V0011 < Marten::Migration
  depends_on :accounting, "0010_micro_accounts"

  def plan
    create_table :accounting_liberal_account do
      column :id, :big_int, primary_key: true, auto: true
      column :key, :string, max_size: 40, unique: true
      column :account_id, :reference, to_table: :accounting_account, to_column: :id
    end

    execute(
      "ALTER TABLE accounting_liberal_account ADD CONSTRAINT accounting_liberal_account_key_check " \
      "CHECK (key ~ '^[A-Za-z0-9_]{1,40}$')",
      "ALTER TABLE accounting_liberal_account DROP CONSTRAINT IF EXISTS accounting_liberal_account_key_check"
    )
  end
end
