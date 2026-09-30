# SPDX-License-Identifier: AGPL-3.0-or-later

# Interface du dossier (DECISIONS D-LIB3-001) : `liberal_settings.interface`
# retient, pour tous les utilisateurs du dossier, la présentation choisie
# dans les paramètres — `simple` (recettes et dépenses, par défaut) ou
# `accounting` (comptabilité). Liste fermée par contrainte.
class Migration::Liberal::V0004 < Marten::Migration
  depends_on :liberal, "0003_open_year_changes"

  def plan
    add_column :liberal_settings, :interface, :string, max_size: 16, default: "simple"
    execute("ALTER TABLE liberal_settings ADD CONSTRAINT liberal_settings_interface_check " \
            "CHECK (interface IN ('simple', 'accounting'))",
      "ALTER TABLE liberal_settings DROP CONSTRAINT IF EXISTS liberal_settings_interface_check")
  end
end
