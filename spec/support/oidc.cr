# SPDX-License-Identifier: AGPL-3.0-or-later

require "jose"

# Fournisseur OpenID Connect simulé (DECISIONS D-R5-009) : transport HTTP
# remplacé, clé RSA de signature, jetons d'identité forgés à la demande.
module OidcSpec
  ISSUER    = "https://login.cabinet.test"
  CLIENT_ID = "partiduo-demo"
  SECRET    = "secret-du-client"
  REDIRECT  = "https://demo.partiduo.localhost/login/federated/cabinet/callback"

  KEY = Jose::JWK::RSAKey.generate(2048)

  class Transport < Partiduo::Auth::OidcAdapter::Transport
    getter forms = [] of Hash(String, String)
    property token_status = 200
    property id_token = ""
    property keys : String

    def initialize
      public = OidcSpec::KEY.public_key.to_jwk_hash
      public["kid"] = "k1"
      @keys = {"keys" => [public]}.to_json
    end

    def post_form(url : String, form : Hash(String, String)) : {Int32, String}
      forms << form
      {token_status, {"access_token" => "a", "token_type" => "Bearer", "id_token" => id_token}.to_json}
    end

    def get(url : String) : {Int32, String}
      {200, keys}
    end
  end

  def self.settings(**overrides) : Hash(String, String)
    base = {
      "issuer"                 => ISSUER,
      "authorization_endpoint" => "#{ISSUER}/authorize",
      "token_endpoint"         => "#{ISSUER}/token",
      "jwks_uri"               => "#{ISSUER}/keys",
      "client_id"              => CLIENT_ID,
      "client_secret"          => SECRET,
      "redirect_uri"           => REDIRECT,
    }
    overrides.each { |key, value| base[key.to_s] = value.to_s }
    base
  end

  def self.configure(code : String = "cabinet", level : Int32 = 2) : Transport
    transport = Transport.new
    Partiduo::Auth::OidcAdapter.transport = transport
    input = Partiduo::Api::Auth::IdentityProviderInput.new(code: code, kind: "oidc", name: "Cabinet (OIDC)",
      level: level, settings: settings)
    Partiduo::Api::Auth.save_identity_provider(Partiduo::Api::Actor.system, input).value!
    transport
  end

  # Paramètres de la requête d'autorisation.
  def self.query(start : Partiduo::Api::Auth::FederatedStartView) : URI::Params
    URI.parse(start.redirect_url).query_params
  end

  def self.id_token(nonce : String, subject : String = "sub-42", issuer : String = ISSUER,
                    audience : String | Array(String) = CLIENT_ID, expires : Time = Time.utc + 5.minutes,
                    key : Jose::JWK::RSAKey = KEY, kid : String = "k1", **extra) : String
    claims = {"iss" => JSON::Any.new(issuer), "sub" => JSON::Any.new(subject), "nonce" => JSON::Any.new(nonce),
              "exp" => JSON::Any.new(expires.to_unix), "iat" => JSON::Any.new(Time.utc.to_unix),
              "email" => JSON::Any.new("expert@cabinet.example")}
    claims["aud"] = audience.is_a?(String) ? JSON::Any.new(audience) : JSON::Any.new(audience.map { |item| JSON::Any.new(item) })
    extra.each { |name, value| claims[name.to_s] = JSON::Any.new(value.to_s) }
    Jose::JWS.sign(claims.to_json, Jose::JWS::Algorithm::RS256, key, {"kid" => kid})
  end
end
