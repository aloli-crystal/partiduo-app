# SPDX-License-Identifier: AGPL-3.0-or-later

Partiduo::Modules.register do
  code "CORE"
  name "core.module.name"
  version Partiduo::VERSION
  kind Partiduo::Modules::Kind::Socle
  permission "core.settings.manage"
  permission "core.users.manage"
  permission "core.modules.manage"
end
