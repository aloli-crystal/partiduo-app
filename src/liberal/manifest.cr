# SPDX-License-Identifier: AGPL-3.0-or-later

# Module des professions libérales au régime de la déclaration contrôlée
# (ADR-007 D6) : comptabilité de trésorerie, livre-journal des recettes et des
# dépenses professionnelles ventilées par rubrique de la 2035-A, registre des
# immobilisations et amortissements linéaires, préparation de la 2035, de la
# 2035-A et de la 2035-B. Ne dépend que du socle ; alimenté par les
# événements de la Facturation quand elle est active, comptabilisé par la
# Comptabilité quand elle l'est (ADR-006 D3 : aucun appel direct).
Partiduo::Modules.register do
  code "LIBERAL"
  name "liberal.module.name"
  version Partiduo::VERSION
  kind Partiduo::Modules::Kind::Module

  # Consultation et éditions du livre-journal, des immobilisations, de la 2035.
  permission "liberal.register.read"
  # Saisie et contre-passation, immobilisations et cessions, réintégrations
  # et déductions de l'année.
  permission "liberal.register.write"
  # Paramètres, natures, table de correspondance des lignes de la 2035.
  permission "liberal.settings.write"

  menu "LIBERAL_JOURNAL", parent: "ENTRY", order: 3, route: "liberal:journal", permission: "liberal.register.read"
  menu "LIBERAL_ASSETS", parent: "ENTRY", order: 4, route: "liberal:assets", permission: "liberal.register.read"
  menu "LIBERAL_TAX_RETURN", parent: "REPORTS", order: 4, route: "liberal:tax_return", permission: "liberal.register.read"
  menu "LIBERAL_SETTINGS", parent: "SETTINGS", order: 71, route: "liberal:settings", permission: "liberal.settings.write"

  # Une facture encaissée devient une recette (ADR-007 D6) ; un lettrage
  # défait contre-passe la recette. Un échec ne bloque jamais l'opération
  # d'origine.
  on("invoice.issued") { |event| Partiduo::Liberal::Feeds.on_event(event) }
  on("payment.recorded") { |event| Partiduo::Liberal::Feeds.on_event(event) }
  on("payment.matched") { |event| Partiduo::Liberal::Feeds.on_event(event) }
  on("payment.unmatched") { |event| Partiduo::Liberal::Feeds.on_event(event) }
end
