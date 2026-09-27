# SPDX-License-Identifier: AGPL-3.0-or-later

# Paramétrage des écritures de la micro-entreprise (ADR-007 D2) : compte de
# contrepartie par nature ou par catégorie de registre. DECISIONS D-MIC-004.
class Migration::Accounting::V0010 < Marten::Migration
  depends_on :accounting, "0009_received_invoices"

  def plan
    create_table :accounting_micro_account do
      column :id, :big_int, primary_key: true, auto: true
      column :key, :string, max_size: 26, unique: true
      column :account_id, :reference, to_table: :accounting_account, to_column: :id
    end

    execute(
      "ALTER TABLE accounting_micro_account ADD CONSTRAINT accounting_micro_account_key_check " \
      "CHECK (key ~ '^[A-Za-z0-9_]{1,26}$')",
      "ALTER TABLE accounting_micro_account DROP CONSTRAINT IF EXISTS accounting_micro_account_key_check"
    )
  end
end
