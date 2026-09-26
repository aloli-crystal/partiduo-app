# SPDX-License-Identifier: AGPL-3.0-or-later

require "./manifest"
require "./services/**"
require "./api/**"

module Partiduo
  # Module Comptabilité (ADR-006 D1) : plan comptable, journaux, écritures,
  # lettrage, rapprochement, éditions, déclarations de TVA, FEC, clôture.
  module Accounting
    class App < Marten::App
      label "accounting"
    end
  end
end
