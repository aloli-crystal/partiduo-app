# SPDX-License-Identifier: AGPL-3.0-or-later

# Nature d'un fournisseur (DAS2) : personne physique (`individual`) ou
# personne morale (`business`) ; vide : pas encore précisée (fiches
# antérieures, déclarées en raison sociale comme avant). Une personne
# physique porte son nom, ses prénoms et sa date de naissance, que la DAS2
# déclare à la place de la raison sociale. DECISIONS D-R5-001.
class Migration::Cards::V0004 < Marten::Migration
  depends_on :cards, "0003_customer_nature_initial"

  def plan
    add_column :cards_card, :supplier_nature, :string, max_size: 16, default: ""
    add_column :cards_card, :last_name, :string, max_size: 128, default: ""
    add_column :cards_card, :first_names, :string, max_size: 128, default: ""
    add_column :cards_card, :birth_date, :date, null: true

    execute(
      "ALTER TABLE cards_card ADD CONSTRAINT cards_card_supplier_nature_check " \
      "CHECK (supplier_nature IN ('', 'individual', 'business'))",
      "ALTER TABLE cards_card DROP CONSTRAINT IF EXISTS cards_card_supplier_nature_check"
    )
    execute(
      "ALTER TABLE cards_card ADD CONSTRAINT cards_card_person_check " \
      "CHECK (supplier_nature = 'individual' OR (last_name = '' AND first_names = '' AND birth_date IS NULL))",
      "ALTER TABLE cards_card DROP CONSTRAINT IF EXISTS cards_card_person_check"
    )
  end
end
