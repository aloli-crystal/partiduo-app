# SPDX-License-Identifier: AGPL-3.0-or-later

require "./manifest"
require "./models/**"
require "./services/**"
require "./api/**"
require "./initial_data"

module Partiduo
  # Module des professions libérales en déclaration contrôlée (ADR-007 D6) :
  # livre-journal des recettes et des dépenses, registre des immobilisations
  # et des amortissements, préparation de la 2035.
  module Liberal
    class App < Marten::App
      label "liberal"
    end
  end
end
