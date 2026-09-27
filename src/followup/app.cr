# SPDX-License-Identifier: AGPL-3.0-or-later

require "./manifest"
require "./models/**"
require "./services/**"
require "./api/**"
require "./initial_data"

module Partiduo
  # Module Suivi (lot 6) : actions de suivi et relations avec les tiers
  # (`action_gestion`, `follow_up` de NOALYSS) — types d'action, états,
  # rappels, commentaires, fiches concernées, actions liées, opérations
  # rattachées, étiquettes. Hors GED : les documents relèvent de
  # l'extension `partiduo-document`.
  module Followup
    class App < Marten::App
      label "followup"
    end
  end
end
