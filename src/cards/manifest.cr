# SPDX-License-Identifier: AGPL-3.0-or-later

# Fiches : tiers, articles et services (socle, ADR-006 D1).
Partiduo::Modules.register do
  code "CARDS"
  name "cards.module.name"
  version Partiduo::VERSION
  kind Partiduo::Modules::Kind::Socle

  permission "cards.card.read"
  permission "cards.card.write"
  # NOALYSS FICCAT : création, modification et effacement de catégorie de fiche.
  permission "cards.category.manage"

  menu "CARDS_LIST", parent: "REFERENCE", order: 20, route: "cards:index", permission: "cards.card.read"
  menu "CARDS_CATEGORIES", parent: "SETTINGS", order: 50, route: "cards:categories", permission: "cards.category.manage"
end
