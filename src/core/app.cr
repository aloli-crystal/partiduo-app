# SPDX-License-Identifier: AGPL-3.0-or-later

require "./manifest"
require "./models/**"
require "./services/**"
require "./api/**"
require "./initial_data"

module Partiduo
  # Socle : dossier et société (Settings), profils, exercices et périodes,
  # devises, paramètres, pièces jointes (ADR-001 § Organisation du code, ADR-006 D1).
  module Core
    class App < Marten::App
      label "core"
    end
  end
end
