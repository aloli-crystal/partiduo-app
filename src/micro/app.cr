# SPDX-License-Identifier: AGPL-3.0-or-later

require "./manifest"
require "./models/**"
require "./services/**"
require "./api/**"
require "./initial_data"

module Partiduo
  # Module micro-entreprise (ADR-007 D1, D2) : registres natifs (livre des
  # recettes, registre des achats), aide URSSAF, 2042-C-PRO, seuils.
  module Micro
    class App < Marten::App
      label "micro"
    end
  end
end
