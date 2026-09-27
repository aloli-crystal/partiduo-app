# SPDX-License-Identifier: AGPL-3.0-or-later

# Socle (ADR-006 D1). Déclare aussi les rubriques de premier niveau du menu
# (ADR-005 § Structure d'écran), auxquelles les modules et extensions
# rattachent leurs entrées ; une rubrique sans entrée visible est omise.
Partiduo::Modules.register do
  code "CORE"
  name "core.module.name"
  version Partiduo::VERSION
  kind Partiduo::Modules::Kind::Socle

  permission "core.settings.manage"
  permission "core.users.manage"
  permission "core.modules.manage"
  # Lot 1 : exercices et périodes, devises, pièces jointes. Pas de suffixe
  # `.manage` : ces droits ne sont pas administratifs, le rôle comptable les
  # garde (Partiduo::Auth::Permissions.administrative?).
  permission "core.fiscal_year.write"
  permission "core.period.close"
  permission "core.period.reopen"
  permission "core.currency.write"
  permission "core.attachment.read"
  permission "core.attachment.write"

  menu "DASHBOARD", order: 10, route: "core:dashboard"
  menu "BILLING", order: 20
  # Suivi des actions et relations (module FOLLOWUP, lot 6, D-FUP-001).
  menu "FOLLOW_UP", order: 25
  menu "ENTRY", order: 30
  menu "CONSULT", order: 40
  menu "REFERENCE", order: 50
  menu "REPORTS", order: 60
  menu "VAT", order: 70
  menu "ANALYTIC", order: 80
  menu "SETTINGS", order: 90
  menu "EXTENSION", order: 100

  menu "CORE_COMPANY", parent: "SETTINGS", order: 10, route: "core:company", permission: "core.settings.manage"
  menu "CORE_FISCAL_YEARS", parent: "SETTINGS", order: 20, route: "core:fiscal_years", permission: "core.fiscal_year.write"
  menu "CORE_USERS", parent: "SETTINGS", order: 30, route: "core:users", permission: "core.users.manage"
  menu "CORE_MODULES", parent: "SETTINGS", order: 40, route: "core:modules", permission: "core.modules.manage"
  menu "CORE_CURRENCIES", parent: "SETTINGS", order: 25, route: "core:currencies", permission: "core.currency.write"
end
