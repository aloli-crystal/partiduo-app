# SPDX-License-Identifier: AGPL-3.0-or-later

# Lot 5 (relecture) — ligne unique des paramètres de l'Analytique : colonne
# `singleton` toujours vraie et unique, ligne par défaut créée ici plutôt
# qu'à la première lecture (deux lectures concurrentes créaient deux
# lignes, D-ANA-017). Doublons éventuels : seule la plus ancienne reste.
class Migration::Analytic::V0002 < Marten::Migration
  depends_on :analytic, "0001_analytic"

  def plan
    add_column :analytic_setting, :singleton, :bool, default: true

    execute(
      "DELETE FROM analytic_setting s WHERE EXISTS (SELECT 1 FROM analytic_setting o WHERE o.id < s.id)",
      "SELECT 1"
    )
    execute("UPDATE analytic_setting SET singleton = true", "SELECT 1")
    execute(
      "ALTER TABLE analytic_setting ALTER COLUMN singleton SET NOT NULL, " \
      "ADD CONSTRAINT analytic_setting_singleton UNIQUE (singleton), " \
      "ADD CONSTRAINT analytic_setting_singleton_check CHECK (singleton)",
      "ALTER TABLE analytic_setting DROP CONSTRAINT IF EXISTS analytic_setting_singleton_check, " \
      "DROP CONSTRAINT IF EXISTS analytic_setting_singleton"
    )
    execute(
      "INSERT INTO analytic_setting (mandatory, account_filter, singleton, created_at, updated_at) " \
      "VALUES (false, '6,7', true, now(), now()) ON CONFLICT (singleton) DO NOTHING",
      "SELECT 1"
    )
  end
end
