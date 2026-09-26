# SPDX-License-Identifier: AGPL-3.0-or-later

Partiduo::Modules.register do
  code "VAT"
  name "vat.module.name"
  version Partiduo::VERSION
  kind Partiduo::Modules::Kind::Socle
  permission "vat.rate.read"
  permission "vat.rate.write"
end
