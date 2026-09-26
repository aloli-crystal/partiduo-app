# SPDX-License-Identifier: AGPL-3.0-or-later

# Ligne de commande Marten du cœur : `crystal run manage.cr -- migrate`.
require "./src/partiduo"
require "./config/settings/base"
require "./config/settings/**"
require "./src/partiduo/cli"
require "marten/cli"

Marten.setup
Marten::CLI.run
