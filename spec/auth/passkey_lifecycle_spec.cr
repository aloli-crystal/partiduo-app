# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Compléments de couverture des passkeys (ADR-002 D2, D5, D-AUTH-008) :
# défis liés à l'utilisateur, doublons, compteur et date d'usage, gestion des
# clés, politique d'instance, compte révoqué.

private def with_env(name : String, value : String?, &)
  previous = ENV[name]?
  value.nil? ? ENV.delete(name) : (ENV[name] = value)
  yield
ensure
  previous.nil? ? ENV.delete(name) : (ENV[name] = previous)
end

describe "Passkeys : enrôlement" do
  it "exclut à l'enrôlement suivant les clés déjà enregistrées" do
    AuthSpec.create_user
    actor = AuthSpec.actor(AuthSpec.session_token)
    authenticator, _enrollment = AuthSpec.enroll_passkey(actor)
    options = Partiduo::Api::Auth.begin_passkey_registration(actor)
    options.exclude_credentials.should eq([AuthSpec.b64(authenticator.credential_id)])
  end

  it "refuse d'enregistrer deux fois la même clé" do
    AuthSpec.create_user
    actor = AuthSpec.actor(AuthSpec.session_token)
    authenticator, _enrollment = AuthSpec.enroll_passkey(actor)
    options = Partiduo::Api::Auth.begin_passkey_registration(actor)
    Partiduo::Api::Auth.finish_passkey_registration(actor, authenticator.register(options)).error_keys
      .should eq(["auth.errors.passkey.already_registered"])
    Partiduo::Auth::Passkey.all.count.should eq(1)
  end

  it "lie le défi d'enregistrement à l'utilisateur et ne l'accepte qu'une fois" do
    AuthSpec.create_user
    AuthSpec.create_user("bob@example.com", first_name: "Bob", last_name: "Durand")
    alice = AuthSpec.actor(AuthSpec.session_token)
    bob = AuthSpec.actor(AuthSpec.session_token("bob@example.com"))

    bob_options = Partiduo::Api::Auth.begin_passkey_registration(bob)
    Partiduo::Api::Auth.finish_passkey_registration(alice, AuthSpec::Authenticator.new.register(bob_options))
      .error_keys.should eq(["auth.errors.passkey.challenge"])

    options = Partiduo::Api::Auth.begin_passkey_registration(alice)
    Partiduo::Api::Auth.finish_passkey_registration(alice, AuthSpec::Authenticator.new.register(options)).success?.should be_true
    Partiduo::Api::Auth.finish_passkey_registration(alice, AuthSpec::Authenticator.new.register(options))
      .error_keys.should eq(["auth.errors.passkey.challenge"])
  end

  it "refuse un défi d'authentification présenté à l'enregistrement" do
    AuthSpec.create_user
    actor = AuthSpec.actor(AuthSpec.session_token)
    get_options = Partiduo::Api::Auth.begin_passkey_login(Partiduo::Api::Actor.anonymous)
    create_options = Partiduo::Api::Auth.begin_passkey_registration(actor)
    forged = AuthSpec::Authenticator.new.register(create_options).copy_with(challenge_id: get_options.challenge_id)
    Partiduo::Api::Auth.finish_passkey_registration(actor, forged).error_keys.should eq(["auth.errors.passkey.challenge"])
  end

  it "refuse une réponse illisible" do
    AuthSpec.create_user
    actor = AuthSpec.actor(AuthSpec.session_token)
    options = Partiduo::Api::Auth.begin_passkey_registration(actor)
    input = AuthSpec::Authenticator.new.register(options).copy_with(attestation_object: "***")
    Partiduo::Api::Auth.finish_passkey_registration(actor, input).error_keys.should eq(["auth.errors.passkey.invalid"])
  end

  it "consigne enregistrements réussis et refusés" do
    created = AuthSpec.create_user
    actor = AuthSpec.actor(AuthSpec.session_token)
    options = Partiduo::Api::Auth.begin_passkey_registration(actor)
    Partiduo::Api::Auth.finish_passkey_registration(actor,
      AuthSpec::Authenticator.new.register(options, origin: "https://evil.test"))
    AuthSpec.enroll_passkey(actor)
    events = Partiduo::Api::Auth.audit_events(AuthSpec.system, Partiduo::Api::Auth::AuditQuery.new(user_id: created.user.id))
      .map { |event| {event.action, event.state} }
    events.should contain({"passkey.register", "FAIL"})
    events.should contain({"passkey.register", "SUCCESS"})
  end

  it "n'admet que les origines de la liste exacte quand PARTIDUO_WEBAUTHN_ORIGINS est posée" do
    with_env("PARTIDUO_WEBAUTHN_ORIGINS", "https://compta.example.org, https://demo.partiduo.localhost") do
      Partiduo::Auth::Config.origin_allowed?("https://compta.example.org").should be_true
      Partiduo::Auth::Config.origin_allowed?("https://demo.partiduo.localhost").should be_true
      Partiduo::Auth::Config.origin_allowed?("http://demo.partiduo.localhost:8000").should be_false
    end
    Partiduo::Auth::Config.origin_allowed?("https://demo.partiduo.localhost/chemin").should be_false
    Partiduo::Auth::Config.origin_allowed?("ftp://demo.partiduo.localhost").should be_false
    Partiduo::Auth::Config.origin_allowed?("pas une origine").should be_false
  end
