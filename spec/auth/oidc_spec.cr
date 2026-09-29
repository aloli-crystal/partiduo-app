# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# OpenID Connect intégré (ADR-002 D3, DECISIONS D-R5-009) : flux
# « authorization code » avec PKCE et nonce, jeton d'identité vérifié,
# autorisation locale (identité rattachée à un utilisateur existant).

private alias Auth = Partiduo::Api::Auth

private def anonymous
  Partiduo::Api::Actor.anonymous
end

private def linked_user(subject : String = "sub-42") : Int64
  created = AuthSpec.create_user("expert@cabinet.example", first_name: "Claire", last_name: "Expert")
  Auth.link_federated_identity(AuthSpec.system, created.user.id, "cabinet", subject).value!
  created.user.id
end

private def callback(start : Auth::FederatedStartView, transport : OidcSpec::Transport, **token)
  query = OidcSpec.query(start)
  transport.id_token = OidcSpec.id_token(**token.merge(nonce: token[:nonce]? || query["nonce"]))
  Auth.login_federated(anonymous, "cabinet", start.request_id, {"code" => "code-1", "state" => query["state"]})
end

describe "OpenID Connect intégré (ADR-002 D3)" do
  it "envoie une requête d'autorisation avec state, nonce et défi PKCE, sans rien confier au navigateur" do
    OidcSpec.configure
    start = Auth.begin_federated_login(anonymous, "cabinet")
    start.redirect_url.should start_with("#{OidcSpec::ISSUER}/authorize?response_type=code")
    query = OidcSpec.query(start)
    {query["client_id"], query["redirect_uri"], query["scope"], query["code_challenge_method"]}
      .should eq({OidcSpec::CLIENT_ID, OidcSpec::REDIRECT, "openid email", "S256"})
    query["state"].size.should be >= 43
    query["nonce"].should_not eq(query["state"])
    start.request_id.should_not contain(query["state"])
  end

  it "connecte l'utilisateur rattaché, au niveau du fournisseur, et envoie le vérificateur PKCE" do
    transport = OidcSpec.configure(level: 2)
    user_id = linked_user
    start = Auth.begin_federated_login(anonymous, "cabinet")
    view = callback(start, transport).value!
    view.user_id.should eq(user_id)
    view.level.should eq(2)
    form = transport.forms.last
    {form["grant_type"], form["code"], form["client_secret"]}.should eq({"authorization_code", "code-1", OidcSpec::SECRET})
    challenge = Partiduo::Auth::Secrets.base64url(OpenSSL::Digest.new("SHA256").update(form["code_verifier"]).final)
    challenge.should eq(OidcSpec.query(start)["code_challenge"])
  end

  it "refuse une identité non rattachée (pas d'auto-provisionnement)" do
    transport = OidcSpec.configure
    start = Auth.begin_federated_login(anonymous, "cabinet")
    callback(start, transport, subject: "inconnu").error_keys.should eq(["auth.errors.federated.unknown_identity"])
  end

  it "refuse un jeton d'un autre émetteur, pour une autre audience, expiré, au mauvais nonce ou mal signé" do
    transport = OidcSpec.configure
    linked_user
    other = Jose::JWK::RSAKey.generate(2048)
    fresh = -> { Auth.begin_federated_login(anonymous, "cabinet") }
    invalid = ["auth.errors.federated.invalid"]
    callback(fresh.call, transport, issuer: "https://autre.test").error_keys.should eq(invalid)
    callback(fresh.call, transport, audience: "autre-client").error_keys.should eq(invalid)
    callback(fresh.call, transport, audience: [OidcSpec::CLIENT_ID, "autre"]).error_keys.should eq(invalid)
    callback(fresh.call, transport, expires: Time.utc - 10.minutes).error_keys.should eq(invalid)
    callback(fresh.call, transport, nonce: "rejoue").error_keys.should eq(invalid)
    callback(fresh.call, transport, key: other).error_keys.should eq(["auth.errors.federated.signature"])
    # azp égal au client : plusieurs audiences admises.
    callback(fresh.call, transport, audience: [OidcSpec::CLIENT_ID, "autre"], azp: OidcSpec::CLIENT_ID).success?.should be_true
  end

  it "refuse un state inattendu, un refus du fournisseur et un rejeu de la requête" do
    transport = OidcSpec.configure
    linked_user
    start = Auth.begin_federated_login(anonymous, "cabinet")
    Auth.login_federated(anonymous, "cabinet", start.request_id, {"code" => "c", "state" => "forge"})
      .error_keys.should eq(["auth.errors.federated.invalid"])
    again = Auth.begin_federated_login(anonymous, "cabinet")
    Auth.login_federated(anonymous, "cabinet", again.request_id, {"error" => "access_denied", "state" => OidcSpec.query(again)["state"]})
      .error_keys.should eq(["auth.errors.federated.denied"])
    third = Auth.begin_federated_login(anonymous, "cabinet")
    callback(third, transport).success?.should be_true
    callback(third, transport).error_keys.should eq(["auth.errors.login.expired"])
  end

  it "valide les paramètres : obligatoires, HTTPS, portée openid" do
    input = Auth::IdentityProviderInput.new(code: "cabinet", kind: "oidc", name: "Cabinet",
      settings: OidcSpec.settings(token_endpoint: "http://idp.example/token", scopes: "email", client_secret: ""))
    result = Auth.save_identity_provider(AuthSpec.system, input)
    result.errors_for("settings.token_endpoint").map(&.key).should eq(["auth.errors.provider.url"])
    result.errors_for("settings.scopes").map(&.key).should eq(["auth.errors.provider.openid_scope"])
    result.errors_for("settings.client_secret").map(&.key).should eq(["auth.errors.provider.required"])
    ReferentialSpec.expect_translated(result)
    local = input.copy_with(settings: OidcSpec.settings(redirect_uri: "http://demo.partiduo.localhost:8000/cb"))
    Auth.save_identity_provider(AuthSpec.system, local).success?.should be_true
  end
