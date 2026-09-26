# SPDX-License-Identifier: AGPL-3.0-or-later

require "totp"

module Partiduo
  module Auth
    # TOTP, second facteur *du mot de passe* (ADR-002 D2). Paramètres par
    # défaut de la RFC 6238 — SHA-1, 6 chiffres, 30 s —, les seuls que toutes
    # les applications d'authentification calculent ; aucune n'est nommée ni
    # recommandée. Anti-rejeu : le compteur accepté est stocké
    # (`last_otp_counter`) et repassé en `after:` à la vérification suivante.
    module Totp
      DIGITS    =  6
      PERIOD    = 30
      ALGORITHM = "SHA1"

      def self.authenticator(secret : String) : TOTP::Authenticator
        TOTP::Authenticator.from_base32(secret)
      end

      def self.provisioning_uri(user : User, secret : String) : String
        authenticator(secret).provisioning_uri(account: user.email.to_s, issuer: Config::ISSUER)
      end

      # Vérifie un code contre le secret actif ; en cas de succès, enregistre
      # le compteur accepté. Un code déjà utilisé (même compteur ou antérieur)
      # est refusé.
      def self.verify!(user : User, code : String, now : Time = Time.utc) : Bool
        secret = user.totp_secret
        return false if secret.nil? || !user.totp_enabled?
        after = user.last_otp_counter.try(&.to_u64)
        counter = authenticator(secret).verify(code, time: now, after: after)
        return false if counter.nil?
        user.last_otp_counter = counter.to_i64
        user.save!
        true
      end

      # Vérifie un code contre le secret en cours d'enrôlement.
      def self.verify_pending(user : User, code : String, now : Time = Time.utc) : UInt64?
        secret = user.totp_pending_secret
        return if secret.nil?
        authenticator(secret).verify(code, time: now)
      end
    end

    # Codes de récupération à usage unique (ADR-002 D7), générés à
    # l'enrôlement du premier second facteur ou de la première passkey,
    # affichés une seule fois. Un code remplace le code TOTP dans une connexion
    # par mot de passe.
    module RecoveryCodes
      ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789" # sans 0/O ni 1/I/L

      def self.remaining(user : User) : Int32
        RecoveryCode.filter(user_id: user.pk, used_at__isnull: true).count.to_i32
      end

      # Remplace tous les codes de l'utilisateur ; renvoie les nouveaux, en
      # clair, pour un affichage unique. 16 caractères sur 31 : 79 bits.
      def self.generate(user : User, count : Int32 = Config::RECOVERY_CODES) : Array(String)
        RecoveryCode.filter(user_id: user.pk).delete
        Array.new(count) do
          code = String.build do |io|
            16.times do |index|
              io << '-' if index > 0 && index % 4 == 0
              io << ALPHABET[Random::Secure.rand(ALPHABET.size)]
            end
          end
          RecoveryCode.create!(user: user, code_digest: Secrets.digest(normalize(code)))
          code
        end
      end

      # Génère des codes seulement si l'utilisateur n'en a plus.
      def self.ensure(user : User) : Array(String)
        remaining(user).zero? ? generate(user) : [] of String
      end

      def self.consume!(user : User, code : String, now : Time = Time.utc) : Bool
        digest = Secrets.digest(normalize(code))
        RecoveryCode.filter(user_id: user.pk, code_digest: digest, used_at__isnull: true)
          .update(used_at: now) == 1
      end

      def self.normalize(code : String) : String
        code.upcase.gsub(/[^A-Z0-9]/, "")
      end
    end
  end
end
