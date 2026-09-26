# SPDX-License-Identifier: AGPL-3.0-or-later

require "json"
require "webauthn"

module Partiduo
  module Auth
    # Passkeys (ADR-002 D2, D5) par `prod-crystal/webauthn` : ES256 et RS256,
    # credential découvrable (`residentKey: required`), vérification de
    # l'utilisateur exigée, attestation `none`, compteur de signature nul
    # accepté (authentificateurs Apple), RP ID configurable
    # (`partiduo.localhost` par défaut).
    module Passkeys
      PURPOSE_CREATE = "webauthn.create"
      PURPOSE_GET    = "webauthn.get"
      TIMEOUT_MS     = Config::CHALLENGE_TIMEOUT.total_milliseconds.to_i

      class Error < Exception
        getter key : String

        def initialize(@key : String, message : String? = nil)
          super(message || key)
        end
      end

      record Verified, passkey : Passkey, user : User

      # Poignée d'utilisateur WebAuthn (`user.id`) : 16 octets dérivés de
      # l'identifiant et du RP ID, sans donnée personnelle.
      def self.user_handle(user : User) : Bytes
        digest = OpenSSL::Digest.new("SHA256")
        digest.update("partiduo:#{Config.rp_id}:#{user.pk}")
        digest.final[0, 16]
      end

      def self.algorithms : Array(Int64)
        WebAuthn::COSE::DEFAULT_ALGORITHMS
      end

      # Enregistrement, étape 1 : défi conservé côté serveur.
      def self.begin_registration(user : User) : Challenges::Issued
        challenge = Secrets.base64url(WebAuthn.generate_challenge)
        Challenges.issue(PURPOSE_CREATE, user: user, value: challenge)
      end

      # Enregistrement, étape 2 : vérifie la cérémonie et enregistre la clé.
      def self.finish_registration(user : User, handle : String, attestation_object : String,
                                   client_data_json : String, transports : Array(String),
                                   name : String) : Passkey
        challenge = Challenges.consume(PURPOSE_CREATE, handle)
        raise Error.new("auth.errors.passkey.challenge") if challenge.nil? || challenge.user_id != user.pk

        attestation = decode(attestation_object)
        client_data = decode(client_data_json)
        rp = relying_party(client_data)

        credential = begin
          rp.verify_registration(attestation, client_data, decode(challenge.value.to_s),
            user_verification: WebAuthn::UserVerification::Required)
        rescue ex : WebAuthn::Error
          raise Error.new("auth.errors.passkey.invalid", ex.message)
        end

        credential_id = Secrets.base64url(credential.id)
        if Passkey.filter(credential_id: credential_id).exists?
          raise Error.new("auth.errors.passkey.already_registered")
        end

        Passkey.create!(
          user: user,
          credential_id: credential_id,
          public_key: Base64.strict_encode(cose_key_bytes(attestation)),
          cose_algorithm: credential.public_key.cose_algorithm.to_i32,
          sign_count: credential.sign_count.to_i64,
          aaguid: uuid(credential.aaguid),
          transports: transports.map(&.strip).reject(&.empty?).first(8).join(','),
          backup_eligible: credential.backup_eligible?,
          backup_state: credential.backup_state?,
          name: name.strip[0, 100],
        )
      end

      # Authentification, étape 1. Sans `user`, credential découvrable : la
      # liste des clés admises reste vide et le navigateur propose les siennes.
      def self.begin_authentication(user : User? = nil) : Challenges::Issued
        challenge = Secrets.base64url(WebAuthn.generate_challenge)
        Challenges.issue(PURPOSE_GET, user: user, value: challenge)
      end

      # Authentification, étape 2. `expected_user` : pour une élévation, la clé
      # doit appartenir à l'utilisateur de la session.
      def self.finish_authentication(handle : String, credential_id : String, authenticator_data : String,
                                     client_data_json : String, signature : String,
                                     user_handle : String? = nil, expected_user : User? = nil,
                                     now : Time = Time.utc) : Verified
        challenge = Challenges.consume(PURPOSE_GET, handle)
        raise Error.new("auth.errors.passkey.challenge") if challenge.nil?

        id_bytes = decode(credential_id)
        passkey = Passkey.filter(credential_id: Secrets.base64url(id_bytes)).first
        raise Error.new("auth.errors.passkey.unknown") if passkey.nil?
        user = passkey.user!
        if (bound = challenge.user_id) && bound != user.pk
          raise Error.new("auth.errors.passkey.unknown")
        end
        if expected_user && expected_user.pk != user.pk
          raise Error.new("auth.errors.passkey.unknown")
        end
        if handle_value = user_handle.presence
          unless decode(handle_value) == user_handle(user)
            raise Error.new("auth.errors.passkey.unknown")
          end
        end

        client_data = decode(client_data_json)
        rp = relying_party(client_data)
        stored = WebAuthn::Credential.new(
          id: id_bytes,
          public_key: WebAuthn::COSE.decode_key(Base64.decode(passkey.public_key.to_s), algorithms),
          sign_count: (passkey.sign_count || 0_i64).to_u32,
          aaguid: Bytes.new(WebAuthn::AuthenticatorData::AAGUID_SIZE),
          backup_eligible: passkey.backup_eligible == true,
          backup_state: passkey.backup_state == true,
          user_verified: true,
        )

        assertion = begin
          rp.verify_authentication(stored, decode(authenticator_data), client_data, decode(signature),
            decode(challenge.value.to_s), user_verification: WebAuthn::UserVerification::Required,
            credential_id: id_bytes)
        rescue ex : WebAuthn::ClonedAuthenticatorError
          raise Error.new("auth.errors.passkey.cloned", ex.message)
        rescue ex : WebAuthn::Error
          raise Error.new("auth.errors.passkey.invalid", ex.message)
        end

        passkey.sign_count = assertion.sign_count.to_i64
        passkey.backup_state = assertion.backup_state?
        passkey.last_used_at = now
        passkey.save!
        Verified.new(passkey, user)
      end

      # Partie de confiance pour l'origine annoncée par le client, si cette
      # origine est admise (`Config.origin_allowed?`). La bibliothèque
      # recontrôle ensuite l'origine, le défi et l'empreinte du RP ID.
      private def self.relying_party(client_data : Bytes) : WebAuthn::RelyingParty
        origin = begin
          JSON.parse(String.new(client_data))["origin"]?.try(&.as_s?)
        rescue JSON::ParseException
          nil
        end
        raise Error.new("auth.errors.passkey.origin") if origin.nil? || !Config.origin_allowed?(origin)
        WebAuthn::RelyingParty.new(id: Config.rp_id, origins: [origin], algorithms: algorithms)
      end

      private def self.decode(value : String) : Bytes
        Secrets.decode64?(value) || raise Error.new("auth.errors.passkey.invalid", "base64url invalide")
      end

      # Clé publique COSE brute, telle qu'enrôlée, extraite des données
      # d'authentificateur (après leur vérification par `verify_registration`).
      private def self.cose_key_bytes(attestation : Bytes) : Bytes
        auth_data = WebAuthn::CBOR.decode_map(attestation)["authData"].as_bytes
        offset = WebAuthn::AuthenticatorData::FIXED_SIZE + WebAuthn::AuthenticatorData::AAGUID_SIZE
        length = (auth_data[offset].to_i << 8) | auth_data[offset + 1].to_i
        offset += 2 + length
        remaining = auth_data[offset, auth_data.size - offset]
        remaining[0, WebAuthn::CBOR.decode_first(remaining)[:size]].dup
      end

      private def self.uuid(bytes : Bytes) : String
        hex = bytes.hexstring
        return "" unless hex.size == 32
        "#{hex[0, 8]}-#{hex[8, 4]}-#{hex[12, 4]}-#{hex[16, 4]}-#{hex[20, 12]}"
      end
    end
  end
end
