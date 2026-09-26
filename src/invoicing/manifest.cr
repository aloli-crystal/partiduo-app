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
  permission "invoicing.credit_note.issue"
  permission "invoicing.payment.record"
  permission "invoicing.reminder.send"
  permission "invoicing.template.manage"
  # Transmission au comptable (ADR-006 D4).
  permission "invoicing.export.read"

  menu "INV_DOCUMENTS", parent: "BILLING", order: 10, route: "invoicing:documents", permission: "invoicing.invoice.read"
  menu "INV_NEW_INVOICE", parent: "BILLING", order: 20, route: "invoicing:invoice_new", permission: "invoicing.invoice.write"
  menu "INV_PAYMENTS", parent: "BILLING", order: 30, route: "invoicing:payments", permission: "invoicing.payment.record"
  menu "INV_REMINDERS", parent: "BILLING", order: 40, route: "invoicing:reminders", permission: "invoicing.reminder.send"
  menu "INV_EXPORT", parent: "BILLING", order: 50, route: "invoicing:export", permission: "invoicing.export.read"
  menu "INV_TEMPLATES", parent: "SETTINGS", order: 60, route: "invoicing:templates", permission: "invoicing.template.manage"
end