end

describe "Passkeys : connexion" do
  it "met à jour le compteur de signature et la date de dernier usage" do
    AuthSpec.create_user
    authenticator, _enrollment = AuthSpec.enroll_passkey(AuthSpec.actor(AuthSpec.session_token))
    Partiduo::Auth::Passkey.all.first!.last_used_at.should be_nil
    authenticator.sign_count = 7_u32
    AuthSpec.passkey_login(authenticator).success?.should be_true
    passkey = Partiduo::Auth::Passkey.all.first!
    passkey.sign_count.should eq(7)
    passkey.last_used_at.should_not be_nil
  end

  it "refuse un défi expiré" do
    AuthSpec.create_user
    authenticator, _enrollment = AuthSpec.enroll_passkey(AuthSpec.actor(AuthSpec.session_token))
    options = Partiduo::Api::Auth.begin_passkey_login(Partiduo::Api::Actor.anonymous)
    Partiduo::Auth::Challenge.all.update(expires_at: Time.utc - 1.minute)
    Partiduo::Api::Auth.login_passkey(Partiduo::Api::Actor.anonymous, authenticator.assert(options))
      .error_keys.should eq(["auth.errors.passkey.challenge"])
  end

  it "refuse la connexion d'un compte révoqué, et la consigne" do
    created = AuthSpec.create_user
    AuthSpec.create_user("patron@societe.example", first_name: "Paul", last_name: "Patron")
    authenticator, _enrollment = AuthSpec.enroll_passkey(AuthSpec.actor(AuthSpec.session_token))
    admin = AuthSpec.actor(AuthSpec.session_token("patron@societe.example"))
    Partiduo::Api::Auth.revoke_access(admin, created.user.id).success?.should be_true

    AuthSpec.passkey_login(authenticator).error_keys.should eq(["auth.errors.login.access_denied"])
    Partiduo::Api::Auth.audit_events(AuthSpec.system, Partiduo::Api::Auth::AuditQuery.new(user_id: created.user.id))
      .any? { |event| event.action == "login.passkey" && event.state == "FAIL" && event.detail == "access_denied" }
      .should be_true
  end

  it "ne dit rien de l'utilisateur quand la clé est inconnue" do
    AuthSpec.create_user
    AuthSpec.passkey_login(AuthSpec::Authenticator.new).error_keys.should eq(["auth.errors.passkey.unknown"])
    Partiduo::Api::Auth.audit_events(AuthSpec.system).find! { |event| event.action == "login.passkey" }
      .user_id.should be_nil
  end
