# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private def anonymous
  Partiduo::Api::Actor.anonymous
end

private def federated_login(response : String, start : Partiduo::Api::Auth::FederatedStartView, code : String = "idp")
  Partiduo::Api::Auth.login_federated(anonymous, code, start.request_id, {"SAMLResponse" => response})
end

private def accountant_with_identity(subject : String = "expert@cabinet.example") : Int64
  created = AuthSpec.create_user("expert@cabinet.example", role: "accountant", first_name: "Claire", last_name: "Expert")
  Partiduo::Api::Auth.link_federated_identity(AuthSpec.system, created.user.id, "idp", subject).value!
  created.user.id
end

describe "SAML intégré (ADR-002 D3 : authentification fédérée, autorisation locale)" do
  it "valide la configuration du fournisseur" do
    input = Partiduo::Api::Auth::IdentityProviderInput.new(code: "Mauvais Code", kind: "saml", name: "",
      level: 5, settings: {"idp_cert" => "pas un certificat"})
    result = Partiduo::Api::Auth.save_identity_provider(AuthSpec.system, input)
    result.errors_for("code").map(&.key).should eq(["auth.errors.provider.code_invalid"])
    result.errors_for("level").map(&.key).should eq(["auth.errors.provider.level_invalid"])
    result.errors_for("settings.idp_entity_id").map(&.key).should eq(["auth.errors.provider.required"])
    result.errors_for("settings.idp_cert").map(&.key).should eq(["auth.errors.provider.certificate"])

    kind = Partiduo::Api::Auth.save_identity_provider(AuthSpec.system,
      Partiduo::Api::Auth::IdentityProviderInput.new(code: "x", kind: "cas", name: "CAS"))
    kind.errors_for("kind").map(&.key).should eq(["auth.errors.provider.kind_unsupported"])
  end

  it "construit la requête vers le fournisseur et liste les fournisseurs actifs" do
    SamlSpec.configure
    Partiduo::Api::Auth.login_providers(anonymous).map(&.code).should eq(["idp"])
    start = Partiduo::Api::Auth.begin_federated_login(anonymous, "idp")
    start.redirect_url.should start_with("https://idp.example.test/sso?SAMLRequest=")
    start.redirect_url.should contain("RelayState=idp")
    SamlSpec.request_id(start).should start_with("_")
  end

  it "connecte l'utilisateur local rattaché à l'identité, au niveau déclaré du fournisseur" do
    SamlSpec.configure(level: 2)
    user_id = accountant_with_identity
    start = Partiduo::Api::Auth.begin_federated_login(anonymous, "idp")
    view = federated_login(SamlSpec.response(SamlSpec.request_id(start)), start).value!
    view.user_id.should eq(user_id)
    view.level.should eq(2)
    view.required_level.should eq(3) # comptable : niveau 3
    view.elevation_required.should be_true
    Partiduo::Api::Auth.session(view.session_token!).try(&.method).should eq("federated")
  end

  it "accorde les droits locaux quand le fournisseur est déclaré de niveau 3" do
    SamlSpec.configure(level: 3)
    accountant_with_identity
    start = Partiduo::Api::Auth.begin_federated_login(anonymous, "idp")
    view = federated_login(SamlSpec.response(SamlSpec.request_id(start)), start).value!
    view.elevation_required.should be_false
    AuthSpec.actor(view.session_token!).can?("auth.users.manage").should be_false
  end

  it "refuse une identité inconnue : pas d'auto-provisionnement" do
    SamlSpec.configure
    accountant_with_identity
    start = Partiduo::Api::Auth.begin_federated_login(anonymous, "idp")
    result = federated_login(SamlSpec.response(SamlSpec.request_id(start), "inconnu@ailleurs.example"), start)
    result.error_keys.should eq(["auth.errors.federated.unknown_identity"])
    Partiduo::Auth::User.filter(email: "inconnu@ailleurs.example").exists?.should be_false
  end

  it "refuse une réponse non signée, ou signée par une autre clé, même avec son certificat embarqué" do
    SamlSpec.configure
    accountant_with_identity
    start = Partiduo::Api::Auth.begin_federated_login(anonymous, "idp")
    federated_login(SamlSpec.response(SamlSpec.request_id(start), signed: false), start)
      .error_keys.should eq(["auth.errors.federated.signature"])

    start = Partiduo::Api::Auth.begin_federated_login(anonymous, "idp")
    forged = SamlSpec.response(SamlSpec.request_id(start), signer: SamlSpec.attacker, embed: SamlSpec.attacker)
    federated_login(forged, start).error_keys.should eq(["auth.errors.federated.signature"])
  end

  it "refuse l'emballage de signature (seconde assertion non signée)" do
    SamlSpec.configure
    accountant_with_identity
    start = Partiduo::Api::Auth.begin_federated_login(anonymous, "idp")
    wrapped = SamlSpec.response(SamlSpec.request_id(start), "autre@cabinet.example", wrap_subject: "expert@cabinet.example")
    federated_login(wrapped, start).error_keys.should eq(["auth.errors.federated.signature"])
  end

  it "refuse une réponse altérée après signature" do
    SamlSpec.configure
    accountant_with_identity("expert@cabinet.example")
    start = Partiduo::Api::Auth.begin_federated_login(anonymous, "idp")
    xml = String.new(Base64.decode(SamlSpec.response(SamlSpec.request_id(start), "autre@cabinet.example")))
    tampered = Base64.strict_encode(xml.gsub(">autre@cabinet.example<", ">expert@cabinet.example<"))
    federated_login(tampered, start).error_keys.should eq(["auth.errors.federated.signature"])
  end

  it "refuse une réponse à une autre requête, rejouée, expirée, ou pour une autre audience" do
    SamlSpec.configure
    accountant_with_identity
    start = Partiduo::Api::Auth.begin_federated_login(anonymous, "idp")
    federated_login(SamlSpec.response("_autre_requete"), start).error_keys.should eq(["auth.errors.federated.invalid"])

    start = Partiduo::Api::Auth.begin_federated_login(anonymous, "idp")
    response = SamlSpec.response(SamlSpec.request_id(start))
    federated_login(response, start).success?.should be_true
    federated_login(response, start).error_keys.should eq(["auth.errors.login.expired"])

    start = Partiduo::Api::Auth.begin_federated_login(anonymous, "idp")
    expired = SamlSpec.response(SamlSpec.request_id(start), not_before: Time.utc - 1.hour, not_after: Time.utc - 10.minutes)
    federated_login(expired, start).error_keys.should eq(["auth.errors.federated.invalid"])

    start = Partiduo::Api::Auth.begin_federated_login(anonymous, "idp")
    other = SamlSpec.response(SamlSpec.request_id(start), audience: "https://autre.example/sp")
    federated_login(other, start).error_keys.should eq(["auth.errors.federated.invalid"])

    start = Partiduo::Api::Auth.begin_federated_login(anonymous, "idp")
    failed = SamlSpec.response(SamlSpec.request_id(start), status: "urn:oasis:names:tc:SAML:2.0:status:Requester")
    federated_login(failed, start).error_keys.should eq(["auth.errors.federated.invalid"])
  end

  it "refuse une DTD (entités externes)" do
    SamlSpec.configure
    start = Partiduo::Api::Auth.begin_federated_login(anonymous, "idp")
    xml = %(<?xml version="1.0"?><!DOCTYPE r [<!ENTITY x SYSTEM "file:///etc/passwd">]><samlp:Response xmlns:samlp="urn:oasis:names:tc:SAML:2.0:protocol">&x;</samlp:Response>)
    federated_login(Base64.strict_encode(xml), start).error_keys.should eq(["auth.errors.federated.invalid"])
  end

  it "refuse un utilisateur révoqué, même authentifié par le fournisseur" do
    SamlSpec.configure(level: 3)
    user_id = accountant_with_identity
    Partiduo::Api::Auth.revoke_access(AuthSpec.system, user_id)
    start = Partiduo::Api::Auth.begin_federated_login(anonymous, "idp")
    federated_login(SamlSpec.response(SamlSpec.request_id(start)), start).error_keys
      .should eq(["auth.errors.login.access_denied"])
  end

  it "refuse de rattacher deux fois la même identité" do
    SamlSpec.configure
    accountant_with_identity
    other = AuthSpec.create_user("bob@example.com", first_name: "Bob", last_name: "Durand")
    Partiduo::Api::Auth.link_federated_identity(AuthSpec.system, other.user.id, "idp", "expert@cabinet.example")
      .errors_for("subject").map(&.key).should eq(["auth.errors.federated.subject_taken"])
    Partiduo::Api::Auth.link_federated_identity(AuthSpec.system, other.user.id, "inconnu", "bob")
      .errors_for("provider").map(&.key).should eq(["auth.errors.provider.unknown"])
  end
