# SPDX-License-Identifier: AGPL-3.0-or-later

# Migrations du cœur, requises par la ligne de commande Marten (`manage.cr`)
# et par tout projet qui embarque le cœur (`require "partiduo/cli"`).
#
# Chaque application qui crée son premier fichier de migration ajoute ici sa
# ligne `require "../<app>/migrations/**"` (un motif sans fichier ne compile pas).
require "marten/cli"

require "../accounting/migrations/**"
require "../analytic/migrations/**"
require "../auth/migrations/**"
require "../core/migrations/**"
require "../vat/migrations/**"
require "../cards/migrations/**"
require "../invoicing/migrations/**"
require "../modules/migrations/**"
require "../stock/migrations/**"
require "../followup/migrations/**"
require "../micro/migrations/**"
require "../liberal/migrations/**"

# Commandes de gestion du cœur (`provision`).
require "../core/commands/**"

# Fin de mois de la Facturation (`invoicing_month_end`, D-INV2-008).
require "../invoicing/commands/**"
