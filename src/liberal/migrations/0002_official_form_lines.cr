# SPDX-License-Identifier: AGPL-3.0-or-later

# Lignes et cases de la 2035 vérifiées le 29 septembre 2026 (DECISIONS
# D-VAL-006 à D-VAL-009, `doc/sources-officielles.adoc`) : les instances déjà
# provisionnées reçoivent la table corrigée du jeu de données initial
# (`data/defaults.yml`), seulement pour les postes restés à la ligne livrée
# (une ligne changée par l'administrateur n'est pas touchée) :
#
# * si le millésime 2024 n'est pas figé (aucune période close en 2024 ou
#   après, D-LIB-010), ses lignes sont corrigées et les sous-totaux ajoutés ;
# * s'il est figé mais pas 2025, les lignes corrigées sont ajoutées au
#   millésime 2025 (les 2035 déjà déposées gardent leurs cases) ;
# * si 2025 est figé aussi, rien : l'administrateur corrige par
#   `set_form_line` au premier millésime ouvert.
#
# Une instance sans table (module jamais activé) n'est pas touchée : le jeu
# de données initial la remplira. Non réversible : le retour ne rétablit pas
# les anciennes cases, qui étaient fausses.
class Migration::Liberal::V0002 < Marten::Migration
  depends_on :liberal, "0001_liberal"
  depends_on :core, "0003_period_guard_fiscal_year_move"

  CHANGES = <<-SQL
    changes (item, old_form, old_line, old_box, new_form, new_line, new_box) AS (VALUES
      ('assets_cost', '2035-B', 'I', 'DA', '2035-A', '', 'GJ'),
      ('cet', '2035-A', '12', 'JY', '2035-A', '12', 'BE'),
      ('maintenance', '2035-A', '17', 'BH', '2035-A', '17', 'EB'),
      ('temporary_staff', '2035-A', '18', 'BJ', '2035-A', '18', 'EC'),
      ('small_tools', '2035-A', '19', 'BK', '2035-A', '19', 'ED'),
      ('utilities', '2035-A', '20', 'BL', '2035-A', '20', 'EE'),
      ('fees', '2035-A', '21', 'BM', '2035-A', '21', 'EF'),
      ('insurance', '2035-A', '22', 'BN', '2035-A', '22', 'EG'),
      ('works_total', NULL, NULL, NULL, '2035-A', '17 à 22', 'BH'),
      ('vehicle', '2035-A', '23', 'BP', '2035-A', '23', 'GF'),
      ('travel', '2035-A', '24', 'BQ', '2035-A', '24', 'EJ'),
      ('transport_total', NULL, NULL, NULL, '2035-A', '23 et 24', 'BJ'),
      ('personal_social_total', NULL, NULL, NULL, '2035-A', '25', 'BK'),
      ('reception', '2035-A', '26', 'BW', '2035-A', '26', 'BL'),
      ('office', '2035-A', '27', 'BX', '2035-A', '27', 'EK'),
      ('legal_costs', '2035-A', '28', 'BY', '2035-A', '28', 'EL'),
      ('professional_dues', '2035-A', '29', 'BZ', '2035-A', '29', 'EM'),
      ('other_management', '2035-A', '30', 'CB', '2035-A', '30', 'EN'),
      ('management_total', NULL, NULL, NULL, '2035-A', '27 à 30', 'BM'),
      ('financial_costs', '2035-A', '31', 'CC', '2035-A', '31', 'BN'),
      ('other_losses', '2035-A', '32', 'CD', '2035-A', '32', 'BP'),
      ('excess', '2035-A', '34', 'CE', '2035-B', '34', 'CA'),
      ('short_term_gains', '2035-A', '35', 'CF', '2035-B', '35', 'CB'),
      ('reintegrations', '2035-A', '36', 'CG', '2035-B', '36', 'CC'),
      ('scm_profit', '2035-A', '37', 'CL', '2035-B', '37', 'CD'),
      ('total_additions', '2035-A', '38', 'CM', '2035-B', '38', 'CE'),
      ('shortfall', '2035-A', '39', 'CN', '2035-B', '39', 'CF'),
      ('establishment_costs', '2035-A', '40', 'CP', '2035-B', '40', 'CG'),
      ('depreciation', '2035-A', '41', 'CH', '2035-B', '41', 'CH'),
      ('short_term_losses', '2035-A', '43', 'CR', '2035-B', '42', 'CK'),
      ('deductions', '2035-A', '44', 'CS', '2035-B', '43', 'CL'),
      ('provision', '2035-A', '42', 'CK', '2035-B', '43', ''),
      ('scm_loss', '2035-A', '45', 'CT', '2035-B', '44', 'CM'),
      ('total_subtractions', '2035-A', '46', 'CU', '2035-B', '45', 'CN'),
      ('profit', '2035-A', '47', 'CP1', '2035-B', '46', 'CP'),
      ('loss', '2035-A', '48', 'CR1', '2035-B', '47', 'CR'),
      ('long_term_gains', '2035-B', 'III', 'DE', '2035', '2', 'FJ'),
      ('assets_prior_depreciation', '2035-B', 'I', 'DB', '2035', 'I', ''),
      ('assets_year_depreciation', '2035-B', 'I', 'DC', '2035', 'I', ''),
      ('disposals_price', '2035-B', 'III', 'DD', '2035', 'II', ''),
      ('long_term_losses', '2035-B', 'III', 'DF', '2035', 'II', '')
    ),
    frozen AS (
      SELECT coalesce(max(extract(year FROM ends_on))::int, 0) AS through
        FROM core_period WHERE closed_at IS NOT NULL
    ),
    target AS (
      SELECT CASE WHEN through < 2024 THEN 2024 WHEN through < 2025 THEN 2025 END AS millesime
        FROM frozen
       WHERE EXISTS (SELECT 1 FROM liberal_form_line WHERE millesime = 2024 AND item = 'receipts')
    )
    SQL

  UPDATE = <<-SQL
    WITH #{CHANGES}
    UPDATE liberal_form_line fl
       SET form = changes.new_form, line = changes.new_line, box = changes.new_box, updated_at = now()
      FROM changes, target
     WHERE target.millesime = 2024 AND fl.millesime = 2024 AND fl.item = changes.item
       AND fl.form = changes.old_form AND fl.line = changes.old_line AND fl.box = changes.old_box
    SQL

  INSERT = <<-SQL
    WITH #{CHANGES}
    INSERT INTO liberal_form_line (millesime, item, form, line, box, created_at, updated_at)
    SELECT target.millesime, changes.item, changes.new_form, changes.new_line, changes.new_box, now(), now()
      FROM changes, target
     WHERE target.millesime IS NOT NULL
       AND ((changes.old_form IS NULL
             AND NOT EXISTS (SELECT 1 FROM liberal_form_line fl WHERE fl.item = changes.item))
         OR (target.millesime = 2025
             AND EXISTS (SELECT 1 FROM liberal_form_line fl
                          WHERE fl.item = changes.item AND fl.millesime = 2024 AND fl.form = changes.old_form
                            AND fl.line = changes.old_line AND fl.box = changes.old_box)
             AND NOT EXISTS (SELECT 1 FROM liberal_form_line fl
                              WHERE fl.item = changes.item AND fl.millesime > 2024)))
    ON CONFLICT DO NOTHING
    SQL

  def plan
    execute(UPDATE, "SELECT 1")
    execute(INSERT, "SELECT 1")
  end
end
