# SPDX-License-Identifier: AGPL-3.0-or-later

Partiduo::Modules.register do
  code "ACCOUNTING"
  name "accounting.module.name"
  version Partiduo::VERSION
  kind Partiduo::Modules::Kind::Module
  permission "accounting.entry.read"
  permission "accounting.entry.post"
end
