# SPDX-License-Identifier: AGPL-3.0-or-later

# Module Analytique (ADR-006 D1) : plans, postes, groupes, clés de
# répartition, ventilations et éditions. Requiert la Comptabilité.
Partiduo::Modules.register do
  code "ANALYTIC"
  name "analytic.module.name"
  version Partiduo::VERSION
  kind Partiduo::Modules::Kind::Module
  depends_on "ACCOUNTING"

  permission "analytic.plan.read"
  permission "analytic.plan.write"
  # Ventilation des lignes d'écriture et opérations diverses analytiques
  # (lot 5, D-ANA-001).
  permission "analytic.operation.write"
  permission "analytic.report.read"

  menu "ANA_PLANS", parent: "ANALYTIC", order: 10, route: "analytic:plans", permission: "analytic.plan.read"
  menu "ANA_KEYS", parent: "ANALYTIC", order: 12, route: "analytic:keys", permission: "analytic.plan.read"
  menu "ANA_MISC", parent: "ANALYTIC", order: 15, route: "analytic:misc_operations", permission: "analytic.operation.write"
  menu "ANA_REPORTS", parent: "ANALYTIC", order: 20, route: "analytic:reports", permission: "analytic.report.read"
  menu "ANA_SETTINGS", parent: "ANALYTIC", order: 30, route: "analytic:settings", permission: "analytic.plan.write"

  # Extourne d'une écriture ventilée : l'extourne reçoit la ventilation
  # inverse (`Acc_Ledger::reverse`, D-ANA-006).
  on("entry.cancelled") { |event| Partiduo::Analytic::Distributions.on_entry_cancelled(event) }
end
