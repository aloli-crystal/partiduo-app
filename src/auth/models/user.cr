# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Auth
    # Utilisateur de l'instance (ADR-002 D1). Le lot 0 y ajoute nom, langue,
    # rôle (dont `comptable`, ADR-002 D4), méthodes d'authentification, TOTP
    # (`last_otp_counter`) et règles de mot de passe (`password-policy`).
    class User < MartenAuth::User
    end
  end
end
