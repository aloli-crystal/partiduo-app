# SPDX-License-Identifier: AGPL-3.0-or-later

require "./manifest"
require "./models/**"
require "./services/**"
require "./api/**"

module Partiduo
  # Module Stock (ADR-006 D1, lot 6) : dépôts, articles suivis, mouvements
  # (manuels et issus de la Facturation ou de la Comptabilité par les
  # événements), inventaires, état des stocks et valorisation. Requiert la
  # Facturation *ou* la Comptabilité (`depends_on_any`, ADR-003 D2).
  module Stock
    class App < Marten::App
      label "stock"
    end
  end
end
