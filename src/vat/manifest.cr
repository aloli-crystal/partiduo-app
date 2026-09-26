# SPDX-License-Identifier: AGPL-3.0-or-later

# Taux et régimes de TVA (socle, ADR-006 D1) ; les déclarations relèvent de
# la Comptabilité.
Partiduo::Modules.register do
  code "VAT"
  name "vat.module.name"
  version Partiduo::VERSION
  kind Partiduo::Modules::Kind::Socle

  permission "vat.rate.read"
  permission "vat.rate.write"

  menu "VAT_RATES", parent: "REFERENCE", order: 40, route: "vat:rates", permission: "vat.rate.read"
end
