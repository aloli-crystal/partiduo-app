# SPDX-License-Identifier: AGPL-3.0-or-later

# Relecture des lots P, 0 et 1 :
#
# * journal financier : il cite une *fiche* Banque du socle (`jrn_def_bank`
#   est un `f_id`, D-ACC-010), dont le compte est celui du journal ; clé
#   étrangère sans cascade (NO ACTION : une fiche citée par un journal ne
#   s'efface pas, `Core::Db.delete_unless_referenced` le signale),
#   fiche obligatoire pour un journal financier — contrôle `NOT VALID` : les
#   journaux financiers d'avant (compte seul) restent lisibles ;
# * comptes de TVA de chaque taux (`tva_rate.tva_poste`, D-ACC-009).
class Migration::Accounting::V0002 < Marten::Migration
  depends_on :accounting, "0001_create_accounting_reference_tables"
  depends_on :vat, "0001_vat_rates"

  def plan
    add_column :accounting_ledger, :bank_card_id, :big_int, null: true

    create_table :accounting_vat_rate_account do
      column :id, :big_int, primary_key: true, auto: true
      column :vat_rate_id, :big_int, unique: true
      column :deductible_account_id, :reference, to_table: :accounting_account, to_column: :id, null: true
      column :collected_account_id, :reference, to_table: :accounting_account, to_column: :id, null: true
    end

    execute(
      <<-SQL,
        ALTER TABLE accounting_ledger
          DROP CONSTRAINT IF EXISTS accounting_ledger_financial_account_check,
          ADD CONSTRAINT accounting_ledger_bank_card_fk
            FOREIGN KEY (bank_card_id) REFERENCES cards_card (id),
          ADD CONSTRAINT accounting_ledger_financial_bank_card_check
            CHECK (kind <> 'financial' OR bank_card_id IS NOT NULL) NOT VALID
        SQL
      <<-SQL
        ALTER TABLE accounting_ledger
          DROP CONSTRAINT IF EXISTS accounting_ledger_bank_card_fk,
          DROP CONSTRAINT IF EXISTS accounting_ledger_financial_bank_card_check
        SQL
    )
    execute(
      <<-SQL,
        ALTER TABLE accounting_vat_rate_account
          ADD CONSTRAINT accounting_vat_rate_account_rate_fk
            FOREIGN KEY (vat_rate_id) REFERENCES vat_rate (id) ON DELETE CASCADE
        SQL
      "ALTER TABLE accounting_vat_rate_account DROP CONSTRAINT IF EXISTS accounting_vat_rate_account_rate_fk"
    )
  end
end
