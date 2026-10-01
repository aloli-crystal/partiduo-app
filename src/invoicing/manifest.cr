# SPDX-License-Identifier: AGPL-3.0-or-later

# Module Facturation (ADR-006 D1, D5) : devis, commandes, bons de livraison,
# factures, acomptes, avoirs, règlements, relances, modèles, envoi.
Partiduo::Modules.register do
  code "INVOICING"
  name "invoicing.module.name"
  version Partiduo::VERSION
  kind Partiduo::Modules::Kind::Module

  permission "invoicing.invoice.read"
  permission "invoicing.invoice.write"
  permission "invoicing.invoice.issue"
  permission "invoicing.invoice.send"
  permission "invoicing.credit_note.issue"
  permission "invoicing.payment.record"
  permission "invoicing.reminder.send"
  permission "invoicing.template.manage"
  permission "invoicing.settings.manage"
  # Transmission au comptable (ADR-006 D4).
  permission "invoicing.export.read"
  # Dérogation à l'encours maximum HT d'un client, motif obligatoire
  # (DECISIONS D-INV2-009).
  permission "invoicing.credit_limit.override"

  menu "INV_DOCUMENTS", parent: "BILLING", order: 10, route: "invoicing:documents", permission: "invoicing.invoice.read"
  # Bons de livraison émis non facturés, facture récapitulative, fin de mois
  # (DECISIONS D-INV2-010).
  menu "INV_TO_INVOICE", parent: "BILLING", order: 15, route: "invoicing:to_invoice", permission: "invoicing.invoice.read"
  menu "INV_NEW_INVOICE", parent: "BILLING", order: 20, route: "invoicing:invoice_new", permission: "invoicing.invoice.write"
  menu "INV_PAYMENTS", parent: "BILLING", order: 30, route: "invoicing:payments", permission: "invoicing.payment.record"
  menu "INV_REMINDERS", parent: "BILLING", order: 40, route: "invoicing:reminders", permission: "invoicing.reminder.send"
  menu "INV_EXPORT", parent: "BILLING", order: 50, route: "invoicing:export", permission: "invoicing.export.read"
  # Lettrage d'un encaissement par la Comptabilité (ADR-006 D3) : facture
  # payée ou partiellement payée (`Partiduo::Invoicing::Payments.on_matched`).
  on("payment.matched") { |event| Partiduo::Invoicing::Payments.on_matched(event) }
  # Délettrage, ou extourne d'une écriture lettrée : règlements retirés
  # (`Partiduo::Invoicing::Payments.on_unmatched`, D-2F-003).
  on("payment.unmatched") { |event| Partiduo::Invoicing::Payments.on_unmatched(event) }
  # Dépôt réussi sur la plateforme agréée (publié par `partiduo-einvoicing`) :
  # document marqué envoyé, copie PDF envoyée après la validation si elle est
  # prévue (`Partiduo::Invoicing::PdfCopy.on_platform_deposited`, ADR-004 D9
  # révisé, D-CPY-001).
  on("invoice.platform_deposited") { |event| Partiduo::Invoicing::PdfCopy.on_platform_deposited(event) }

  menu "INV_TEMPLATES", parent: "SETTINGS", order: 60, route: "invoicing:templates", permission: "invoicing.template.manage"
  menu "INV_SETTINGS", parent: "SETTINGS", order: 61, route: "invoicing:settings", permission: "invoicing.settings.manage"
end
