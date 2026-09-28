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
# Lecture des colonnes `numeric` en BigDecimal (Marten ne la charge que si
# `pg` est requis avant lui), avec le correctif des grands multiples de 10 000.
require "./partiduo/ext/pg_numeric"

require "./partiduo/version"
require "./partiduo/config"
require "./partiduo/api/**"

# Applications Marten, dans l'ordre de l'ADR-001 § Organisation du code.
require "./modules/app"
require "./auth/app"
require "./core/app"
# `vat` avant `cards` : une fiche article cite son taux de TVA par défaut.
require "./vat/app"
require "./cards/app"
require "./accounting/app"
require "./invoicing/app"
require "./analytic/app"
require "./stock/app"
require "./followup/app"
require "./micro/app"
require "./liberal/app"

require "./partiduo/settings"
