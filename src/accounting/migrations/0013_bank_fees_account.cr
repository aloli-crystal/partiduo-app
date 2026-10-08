# SPDX-License-Identifier: AGPL-3.0-or-later

# Compte de frais bancaires d'un paiement rejeté (D-INV3-008) : le plan
# initial le porte désormais ; une instance déjà provisionnée le reçoit ici.
#
# * régime `fr` et plan chargé (compte `6` présent) : compte `627`
#   « Services bancaires et assimilés » sous `62` (à défaut sous `6`), s'il
#   manque ;
# * compte par défaut `bank_fees` : `627` (fr) ou `657` (be), si ce compte
#   existe et qu'aucun compte par défaut `bank_fees` n'est posé.
#
# Retour : le compte par défaut `bank_fees` est retiré ; le compte `627`
# ajouté par cette migration (repéré par une table de travail) est effacé
# s'il n'est cité nulle part.
class Migration::Accounting::V0013 < Marten::Migration
  depends_on :accounting, "0012_result_accounts_fr"
  depends_on :core, "0001_create_core_settings_table"

  FORWARD_ACCOUNT = <<-SQL
    WITH added AS (
      INSERT INTO accounting_account (number, label, parent_id, kind, direct_use, created_at, updated_at)
      SELECT '627', 'Services bancaires et assimilés',
             coalesce((SELECT id FROM accounting_account WHERE number = '62'),
                      (SELECT id FROM accounting_account WHERE number = '6')),
             'expense', true, now(), now()
       WHERE EXISTS (SELECT 1 FROM core_settings WHERE tax_regime = 'fr')
         AND EXISTS (SELECT 1 FROM accounting_account WHERE number = '6')
         AND NOT EXISTS (SELECT 1 FROM accounting_account WHERE number = '627')
      RETURNING id
    )
    INSERT INTO accounting_bank_fees_account_added (account_id)
    SELECT id FROM added ON CONFLICT DO NOTHING
    SQL

  FORWARD_DEFAULT = <<-SQL
    INSERT INTO accounting_default_account (code, account_id)
    SELECT 'bank_fees', account.id
      FROM core_settings settings
      JOIN accounting_account account
        ON account.number = CASE settings.tax_regime WHEN 'fr' THEN '627' WHEN 'be' THEN '657' END
     WHERE NOT EXISTS (SELECT 1 FROM accounting_default_account WHERE code = 'bank_fees')
     LIMIT 1
    SQL

  BACKWARD = <<-SQL
    DO $$
    DECLARE
      added bigint;
    BEGIN
      DELETE FROM accounting_default_account WHERE code = 'bank_fees';
      FOR added IN SELECT account_id FROM accounting_bank_fees_account_added LOOP
        BEGIN
          DELETE FROM accounting_account WHERE id = added;
          DELETE FROM accounting_bank_fees_account_added WHERE account_id = added;
        EXCEPTION WHEN foreign_key_violation THEN
          NULL; -- compte cité (écriture, paramétrage) : conservé
        END;
      END LOOP;
    END
    $$
    SQL

  def plan
    execute(
      "CREATE TABLE accounting_bank_fees_account_added (account_id bigint PRIMARY KEY)",
      "DROP TABLE IF EXISTS accounting_bank_fees_account_added"
    )
    execute(FORWARD_ACCOUNT, "SELECT 1")
    execute(FORWARD_DEFAULT, BACKWARD)
  end
end
