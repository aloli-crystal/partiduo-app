# SPDX-License-Identifier: AGPL-3.0-or-later

# Nature du client (ADR-004 D9 révisé) : les fiches de client existantes
# sans nature reçoivent celle que la règle en place leur prêtait déjà
# (`CardRules.propose_nature`) : administration publique pour un SIREN
# commençant par 1 ou 2 (lu sur la fiche, sinon dans un numéro de TVA
# français), professionnel avec un SIREN ou un numéro de TVA, particulier
# sinon. Rien ne change donc pour le canal, le B2C ni les mentions ; la
# nature devient visible et modifiable sur la fiche.
#
# SIREN : une fiche de client sans SIREN mais avec un numéro de TVA
# français reçoit le SIREN qu'il porte (caractères 5 à 13), s'il passe la
# clé de Luhn : sans cela, la nature désormais choisie ferait refuser à la
# validation toute facture à ce client (`Issuing.siren_required?`), cas
# courant des fiches reprises de NOALYSS qui n'ont que la TVA.
#
# Retour : les natures et les SIREN posés par cette migration (et eux
# seuls, repérés par deux tables de travail) redeviennent vides.
# DECISIONS D-CPY-002, D-CPY-008.
class Migration::Cards::V0003 < Marten::Migration
  depends_on :cards, "0002_customer_nature"

  VAT_FR = %q('^FR[0-9A-Z]{2}[0-9]{9}$')

  FORWARD = <<-SQL
    WITH candidates AS (
      SELECT card.id,
             card.customer_nature = '' AS set_nature,
             btrim(card.siren) = '' AND btrim(card.vat_number) ~ #{VAT_FR} AS derived,
             CASE
               WHEN btrim(card.siren) <> '' THEN btrim(card.siren)
               WHEN btrim(card.vat_number) ~ #{VAT_FR} THEN substr(btrim(card.vat_number), 5, 9)
               ELSE ''
             END AS siren,
             btrim(card.vat_number) AS vat_number
        FROM cards_card card
        JOIN cards_category category ON category.id = card.category_id
       WHERE category.kind = 'customer'
         AND (card.customer_nature = '' OR (btrim(card.siren) = '' AND btrim(card.vat_number) ~ #{VAT_FR}))
    ), eligible AS (
      SELECT candidates.*,
             candidates.derived AND (
               SELECT sum(CASE WHEN i % 2 = 0 THEN (d * 2) / 10 + (d * 2) % 10 ELSE d END)
                 FROM (SELECT i, substr(candidates.siren, i, 1)::int AS d FROM generate_series(1, 9) AS i) digits
             ) % 10 = 0 AS fill_siren
        FROM candidates
    ), updated AS (
      UPDATE cards_card card
         SET customer_nature = CASE
               WHEN NOT eligible.set_nature THEN card.customer_nature
               WHEN length(eligible.siren) = 9 AND left(eligible.siren, 1) IN ('1', '2') THEN 'public'
               WHEN eligible.siren = '' AND eligible.vat_number = '' THEN 'individual'
               ELSE 'business'
             END,
             siren = CASE WHEN eligible.fill_siren THEN eligible.siren ELSE card.siren END
        FROM eligible
       WHERE card.id = eligible.id AND (eligible.set_nature OR eligible.fill_siren)
      RETURNING card.id, eligible.set_nature, eligible.fill_siren
    ), sirens AS (
      INSERT INTO cards_customer_siren_filled (card_id)
      SELECT id FROM updated WHERE fill_siren ON CONFLICT DO NOTHING
    )
    INSERT INTO cards_customer_nature_initialized (card_id)
    SELECT id FROM updated WHERE set_nature ON CONFLICT DO NOTHING
    SQL

  BACKWARD = <<-SQL
    UPDATE cards_card
       SET customer_nature = CASE WHEN id IN (SELECT card_id FROM cards_customer_nature_initialized)
                                  THEN '' ELSE customer_nature END,
           siren = CASE WHEN id IN (SELECT card_id FROM cards_customer_siren_filled) THEN '' ELSE siren END
     WHERE id IN (SELECT card_id FROM cards_customer_nature_initialized
                  UNION SELECT card_id FROM cards_customer_siren_filled)
    SQL

  def plan
    execute(
      "CREATE TABLE cards_customer_nature_initialized (card_id bigint PRIMARY KEY)",
      "DROP TABLE IF EXISTS cards_customer_nature_initialized"
    )
    execute(
      "CREATE TABLE cards_customer_siren_filled (card_id bigint PRIMARY KEY)",
      "DROP TABLE IF EXISTS cards_customer_siren_filled"
    )
    execute(FORWARD, BACKWARD)
  end
end
