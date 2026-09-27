# SPDX-License-Identifier: AGPL-3.0-or-later

# Module Suivi (lot 6, D-FUP-001) : actions de suivi et relations avec les
# tiers (`follow_up`, `action_gestion` de NOALYSS), hors GED (extension
# `partiduo-document`). Ne dépend que du socle.
Partiduo::Modules.register do
  code "FOLLOWUP"
  name "followup.module.name"
  version Partiduo::VERSION
  kind Partiduo::Modules::Kind::Module

  permission "followup.action.read"
  permission "followup.action.write"
  # Types d'action et étiquettes (`cfg_action`, `tag`).
  permission "followup.settings.write"

  menu "FUP_ACTIONS", parent: "FOLLOW_UP", order: 10, route: "followup:actions", permission: "followup.action.read"
  menu "FUP_REMINDERS", parent: "FOLLOW_UP", order: 20, route: "followup:reminders", permission: "followup.action.read"
  menu "FUP_TYPES", parent: "FOLLOW_UP", order: 30, route: "followup:types", permission: "followup.settings.write"
  menu "FUP_TAGS", parent: "FOLLOW_UP", order: 40, route: "followup:tags", permission: "followup.settings.write"
end
