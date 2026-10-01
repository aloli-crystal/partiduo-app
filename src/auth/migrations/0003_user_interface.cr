# SPDX-License-Identifier: AGPL-3.0-or-later

# Préférence d'interface de l'utilisateur (DECISIONS D-AUTH-016) :
# `auth_user.interface` retient le choix de la personne — `simple`
# (présentation simplifiée : recettes et dépenses, mode simplifié) ou
# `full` (présentation complète : comptabilité) —, NULL tant qu'elle n'a
# rien choisi (défaut selon le rôle). Liste fermée par contrainte.
class Migration::Auth::V0003 < Marten::Migration
  depends_on :auth, "0002_auth_security"

  def plan
    add_column :auth_user, :interface, :string, max_size: 8, null: true
    execute("ALTER TABLE auth_user ADD CONSTRAINT auth_user_interface_check " \
            "CHECK (interface IS NULL OR interface IN ('simple', 'full'))",
      "ALTER TABLE auth_user DROP CONSTRAINT IF EXISTS auth_user_interface_check")
  end
end
