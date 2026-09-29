# SPDX-License-Identifier: AGPL-3.0-or-later

# Visibilité d'une action réservée à un profil (`action_gestion.ag_dest`
# d'origine ; DECISIONS D-FUP-001 révisée, D-R5-016) : vide, toute personne
# qui lit le suivi la voit ; sinon, les utilisateurs de ce profil, son
# auteur et qui paramètre le suivi. Un profil supprimé rend l'action
# visible de tous.
class Migration::Followup::V0002 < Marten::Migration
  depends_on :followup, "0001_followup"

  def plan
    add_column :followup_action, :visible_profile_id, :big_int, null: true

    execute(
      "ALTER TABLE followup_action ADD CONSTRAINT followup_action_visible_profile_fk FOREIGN KEY (visible_profile_id) " \
      "REFERENCES auth_profile (id) ON DELETE SET NULL",
      "ALTER TABLE followup_action DROP CONSTRAINT IF EXISTS followup_action_visible_profile_fk"
    )
  end
end
