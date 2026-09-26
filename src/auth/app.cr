# SPDX-License-Identifier: AGPL-3.0-or-later

require "./config"
require "./manifest"
require "./models/profile"
require "./models/user"
require "./models/security"
require "./services/**"
require "./api/**"
require "./initial_data"

module Partiduo
  # Authentification et droits (ADR-002) : utilisateurs, profils et droits
  # par journal, rôle `comptable`, mot de passe (CNIL 2022-100) avec
  # limitation des tentatives, TOTP, passkeys, codes de récupération, SAML,
  # sessions et journal d'audit. Tout passe par `Partiduo::Api::Auth` ; les
  # écrans appartiennent à l'interface (ADR-005), pas à ce dépôt.
  module Auth
    class App < Marten::App
      label "auth"
    end
  end
end
