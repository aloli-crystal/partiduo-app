# SPDX-License-Identifier: AGPL-3.0-or-later

# Lot 5 (relecture) — rang de la ligne *saisie* dont provient chaque ligne
# d'écriture (`EntryInput.lines[i]`, `DocumentInput.lines[i]`) : un autre
# module (l'Analytique) désigne ainsi une ligne par sa saisie, sans deviner
# la construction de l'écriture (lignes nulles écartées, TVA, tiers).
# Nul pour les lignes calculées (TVA, tiers, banque) et pour les écritures
# antérieures (DECISIONS D-ANA-012).
class Migration::Accounting::V0006 < Marten::Migration
  depends_on :accounting, "0005_reports"

  def plan
    add_column :accounting_entry_line, :input_index, :int, null: true
  end
end
