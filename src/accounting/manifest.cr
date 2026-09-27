# SPDX-License-Identifier: AGPL-3.0-or-later

# Module Comptabilité (ADR-006 D1) : plan comptable, journaux, écritures,
# lettrage, rapprochement, éditions, déclarations de TVA, FEC, clôture.
Partiduo::Modules.register do
  code "ACCOUNTING"
  name "accounting.module.name"
  version Partiduo::VERSION
  kind Partiduo::Modules::Kind::Module

  permission "accounting.entry.read"
  permission "accounting.entry.post"
  # Annulation par extourne (NOALYSS RMOPER : effacer une opération).
  permission "accounting.entry.cancel"
  permission "accounting.account.read"
  permission "accounting.account.write"
  permission "accounting.ledger.read"
  permission "accounting.ledger.write"
  permission "accounting.matching.write"
  permission "accounting.report.read"
  # Rapports personnalisés (`formulaire`, `form_definition`).
  permission "accounting.report.write"
  permission "accounting.vat.declare"
  permission "accounting.period.close"

  menu "ACC_ENTRY_PURCHASE", parent: "ENTRY", order: 10, route: "accounting:entry_purchase", permission: "accounting.entry.post"
  # Facture d'achat papier ou PDF simple, avec sa pièce jointe (ADR-004 D9).
  menu "ACC_ENTRY_RECEIVED", parent: "ENTRY", order: 15, route: "accounting:entry_received", permission: "accounting.entry.post"
  menu "ACC_ENTRY_SALE", parent: "ENTRY", order: 20, route: "accounting:entry_sale", permission: "accounting.entry.post"
  menu "ACC_ENTRY_FINANCIAL", parent: "ENTRY", order: 30, route: "accounting:entry_financial", permission: "accounting.entry.post"
  menu "ACC_ENTRY_MISC", parent: "ENTRY", order: 40, route: "accounting:entry_misc", permission: "accounting.entry.post"
  # Factures, avoirs et règlements de la Facturation sans écriture (ADR-006 D2).
  menu "ACC_INVOICING_HISTORY", parent: "ENTRY", order: 50, route: "accounting:invoicing_history", permission: "accounting.entry.post"

  menu "ACC_ACCOUNTS", parent: "CONSULT", order: 10, route: "accounting:accounts", permission: "accounting.entry.read"
  menu "ACC_ENTRIES", parent: "CONSULT", order: 20, route: "accounting:entries", permission: "accounting.entry.read"
  menu "ACC_MATCHING", parent: "CONSULT", order: 30, route: "accounting:matching", permission: "accounting.matching.write"
  # Rapprochement bancaire (`compta_fin_rec.inc.php`, D-REC-001).
  menu "ACC_RECONCILIATION", parent: "CONSULT", order: 35, route: "accounting:reconciliation", permission: "accounting.matching.write"

  menu "ACC_CHART", parent: "REFERENCE", order: 10, route: "accounting:chart", permission: "accounting.account.read"
  menu "ACC_LEDGERS", parent: "REFERENCE", order: 30, route: "accounting:ledgers", permission: "accounting.ledger.read"

  menu "ACC_TRIAL_BALANCE", parent: "REPORTS", order: 10, route: "accounting:trial_balance", permission: "accounting.report.read"
  menu "ACC_GENERAL_LEDGER", parent: "REPORTS", order: 20, route: "accounting:general_ledger", permission: "accounting.report.read"
  menu "ACC_FEC", parent: "REPORTS", order: 30, route: "accounting:fec", permission: "accounting.report.read"
  menu "ACC_AUXILIARY_BALANCE", parent: "REPORTS", order: 12, route: "accounting:auxiliary_balance", permission: "accounting.report.read"
  menu "ACC_AGED_BALANCE", parent: "REPORTS", order: 14, route: "accounting:aged_balance", permission: "accounting.report.read"
  menu "ACC_JOURNALS", parent: "REPORTS", order: 25, route: "accounting:journals", permission: "accounting.report.read"
  menu "ACC_BALANCE_SHEET", parent: "REPORTS", order: 26, route: "accounting:balance_sheet", permission: "accounting.report.read"
  menu "ACC_INCOME_STATEMENT", parent: "REPORTS", order: 27, route: "accounting:income_statement", permission: "accounting.report.read"
  menu "ACC_REPORTS", parent: "REPORTS", order: 28, route: "accounting:reports", permission: "accounting.report.read"
  # Prévisions budgétaires (`forecast`, lot 6, D-FCT-001).
  menu "ACC_FORECASTS", parent: "REPORTS", order: 29, route: "accounting:forecasts", permission: "accounting.report.read"

  menu "ACC_VAT_RETURN", parent: "VAT", order: 10, route: "accounting:vat_return", permission: "accounting.vat.declare"
  # Historique et paramètres des déclarations (proposition D-UI-040, adoptée au lot 4).
  menu "ACC_VAT_RETURNS", parent: "VAT", order: 20, route: "accounting:vat_returns", permission: "accounting.vat.declare"
  menu "ACC_VAT_SETTINGS", parent: "VAT", order: 30, route: "accounting:vat_settings", permission: "accounting.vat.declare"

  menu "ACC_CLOSING", parent: "SETTINGS", order: 25, route: "accounting:closing", permission: "accounting.period.close"

  # Une fiche neuve reçoit le compte que prévoit sa catégorie (D-ACC-006).
  on("card.saved") { |event| Partiduo::Accounting::CardAccounts.on_card_saved(event["card_id"].to_i64) }

  # Écritures issues de la Facturation (ADR-006 D3, D-INT-001) : vente,
  # avoir lettré avec sa facture, encaissement. Un échec ne bloque pas la
  # Facturation : l'événement reste dans l'historique à comptabiliser.
  on("invoice.issued") { |event| Partiduo::Accounting::Billing.on_event(event) }
  on("credit_note.issued") { |event| Partiduo::Accounting::Billing.on_event(event) }
  on("payment.recorded") { |event| Partiduo::Accounting::Billing.on_event(event) }

  # Écritures des registres de la micro-entreprise (ADR-007 D2) : trésorerie
  # et contrepartie selon le paramétrage par nature ; un échec ne bloque pas
  # le registre, qui peut republier ses lignes.
  on("micro.receipt.recorded") { |event| Partiduo::Accounting::MicroEntries.on_event(event) }
  on("micro.purchase.recorded") { |event| Partiduo::Accounting::MicroEntries.on_event(event) }
end
