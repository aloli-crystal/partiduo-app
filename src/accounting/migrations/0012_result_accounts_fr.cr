# SPDX-License-Identifier: AGPL-3.0-or-later

# Comptes de résultat de la clôture d'exercice au plan FR (amendement
# D-CLO-003, adopté le 29 septembre 2026) : le plan initial les porte
# désormais ; une instance française déjà provisionnée les reçoit ici s'ils
# manquent — `120` (bénéfice) et `129` (perte), sous `12` (à défaut sous
# `1`), mêmes libellés, type et usage que le plan initial. Instance
# française : régime `fr` de la configuration société et plan chargé
# (compte `1` présent). Un compte déjà présent n'est pas touché.
#
# Retour : les comptes ajoutés par cette migration (et eux seuls, repérés par
# une table de travail) sont effacés s'ils ne sont cités nulle part.
class Migration::Accounting::V0012 < Marten::Migration
  depends_on :accounting, "0011_liberal_accounts"
  depends_on :core, "0001_create_core_settings_table"

  FORWARD = <<-SQL
    WITH instance AS (
      SELECT 1 FROM core_settings
       WHERE tax_regime = 'fr' AND EXISTS (SELECT 1 FROM accounting_account WHERE number = '1')
    ), wanted (number, label) AS (
      VALUES ('120', 'Résultat de l''exercice (bénéfice)'), ('129', 'Résultat de l''exercice (perte)')
    ), added AS (
      INSERT INTO accounting_account (number, label, parent_id, kind, direct_use, created_at, updated_at)
      SELECT wanted.number, wanted.label,
             coalesce((SELECT id FROM accounting_account WHERE number = '12'),
                      (SELECT id FROM accounting_account WHERE number = '1')),
             'liability', true, now(), now()
        FROM wanted
       WHERE EXISTS (SELECT 1 FROM instance)
         AND NOT EXISTS (SELECT 1 FROM accounting_account account WHERE account.number = wanted.number)
      RETURNING id
    )
    INSERT INTO accounting_result_account_added (account_id)
    SELECT id FROM added ON CONFLICT DO NOTHING
    SQL

  BACKWARD = <<-SQL
    DO $$
    DECLARE
      added bigint;
    BEGIN
      FOR added IN SELECT account_id FROM accounting_result_account_added LOOP
        BEGIN
          DELETE FROM accounting_account WHERE id = added;
          DELETE FROM accounting_result_account_added WHERE account_id = added;
        EXCEPTION WHEN foreign_key_violation THEN
          NULL; -- compte cité (écriture, paramétrage) : conservé
        END;
      END LOOP;
    END
    $$
    SQL

  def plan
    execute(
      "CREATE TABLE accounting_result_account_added (account_id bigint PRIMARY KEY)",
      "DROP TABLE IF EXISTS accounting_result_account_added"
    )
    execute(FORWARD, BACKWARD)
  end
end
