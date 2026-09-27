# SPDX-License-Identifier: AGPL-3.0-or-later

# Jeu de données initial du module Comptabilité (convention C6, D-SET-005) :
# plan comptable du régime, comptes par défaut, comptes de base des catégories
# de fiches (après leur création par `CARDS.categories`, ordre 12), journaux
# par défaut. Exécuté par `Partiduo::Api::Core.provision` si le module est actif.
Partiduo::Api::InitialData.register("ACCOUNTING", "reference_data", order: 20) do |context|
  result = Partiduo::Api::Accounting.load_initial_data(context.actor, context.tax_regime, context.locale)
  raise ArgumentError.new("données initiales comptables refusées : #{result.error_keys.join(", ")}") if result.failure?
end
