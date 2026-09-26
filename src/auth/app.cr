# SPDX-License-Identifier: AGPL-3.0-or-later

require "./models/**"

module Partiduo
  # Authentification (ADR-002 D1) : l'utilisateur vit dans le projet, extensible
  # et migrable comme tout modèle. Les écrans de connexion, d'inscription et de
  # réinitialisation appartiennent à l'interface (ADR-005), pas à ce dépôt.
  module Auth
    class App < Marten::App
      label "auth"
    end
  end
end
