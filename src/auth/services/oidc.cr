# SPDX-License-Identifier: AGPL-3.0-or-later

require "http/client"
require "json"
require "jose"
require "uri"

module Partiduo
  module Auth
    # OpenID Connect intégré (ADR-002 D3, « OIDC pluggable » branché au
    # cœur) : flux « authorization code » d'un client confidentiel, avec
    # PKCE (S256) et `nonce` (DECISIONS D-R5-009).
    #
    # * Début : `state`, vérificateur PKCE et `nonce` tirés au hasard ; seul
    #   `state` part chez le fournisseur avec le défi PKCE et le `nonce`. Les
    #   trois restent côté serveur, dans la valeur du défi de connexion
    #   (`Challenges`), jamais dans le navigateur.
    # * Retour (`code`, `state`) : `state` comparé en temps constant, code
    #   échangé au point de jeton (`client_secret_post`, vérificateur PKCE),
    #   jeton d'identité vérifié : signature RS256/384/512 par la clé
    #   publiée (`jwks_uri`, `kid`), émetteur, audience (et `azp` si
    #   plusieurs), expiration et émission (±60 s), `nonce`.
    # * Identité : la revendication `sub` (ou celle des paramètres),
    #   rattachée par l'administrateur à un utilisateur *déjà créé* ; pas
    #   d'auto-provisionnement.
    #
    # Adresses en HTTPS (HTTP admis pour `localhost` et `*.localhost`, en
    # développement). Le transport HTTP est remplaçable (specs).
    class OidcAdapter < Federation::Adapter
      REQUIRED = %w[issuer authorization_endpoint token_endpoint jwks_uri client_id client_secret redirect_uri]
      URLS     = %w[issuer authorization_endpoint token_endpoint jwks_uri redirect_uri]
      SKEW     = 60.seconds
      SCOPES   = "openid email"
      # Séparateur des trois valeurs gardées côté serveur (base64url : pas de `~`).
      SEPARATOR = '~'

      # Accès HTTP du client : `POST` d'un formulaire, `GET` ; rend {statut, corps}.
      abstract class Transport
        abstract def post_form(url : String, form : Hash(String, String)) : {Int32, String}
        abstract def get(url : String) : {Int32, String}
      end

      # Transport réel : délais courts, pas de redirection suivie.
      class NetTransport < Transport
        TIMEOUT = 10.seconds

        def post_form(url : String, form : Hash(String, String)) : {Int32, String}
          uri = URI.parse(url)
          client(uri) do |http|
            headers = HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded", "Accept" => "application/json"}
            response = http.post(uri.request_target, headers: headers, body: URI::Params.encode(form))
            {response.status_code, response.body}
          end
        end

        def get(url : String) : {Int32, String}
          uri = URI.parse(url)
          client(uri) do |http|
            response = http.get(uri.request_target, headers: HTTP::Headers{"Accept" => "application/json"})
            {response.status_code, response.body}
          end
        end

        private def client(uri : URI, & : HTTP::Client -> {Int32, String}) : {Int32, String}
          http = HTTP::Client.new(uri)
          http.connect_timeout = TIMEOUT
          http.read_timeout = TIMEOUT
          begin
            yield http
          ensure
            http.close
          end
        rescue ex : IO::Error | Socket::Error | OpenSSL::SSL::Error
          raise Federation::Error.new("auth.errors.federated.unreachable", ex.message)
        end
      end

      class_property transport : Transport = NetTransport.new

      def kind : String
        "oidc"
      end

      def settings_schema : Array(Federation::SettingField)
        [
          Federation::SettingField.new("issuer", required: true),
          Federation::SettingField.new("authorization_endpoint", required: true),
          Federation::SettingField.new("token_endpoint", required: true),
          Federation::SettingField.new("jwks_uri", required: true),
          Federation::SettingField.new("client_id", required: true),
          Federation::SettingField.new("client_secret", required: true, secret: true),
          Federation::SettingField.new("redirect_uri", required: true),
          Federation::SettingField.new("scopes"),
          Federation::SettingField.new("subject_claim"),
        ]
      end

      def validate_settings(settings : Hash(String, String)) : Array(Partiduo::Api::FieldError)
        errors = REQUIRED.compact_map do |key|
          next if settings[key]?.presence
          Partiduo::Api::FieldError.new("settings.#{key}", "auth.errors.provider.required")
        end
        URLS.each do |key|
          value = settings[key]?.presence || next
          unless self.class.acceptable_url?(value)
            errors << Partiduo::Api::FieldError.new("settings.#{key}", "auth.errors.provider.url")
          end
        end
        if (scopes = settings["scopes"]?.presence) && !scopes.split.includes?("openid")
          errors << Partiduo::Api::FieldError.new("settings.scopes", "auth.errors.provider.openid_scope")
        end
        errors
      end

      # HTTPS, ou HTTP pour un hôte local de développement.
      def self.acceptable_url?(value : String) : Bool
        uri = URI.parse(value)
        host = uri.host.to_s
        return false if host.empty?
        uri.scheme == "https" || (uri.scheme == "http" && (host == "localhost" || host.ends_with?(".localhost")))
      rescue URI::Error
        false
      end

      def begin_login(provider : IdentityProvider, settings : Hash(String, String)) : Federation::Start
        state, verifier, nonce = Secrets.token, Secrets.token, Secrets.token
        challenge = Secrets.base64url(OpenSSL::Digest.new("SHA256").update(verifier).final)
        params = URI::Params.build do |form|
          form.add "response_type", "code"
          form.add "client_id", settings["client_id"]? || ""
          form.add "redirect_uri", settings["redirect_uri"]? || ""
          form.add "scope", settings["scopes"]?.presence || SCOPES
          form.add "state", state
          form.add "nonce", nonce
          form.add "code_challenge", challenge
          form.add "code_challenge_method", "S256"
        end
        endpoint = settings["authorization_endpoint"]? || ""
        separator = endpoint.includes?('?') ? '&' : '?'
        Federation::Start.new("#{endpoint}#{separator}#{params}", [state, verifier, nonce].join(SEPARATOR))
      end

      def complete_login(provider : IdentityProvider, settings : Hash(String, String),
                         payload : Hash(String, String), request_id : String,
                         now : Time = Time.utc) : Federation::Identity
        state, verifier, nonce = split_request(request_id)
        if payload["error"]?.presence
          raise Federation::Error.new("auth.errors.federated.denied", payload["error"])
        end
        unless Secrets.equal?(payload["state"]? || "", state)
          raise Federation::Error.new("auth.errors.federated.invalid", "state inattendu")
        end
        code = payload["code"]?.presence || invalid("code absent")
        id_token = exchange(settings, code, verifier)
        claims = verified_claims(id_token, settings)
        check_claims(claims, settings, nonce, now)
        subject_claim = settings["subject_claim"]?.presence || "sub"
        subject = claims[subject_claim]?.try(&.as_s?).presence || invalid("revendication #{subject_claim} absente")
        email = claims["email"]?.try(&.as_s?)
        Federation::Identity.new(subject: subject, email: email)
      end

      private def split_request(request_id : String) : {String, String, String}
        parts = request_id.split(SEPARATOR)
        invalid("requête illisible") unless parts.size == 3 && parts.none?(&.empty?)
        {parts[0], parts[1], parts[2]}
      end

      # Échange du code contre les jetons ; rend le jeton d'identité.
      private def exchange(settings : Hash(String, String), code : String, verifier : String) : String
        status, body = self.class.transport.post_form(settings["token_endpoint"]? || "", {
          "grant_type"    => "authorization_code",
          "code"          => code,
          "redirect_uri"  => settings["redirect_uri"]? || "",
          "client_id"     => settings["client_id"]? || "",
          "client_secret" => settings["client_secret"]? || "",
          "code_verifier" => verifier,
        })
        invalid("point de jeton : HTTP #{status}") unless status == 200
        json = parse(body)
        json["id_token"]?.try(&.as_s?).presence || invalid("id_token absent")
      end

      # Signature du jeton par une clé RSA publiée (`kid` s'il est donné).
      private def verified_claims(token : String, settings : Hash(String, String)) : Hash(String, JSON::Any)
        header = parse(String.new(Secrets.decode64?(token.split('.').first? || "") || Bytes.empty))
        kid = header["kid"]?.try(&.as_s?)
        algorithm = header["alg"]?.try(&.as_s?) || ""
        invalid("algorithme #{algorithm} refusé") unless algorithm.in?("RS256", "RS384", "RS512")
        signing_keys(settings, kid).each do |key|
          jwk = Jose::JWK::RSAKey.from_jwk_hash(key.as_h)
          return parse(String.new(Jose::JWS.verify(token, jwk)))
        rescue Jose::JWS::Error | Jose::JWK::Error | ArgumentError | KeyError
          next
        end
        raise Federation::Error.new("auth.errors.federated.signature", "aucune clé ne vérifie le jeton")
      end

      # Clés RSA de signature publiées par le fournisseur (`kid` s'il est donné).
      private def signing_keys(settings : Hash(String, String), kid : String?) : Array(JSON::Any)
        status, body = self.class.transport.get(settings["jwks_uri"]? || "")
        invalid("clés du fournisseur : HTTP #{status}") unless status == 200
        keys = parse(body)["keys"]?.try(&.as_a?) || invalid("jeu de clés illisible")
        keys.select do |key|
          next false unless key["kty"]?.try(&.as_s?) == "RSA"
          next false if (use = key["use"]?.try(&.as_s?)) && use != "sig"
          kid.nil? || key["kid"]?.try(&.as_s?) == kid
        end
      end

      private def check_claims(claims : Hash(String, JSON::Any), settings : Hash(String, String), nonce : String, now : Time) : Nil
        invalid("émetteur inattendu") unless claims["iss"]?.try(&.as_s?) == settings["issuer"]?
        check_audience(claims, settings["client_id"]? || "")
        expires = claims["exp"]?.try(&.as_i64?) || invalid("exp absent")
        invalid("jeton expiré") if now - SKEW >= Time.unix(expires)
        if issued = claims["iat"]?.try(&.as_i64?)
          invalid("jeton émis dans le futur") if Time.unix(issued) > now + SKEW
        end
        invalid("nonce inattendu") unless Secrets.equal?(claims["nonce"]?.try(&.as_s?) || "", nonce)
      end

      # Audience : le client ; plusieurs audiences exigent `azp` égal au client.
      private def check_audience(claims : Hash(String, JSON::Any), client_id : String) : Nil
        audiences = case audience = claims["aud"]?.try(&.raw)
                    when String then [audience]
                    when Array  then audience.compact_map(&.as_s?)
                    else             [] of String
                    end
        invalid("audience inattendue") unless audiences.includes?(client_id)
        invalid("azp inattendu") if audiences.size > 1 && claims["azp"]?.try(&.as_s?) != client_id
      end

      private def parse(body : String) : Hash(String, JSON::Any)
        JSON.parse(body).as_h? || invalid("réponse JSON attendue")
      rescue JSON::ParseException
        invalid("réponse JSON illisible")
      end

      private def invalid(reason : String) : NoReturn
        raise Federation::Error.new("auth.errors.federated.invalid", reason)
      end
    end

    Federation.register(OidcAdapter.new)
  end
end
