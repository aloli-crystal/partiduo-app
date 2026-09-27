# SPDX-License-Identifier: AGPL-3.0-or-later

require "./manifest"
require "./models/category"
require "./models/card"
require "./services/**"
require "./defaults"
require "./api/**"
require "./initial_data"

module Partiduo
  # Socle : fiches — tiers (clients, fournisseurs), articles et services,
  # catégories et attributs (ADR-001 D3, ADR-006 D1). Lot 1.
  module Cards
    class App < Marten::App
      label "cards"
    end
  end
end
