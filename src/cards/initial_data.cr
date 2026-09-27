# SPDX-License-Identifier: AGPL-3.0-or-later

# Jeu de données initial des fiches (convention C6) : catégories par défaut,
# après les taux de TVA. La Comptabilité, qui y rattache ses comptes de base
# (`fd_class_base`), passe après (ordre supérieur à 12).
Partiduo::Api::InitialData.register("CARDS", "categories", order: 12) do |context|
  Partiduo::Api::Cards.load_default_categories(context.actor, context.locale)
end
