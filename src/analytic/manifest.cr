# SPDX-License-Identifier: AGPL-3.0-or-later

# Module Analytique (ADR-006 D1) : plans, postes, ventilations. Requiert la
# Comptabilité.
Partiduo::Modules.register do
  code "ANALYTIC"
  name "analytic.module.name"
  version Partiduo::VERSION
  kind Partiduo::Modules::Kind::Module
  depends_on "ACCOUNTING"

  permission "analytic.plan.read"
  permission "analytic.plan.write"
  permission "analytic.report.read"

  menu "ANA_PLANS", parent: "ANALYTIC", order: 10, route: "analytic:plans", permission: "analytic.plan.read"
  menu "ANA_REPORTS", parent: "ANALYTIC", order: 20, route: "analytic:reports", permission: "analytic.report.read"
end
