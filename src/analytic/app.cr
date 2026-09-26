# SPDX-License-Identifier: AGPL-3.0-or-later

require "./manifest"

module Partiduo
  # Module Analytique (ADR-006 D1) : plans, postes, ventilations. Lot 5.
  module Analytic
    class App < Marten::App
      label "analytic"
    end
  end
end
