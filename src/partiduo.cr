# SPDX-License-Identifier: AGPL-3.0-or-later

# Point d'entrée du shard `partiduo` : le socle, les modules et le contrat
# `Partiduo::Api`, sans aucune interface (ADR-005 D1).
#
# Un dépôt d'interface ou une extension fait `require "partiduo"`, puis
# `Partiduo.apply_settings(config)` dans sa configuration Marten.

require "big"
require "marten"
require "marten_auth"
require "pg"

require "./partiduo/version"
require "./partiduo/config"
require "./partiduo/api/**"

# Applications Marten, dans l'ordre de l'ADR-001 § Organisation du code.
require "./modules/app"
require "./auth/app"
require "./core/app"
require "./cards/app"
require "./vat/app"
require "./accounting/app"
require "./invoicing/app"
require "./analytic/app"

require "./partiduo/settings"
