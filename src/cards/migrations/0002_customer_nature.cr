# SPDX-License-Identifier: AGPL-3.0-or-later

# Nature du client (ADR-004 D9 révisé le 28 septembre 2026) : particulier,
# professionnel ou administration publique, choisie sur la fiche (vide : pas
# encore précisée, fiches antérieures) ; refus de la copie PDF d'une facture
# transmise par la plateforme agréée, client par client. DECISIONS D-FIN-001
# et D-FIN-002.
class Migration::Cards::V0002 < Marten::Migration
  depends_on :cards, "0001_cards"

  def plan
    add_column :cards_card, :customer_nature, :string, max_size: 16, default: ""
    add_column :cards_card, :pdf_copy, :bool, default: true

    execute(
      "ALTER TABLE cards_card ADD CONSTRAINT cards_card_customer_nature_check " \
      "CHECK (customer_nature IN ('', 'individual', 'business', 'public'))",
      "ALTER TABLE cards_card DROP CONSTRAINT IF EXISTS cards_card_customer_nature_check"
    )
  end
end
