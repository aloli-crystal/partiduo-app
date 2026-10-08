# SPDX-License-Identifier: AGPL-3.0-or-later

# Module micro-entreprise (ADR-007 D1, D2) : livre des recettes, registre
# des achats, aide à la déclaration URSSAF, montants de la 2042-C-PRO, suivi
# des seuils. Ne dépend que du socle ; alimenté par les événements de la
# Facturation quand elle est active, comptabilisé par la Comptabilité quand
# elle l'est (ADR-006 D3 : aucun appel direct).
Partiduo::Modules.register do
  code "MICRO"
  name "micro.module.name"
  version Partiduo::VERSION
  kind Partiduo::Modules::Kind::Module

  # Consultation et éditions des registres, URSSAF, 2042-C-PRO, seuils.
  permission "micro.register.read"
  # Saisie, modification et suppression en période ouverte,
  # contre-passation, déclaration URSSAF notée.
  permission "micro.register.write"
  # Paramètres, natures, taux et seuils datés, bascules.
  permission "micro.settings.write"

  menu "MICRO_RECEIPTS", parent: "ENTRY", order: 1, route: "micro:receipts", permission: "micro.register.read"
  menu "MICRO_PURCHASES", parent: "ENTRY", order: 2, route: "micro:purchases", permission: "micro.register.read"
  menu "MICRO_URSSAF", parent: "REPORTS", order: 1, route: "micro:urssaf", permission: "micro.register.read"
  menu "MICRO_TAX_RETURN", parent: "REPORTS", order: 2, route: "micro:tax_return", permission: "micro.register.read"
  menu "MICRO_THRESHOLDS", parent: "REPORTS", order: 3, route: "micro:thresholds", permission: "micro.register.read"
  menu "MICRO_SETTINGS", parent: "SETTINGS", order: 70, route: "micro:settings", permission: "micro.settings.write"

  # Une facture encaissée devient une recette (ADR-007 D1) ; un lettrage
  # défait contre-passe la recette. Un échec ne bloque jamais l'opération
  # d'origine.
  on("invoice.issued") { |event| Partiduo::Micro::Feeds.on_event(event) }
  on("payment.recorded") { |event| Partiduo::Micro::Feeds.on_event(event) }
  on("payment.matched") { |event| Partiduo::Micro::Feeds.on_event(event) }
  on("payment.unmatched") { |event| Partiduo::Micro::Feeds.on_event(event) }
  # Règlement saisi rejeté (D-INV3-008) : recette contre-passée.
  on("payment.rejected") { |event| Partiduo::Micro::Feeds.on_event(event) }
end
