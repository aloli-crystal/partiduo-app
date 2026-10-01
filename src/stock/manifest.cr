# SPDX-License-Identifier: AGPL-3.0-or-later

# Module Stock (ADR-006 D1, lot 6) : dépôts, mouvements, inventaire,
# valorisation. Requiert la Facturation ou la Comptabilité : les mouvements
# naissent des bons de livraison, des factures et des avoirs émis, ou des
# factures d'achat et de vente saisies en comptabilité (D-STK-004).
Partiduo::Modules.register do
  code "STOCK"
  name "stock.module.name"
  version Partiduo::VERSION
  kind Partiduo::Modules::Kind::Module
  depends_on_any "INVOICING", "ACCOUNTING"

  # Consultation : dépôts, articles suivis, historique, état, valorisation.
  permission "stock.movement.read"
  # Opérations manuelles et inventaires (`stock_change`).
  permission "stock.movement.write"
  # Dépôts, articles suivis, dépôt par défaut.
  permission "stock.settings.write"

  menu "STOCK_CHANGES", parent: "ENTRY", order: 60, route: "stock:changes", permission: "stock.movement.write"
  menu "STOCK_INVENTORY", parent: "ENTRY", order: 65, route: "stock:inventory", permission: "stock.movement.write"
  menu "STOCK_STATE", parent: "CONSULT", order: 50, route: "stock:state", permission: "stock.movement.read"
  menu "STOCK_HISTORY", parent: "CONSULT", order: 55, route: "stock:history", permission: "stock.movement.read"
  menu "STOCK_VALUATION", parent: "REPORTS", order: 50, route: "stock:valuation", permission: "stock.movement.read"
  menu "STOCK_REPOSITORIES", parent: "REFERENCE", order: 60, route: "stock:repositories", permission: "stock.settings.write"
  menu "STOCK_ITEMS", parent: "REFERENCE", order: 65, route: "stock:items", permission: "stock.settings.write"

  # Mouvements automatiques (D-STK-004) ; un échec est consigné et ne bloque
  # jamais l'opération d'origine.
  on("delivery_note.issued") { |event| Partiduo::Stock::Feeds.on_event(event) }
  on("invoice.issued") { |event| Partiduo::Stock::Feeds.on_event(event) }
  on("credit_note.issued") { |event| Partiduo::Stock::Feeds.on_event(event) }
  # Bon de retour émis : entrée en stock (D-INV3-002).
  on("return_note.issued") { |event| Partiduo::Stock::Feeds.on_event(event) }
  on("entry.posted") { |event| Partiduo::Stock::Feeds.on_event(event) }
end
