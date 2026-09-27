# SPDX-License-Identifier: AGPL-3.0-or-later

# Jeu de données initial de la TVA (convention C6) : les taux du régime du
# dossier, avant les catégories de fiches (qui peuvent citer un taux par
# défaut) et avant la Comptabilité (qui y rattache ses comptes de TVA).
Partiduo::Api::InitialData.register("VAT", "rates", order: 8) do |context|
  Partiduo::Api::Vat.load_rates(context.actor, context.tax_regime, context.locale)
end
