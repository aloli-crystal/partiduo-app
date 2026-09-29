# SPDX-License-Identifier: AGPL-3.0-or-later

# Valeurs officielles vérifiées le 29 septembre 2026 (DECISIONS D-VAL-001,
# `doc/sources-officielles.adoc`) : les instances déjà provisionnées
# reçoivent les corrections du jeu de données initial, seulement pour les
# lignes restées à la valeur livrée (une valeur changée par l'administrateur
# n'est pas touchée) :
#
# * taux global BNC du régime général au 1er janvier 2026 : 25,6 % (art.
#   D613-4 du code de la sécurité sociale, décret n° 2025-943) au lieu de
#   26,1 % ;
# * taux des prestations de services BIC : en vigueur depuis le 1er janvier
#   2024 (21,2 % depuis décembre 2022) et non depuis le 1er juillet 2024.
#
# Retour : les valeurs livrées auparavant sont rétablies, aux mêmes
# conditions.
class Migration::Micro::V0002 < Marten::Migration
  depends_on :micro, "0001_micro"

  def plan
    execute(<<-SQL, <<-SQL)
      UPDATE micro_parameter SET value = 25.6, updated_at = now()
       WHERE code = 'rate.social.bnc' AND valid_from = DATE '2026-01-01' AND value = 26.1
      SQL
      UPDATE micro_parameter SET value = 26.1, updated_at = now()
       WHERE code = 'rate.social.bnc' AND valid_from = DATE '2026-01-01' AND value = 25.6
      SQL
    execute(<<-SQL, <<-SQL)
      UPDATE micro_parameter SET valid_from = DATE '2024-01-01', updated_at = now()
       WHERE code = 'rate.social.service_bic' AND valid_from = DATE '2024-07-01' AND value = 21.2
         AND NOT EXISTS (SELECT 1 FROM micro_parameter other
                          WHERE other.code = 'rate.social.service_bic' AND other.valid_from = DATE '2024-01-01')
      SQL
      UPDATE micro_parameter SET valid_from = DATE '2024-07-01', updated_at = now()
       WHERE code = 'rate.social.service_bic' AND valid_from = DATE '2024-01-01' AND value = 21.2
         AND NOT EXISTS (SELECT 1 FROM micro_parameter other
                          WHERE other.code = 'rate.social.service_bic' AND other.valid_from = DATE '2024-07-01')
      SQL
  end
end
