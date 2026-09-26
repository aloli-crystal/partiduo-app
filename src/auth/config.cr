# SPDX-License-Identifier: AGPL-3.0-or-later

require "password-policy"

module Partiduo
  module Auth
    # Paramètres techniques de l'authentification (ADR-002). La politique
    # propre à la société (niveau minimum, méthodes autorisées, durée de
    # session) vient de `Core::Settings` : voir `Partiduo::Auth::Policy`.
    module Config
      # Nom affiché de la partie de confiance WebAuthn et émetteur TOTP.
      ISSUER = "Partiduo"

      # Limitation des attaques en ligne (CNIL 2022-100, palier à 50 bits ;
      # ADR-001, CAPTCHA abandonné) : temporisation croissante à partir du
      # `THROTTLE_AFTER`-ième échec consécutif, blocage au `LOCK_AFTER`-ième.
      THROTTLE_AFTER    =  3
      LOCK_AFTER        = 10
      THROTTLE_BASE     = 5.seconds
      THROTTLE_MAXIMUM  = 15.minutes
      PENDING_LIFETIME  = 5.minutes  # jeton entre mot de passe et second facteur
      CHALLENGE_TIMEOUT = 5.minutes  # défi WebAuthn, requête SAML
      IDLE_TIMEOUT      = 60.minutes # session inactive
      INVITATION_TTL    = 7.days
      RESET_TTL         = 1.hour
      UNLOCK_TTL        = 1.hour
      RECOVERY_CODES    = 10

      # Rappel de l'invitation à enrôler une passkey après un refus (ADR-002 D6).
      PASSKEY_REMINDER = 30.days

      # Délai par défaut d'une session, si `Core::Settings` ne le fixe pas.
      DEFAULT_SESSION_MINUTES = 480

      # Règles de mot de passe : préréglage « 14 caractères sans caractère
      # spécial obligatoire » de la CNIL, au palier « avec restriction des
      # accès » — qui n'est acquis que parce que `Throttle` limite les
      # tentatives. Limite de 71 octets (BCrypt de Crystal).
      def self.password_policy : PasswordPolicy::Policy
        PasswordPolicy::Policy.long(use_case: PasswordPolicy::UseCase::WithAccessRestriction)
      end

      # Coût BCrypt : `PARTIDUO_BCRYPT_COST`, sinon 4 en test (le minimum de
      # BCrypt, pour des specs rapides) et 12 ailleurs.
      def self.bcrypt_cost : Int32
        if value = ENV["PARTIDUO_BCRYPT_COST"]?.try(&.to_i?)
          return value.clamp(4, 31)
        end
        ENV["MARTEN_ENV"]? == "test" ? 4 : 12
      end

      # Identifiant de la partie de confiance WebAuthn (ADR-002 D5) :
      # `PARTIDUO_RP_ID`, sinon le domaine des instances
      # (`partiduo.localhost` par défaut). À figer avant le premier enrôlement.
      def self.rp_id : String
        ENV["PARTIDUO_RP_ID"]?.presence || Partiduo::Config.domain
      end

      # Origines WebAuthn admises. `PARTIDUO_WEBAUTHN_ORIGINS` (liste séparée
      # par des virgules) fixe une liste exacte ; sinon toute origine servie
      # sous le RP ID est admise — `https://<dossier>.<domaine>`, et `http://`
      # pour un domaine en `.localhost` (contexte sécurisé sans HTTPS).
      def self.origin_allowed?(origin : String) : Bool
        if list = ENV["PARTIDUO_WEBAUTHN_ORIGINS"]?.presence
          return list.split(',').map(&.strip).includes?(origin)
        end

        uri = URI.parse(origin)
        host = uri.host.to_s.downcase
        return false if host.empty? || !uri.path.empty? || uri.query || uri.user
        rp = rp_id.downcase
        return false unless host == rp || host.ends_with?(".#{rp}")

        case uri.scheme
        when "https" then true
        when "http"  then host == "localhost" || host.ends_with?(".localhost")
        else              false
        end
      rescue URI::Error
        false
      end
    end
  end
end
