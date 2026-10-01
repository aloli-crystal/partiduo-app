# SPDX-License-Identifier: AGPL-3.0-or-later

# L'interface n'est plus un réglage du dossier mais une préférence de chaque
# utilisateur (DECISIONS D-UI-077, D-AUTH-016 ; D-LIB3-001 remplacée). Le
# dossier qui avait choisi la comptabilité la transmet à ses utilisateurs de
# la société qui n'ont encore rien choisi (le comptable y est par défaut),
# puis `liberal_settings.interface` disparaît avec sa contrainte.
class Migration::Liberal::V0005 < Marten::Migration
  depends_on :liberal, "0004_settings_interface"
  depends_on :auth, "0003_user_interface"

  def plan
    execute("UPDATE auth_user SET interface = 'full' WHERE role = 'member' AND interface IS NULL " \
            "AND EXISTS (SELECT 1 FROM liberal_settings WHERE interface = 'accounting')")
    execute("ALTER TABLE liberal_settings DROP CONSTRAINT IF EXISTS liberal_settings_interface_check",
      "ALTER TABLE liberal_settings ADD CONSTRAINT liberal_settings_interface_check " \
      "CHECK (interface IN ('simple', 'accounting'))")
    remove_column :liberal_settings, :interface
  end
end
