# SPDX-License-Identifier: AGPL-3.0-or-later

require "./events"
require "./manifest"
require "./registry"

module Partiduo
  module Modules
    # Application Marten du registre. Sa mise en place vérifie la cohérence des
    # modules actifs : une configuration incohérente empêche le démarrage.
    class App < Marten::App
      label "modules"

      def setup
        Partiduo::Modules.check!
      end
    end
  end
end