end

# Fournisseur OIDC fictif : prouve que l'interface est pluggable.
class FakeOidcAdapter < Partiduo::Auth::Federation::Adapter
  def kind : String
    "oidc"
  end

  def validate_settings(settings : Hash(String, String)) : Array(Partiduo::Api::FieldError)
    settings["issuer"]?.presence ? [] of Partiduo::Api::FieldError : [Partiduo::Api::FieldError.new("settings.issuer", "auth.errors.provider.required")]
  end

  def begin_login(provider : Partiduo::Auth::IdentityProvider, settings : Hash(String, String)) : Partiduo::Auth::Federation::Start
    Partiduo::Auth::Federation::Start.new("#{settings["issuer"]}/authorize?state=x", "nonce-1")
  end

  def complete_login(provider : Partiduo::Auth::IdentityProvider, settings : Hash(String, String),
                     payload : Hash(String, String), request_id : String) : Partiduo::Auth::Federation::Identity
    raise Partiduo::Auth::Federation::Error.new("auth.errors.federated.invalid") unless payload["nonce"]? == request_id
    Partiduo::Auth::Federation::Identity.new(subject: payload["sub"])
  end
end

describe "Interface pluggable des fournisseurs d'identité (OIDC)" do
  it "accepte un type enregistré par Federation.register" do
    Partiduo::Auth::Federation.register(FakeOidcAdapter.new)
    Partiduo::Auth::Federation.kinds.should contain("oidc")
    input = Partiduo::Api::Auth::IdentityProviderInput.new(code: "oidc", kind: "oidc", name: "OIDC",
      settings: {"issuer" => "https://oidc.example.test"})
    Partiduo::Api::Auth.save_identity_provider(AuthSpec.system, input).success?.should be_true
    created = AuthSpec.create_user
    Partiduo::Api::Auth.link_federated_identity(AuthSpec.system, created.user.id, "oidc", "sub-42").success?.should be_true

    start = Partiduo::Api::Auth.begin_federated_login(anonymous, "oidc")
    view = Partiduo::Api::Auth.login_federated(anonymous, "oidc", start.request_id, {"nonce" => "nonce-1", "sub" => "sub-42"}).value!
    view.user_id.should eq(created.user.id)
  end
end
