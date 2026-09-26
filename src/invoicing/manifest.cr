# SPDX-License-Identifier: AGPL-3.0-or-later

Partiduo::Modules.register do
  code "INVOICING"
  name "invoicing.module.name"
  version Partiduo::VERSION
  kind Partiduo::Modules::Kind::Module
  permission "invoicing.invoice.read"
  permission "invoicing.invoice.write"
  permission "invoicing.invoice.issue"
end
