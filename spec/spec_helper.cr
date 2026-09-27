# SPDX-License-Identifier: AGPL-3.0-or-later

ENV["MARTEN_ENV"] = "test"

require "spec"

require "../src/partiduo"
require "../config/settings/base"
require "../config/settings/**"
require "../src/partiduo/cli"

require "marten/spec"
require "marten_auth/spec"

require "./support/**"

# Date du jour figée pour les règles datées de la Facturation et de la
# Comptabilité (émission, échéances, relances, relevés) : les specs restent
# vraies quel que soit le jour où elles tournent (D-2F-012). Une spec qui a
# besoin d'un autre jour l'obtient par `Partiduo::Config.travel_to`.
SPEC_NOW = Time.utc(2026, 9, 27, 10, 0, 0)
Partiduo::Config.clock = -> { SPEC_NOW }
