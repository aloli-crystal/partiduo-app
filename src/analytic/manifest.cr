# SPDX-License-Identifier: AGPL-3.0-or-later

Partiduo::Modules.register do
  code "ANALYTIC"
  name "analytic.module.name"
  version Partiduo::VERSION
  kind Partiduo::Modules::Kind::Module
  depends_on "ACCOUNTING"
  permission "analytic.plan.read"
  permission "analytic.plan.write"
end
