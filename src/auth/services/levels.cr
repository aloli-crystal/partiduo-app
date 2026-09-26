# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Auth
    # Niveaux de sécurité (ADR-002 D2) et parcours d'élévation (D6).
    #
    # [cols="1,3"]
    # |===
    # |0 |session d'enrôlement (invitation) : aucun droit, sauf enrôler une méthode
    # |1 |mot de passe seul
    # |2 |mot de passe + TOTP (ou code de récupération), ou fournisseur d'identité
    # |3 |passkey avec vérification de l'utilisateur
    # |===
    #
    # Le niveau 3 ne s'empile pas sur le 2 : une passkey suffit.
    module Levels
      ENROLLMENT = 0
      PASSWORD   = 1
      TWO_FACTOR = 2
      PASSKEY    = 3

      # Niveau exigé pour obtenir ses droits : celui de la politique de
      # l'instance, et 3 pour le rôle `comptable` (ADR-002 D4).
      def self.required(user : User, policy : Policy = Policy.current) : Int32
        level = policy.minimum_level
        level = PASSKEY if user.accountant?
        level
      end

      # Niveau le plus haut que l'utilisateur peut atteindre avec les méthodes
      # qu'il a enrôlées.
      def self.achievable(user : User, policy : Policy = Policy.current) : Int32
        return PASSKEY if policy.allows?("passkey") && Passkey.filter(user_id: user.pk).exists?
        federated = federated_level(user, policy)
        password = if policy.allows?("password") && user.usable_password?
                     user.totp_enabled? ? TWO_FACTOR : PASSWORD
                   else
                     ENROLLMENT
                   end
        {federated, password}.max
      end

      def self.federated_level(user : User, policy : Policy) : Int32
        return ENROLLMENT unless policy.allows?("federated")
        codes = FederatedIdentity.filter(user_id: user.pk).map(&.provider)
        return ENROLLMENT if codes.empty?
        IdentityProvider.filter(code__in: codes, active: true).max_of? { |provider| (provider.level || TWO_FACTOR).to_i32 } || ENROLLMENT
      end

      # Ce qui manque pour monter (page « sécurité du compte », ADR-002 D6) :
      # `totp`, `passkey`, `recovery_codes`. Liste vide : rien à ajouter.
      def self.missing(user : User, policy : Policy = Policy.current) : Array(String)
        missing = [] of String
        has_passkey = Passkey.filter(user_id: user.pk).exists?
        missing << "totp" if policy.allows?("password") && user.usable_password? && !user.totp_enabled?
        missing << "passkey" if policy.allows?("passkey") && !has_passkey
        if (has_passkey || user.totp_enabled?) && RecoveryCodes.remaining(user).zero?
          missing << "recovery_codes"
        end
        missing
      end

      # Invitation à enrôler une passkey après une connexion sans passkey :
      # refusable, mais rappelée (ADR-002 D6).
      def self.suggest_passkey?(user : User, policy : Policy = Policy.current, now : Time = Time.utc) : Bool
        return false unless policy.allows?("passkey")
        return false if Passkey.filter(user_id: user.pk).exists?
        dismissed = user.passkey_prompt_dismissed_at
        dismissed.nil? || dismissed + Config::PASSKEY_REMINDER <= now
      end
    end
  end
end
