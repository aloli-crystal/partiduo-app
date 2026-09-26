# SPDX-License-Identifier: AGPL-3.0-or-later

require "./events"
require "./manifest"
require "./registry"
require "./models/**"
require "./state"
require "./api/**"

module Partiduo
  module Modules
    # Application Marten du registre (ADR-003 D2, ADR-006 D1). Sa mise en place
    # vérifie la cohérence des pièces enregistrées et de l'ensemble actif : une
    # incohérence empêche le démarrage (`ConfigurationError`).
    class App < Marten::App
      label "modules"

      def setup
        Partiduo::Modules.check!
      end
    end
  end
end