end

describe "Passkeys : gestion des clés" do
  it "renomme une clé de l'utilisateur, tronquée à cent caractères" do
    AuthSpec.create_user
    actor = AuthSpec.actor(AuthSpec.session_token)
    _authenticator, enrollment = AuthSpec.enroll_passkey(actor)
    view = Partiduo::Api::Auth.rename_passkey(actor, enrollment.passkey.id, "  Téléphone  ").value!
    view.name.should eq("Téléphone")
    Partiduo::Api::Auth.rename_passkey(actor, enrollment.passkey.id, "x" * 150).value!.name.size.should eq(100)
  end

  it "ne laisse ni renommer ni retirer la clé d'un autre utilisateur" do
    AuthSpec.create_user
    AuthSpec.create_user("bob@example.com", first_name: "Bob", last_name: "Durand")
    _authenticator, enrollment = AuthSpec.enroll_passkey(AuthSpec.actor(AuthSpec.session_token("bob@example.com")))
    alice_authenticator, _alice = AuthSpec.enroll_passkey(AuthSpec.actor(AuthSpec.session_token))
    alice = AuthSpec.actor(AuthSpec.passkey_login(alice_authenticator).value!.session_token!)

    expect_raises(Partiduo::Api::NotFound) { Partiduo::Api::Auth.rename_passkey(alice, enrollment.passkey.id, "À moi") }
    expect_raises(Partiduo::Api::NotFound) { Partiduo::Api::Auth.remove_passkey(alice, enrollment.passkey.id) }
    Partiduo::Auth::Passkey.all.count.should eq(2)
  end

  it "refuse la gestion des clés à un anonyme" do
    expect_raises(Partiduo::Api::Forbidden) do
      Partiduo::Api::Auth.begin_passkey_registration(Partiduo::Api::Actor.anonymous)
    end
    expect_raises(Partiduo::Api::Forbidden) do
      Partiduo::Api::Auth.security_overview(Partiduo::Api::Actor.anonymous)
    end
  end

  it "rend au mot de passe seul un compte qui retire sa dernière passkey" do
    AuthSpec.create_user
    authenticator, enrollment = AuthSpec.enroll_passkey(AuthSpec.actor(AuthSpec.session_token))
    level3 = AuthSpec.actor(AuthSpec.passkey_login(authenticator).value!.session_token!)
    Partiduo::Api::Auth.remove_passkey(level3, enrollment.passkey.id).success?.should be_true
    AuthSpec.login.value!.authenticated?.should be_true
    AuthSpec.passkey_login(authenticator).error_keys.should eq(["auth.errors.passkey.unknown"])
  end
end

describe "Passkeys : politique de l'instance" do
  it "refuse enrôlement et connexion par passkey quand l'instance ne les admet pas" do
    provision_instance(settings_input(auth_methods: ["password"]))
    AuthSpec.create_user
    token = AuthSpec.session_token
    actor = AuthSpec.actor(token)
    expect_raises(Partiduo::Api::Forbidden) { Partiduo::Api::Auth.begin_passkey_registration(actor) }

    # Clé enrôlée avant le changement de politique : elle ne sert plus.
    Partiduo::Api::Core.update_settings(Partiduo::Api::Actor.system, settings_input(auth_methods: %w[password passkey]))
      .success?.should be_true
    authenticator, _enrollment = AuthSpec.enroll_passkey(actor)
    Partiduo::Api::Core.update_settings(Partiduo::Api::Actor.system, settings_input(auth_methods: ["password"]))
      .success?.should be_true
    AuthSpec.passkey_login(authenticator).error_keys.should eq(["auth.errors.login.method_disabled"])

    overview = Partiduo::Api::Auth.security_overview(actor)
    overview.suggest_passkey.should be_false
    overview.missing.should_not contain("passkey")
  end
end
