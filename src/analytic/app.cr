# SPDX-License-Identifier: AGPL-3.0-or-later

require "./manifest"
require "./models/plan"
require "./models/**"
require "./services/**"
require "./api/**"

module Partiduo
  # Module Analytique (ADR-006 D1) : plans, postes, groupes, clés de
  # répartition, ventilation des lignes d'écriture, opérations diverses,
  # balances et historiques. Requiert la Comptabilité (lot 5).
  module Analytic
    class App < Marten::App
      label "analytic"
    end
  end
end