end

describe "Contrat des écrans des fournisseurs d'identité" do
  it "décrit les types enregistrés et leurs paramètres" do
    kinds = Auth.identity_provider_kinds(AuthSpec.system)
    kinds.map(&.kind).should contain("saml")
    oidc = kinds.find! { |kind| kind.kind == "oidc" }
    secret = oidc.settings.find! { |field| field.key == "client_secret" }
    {secret.required, secret.secret, secret.label_key}.should eq({true, true, "auth.provider_settings.client_secret"})
    saml = kinds.find! { |kind| kind.kind == "saml" }
    saml.settings.find!(&.key.==("idp_cert")).multiline.should be_true
    Partiduo::LOCALES.each do |locale|
      I18n.with_locale(locale) do
        kinds.select(&.kind.in?("saml", "oidc")).each do |kind|
          I18n.t(kind.label_key).should_not contain("missing")
          kind.settings.each { |field| I18n.t(field.label_key).should_not contain("missing") }
        end
      end
    end
  end

  it "ne rend jamais un secret, et le garde quand il est laissé vide" do
    OidcSpec.configure
    detail = Auth.identity_provider(AuthSpec.system, "cabinet")
    detail.settings.has_key?("client_secret").should be_false
    detail.secrets_set.should eq(["client_secret"])
    detail.settings["issuer"].should eq(OidcSpec::ISSUER)
    input = Auth::IdentityProviderInput.new(code: "cabinet", kind: "oidc", name: "Cabinet renommé", level: 3,
      settings: OidcSpec.settings(client_secret: ""))
    Auth.save_identity_provider(AuthSpec.system, input).value!.level.should eq(3)
    stored = Partiduo::Auth::Federation.settings_of(Partiduo::Auth::IdentityProvider.filter(code: "cabinet").first!)
    stored["client_secret"].should eq(OidcSpec::SECRET)
    kind = Auth.save_identity_provider(AuthSpec.system, input.copy_with(kind: "saml"))
    kind.errors_for("kind").map(&.key).should eq(["auth.errors.provider.kind_immutable"])
    expect_raises(Partiduo::Api::NotFound) { Auth.identity_provider(AuthSpec.system, "absent") }
    expect_raises(Partiduo::Api::Forbidden) { Auth.identity_provider_kinds(actor_with) }
  end
end
