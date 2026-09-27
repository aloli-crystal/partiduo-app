# SPDX-License-Identifier: AGPL-3.0-or-later

require "./manifest"
require "./models/account"
require "./models/**"
require "./services/**"
require "./api/**"
require "./initial_data"

module Partiduo
  # Module Comptabilité (ADR-006 D1) : plan comptable, journaux, écritures,
  # lettrage, rapprochement, éditions, déclarations de TVA, FEC, clôture.
  module Accounting
    class App < Marten::App
      label "accounting"
    end
  end
end
