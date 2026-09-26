# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private def with_env(name : String, value : String?, &)
  previous = ENV[name]?
  value.nil? ? ENV.delete(name) : (ENV[name] = value)
  yield
ensure
  previous.nil? ? ENV.delete(name) : (ENV[name] = previous)
end

describe "Passkeys (WebAuthn, ADR-002 D2, D5)" do
  it "annonce ES256 et RS256, credential découvrable, vérification exigée, RP ID partiduo.localhost" do
    AuthSpec.create_user
    options = Partiduo::Api::Auth.begin_passkey_registration(AuthSpec.actor(AuthSpec.session_token))
    options.rp_id.should eq("partiduo.localhost")
    options.algorithms.should eq([-7_i64, -257_i64])
    options.resident_key.should eq("required")
    options.user_verification.should eq("required")
    options.attestation.should eq("none")
    options.user_name.should eq("alice@example.com")
    options.user_display_name.should eq("Alice Martin")
    options.challenge.size.should eq(43) # 32 octets en base64url
    options.exclude_credentials.should be_empty
  end

  it "rend le RP ID configurable" do
    with_env("PARTIDUO_RP_ID", "compta.example") do
      Partiduo::Auth::Config.rp_id.should eq("compta.example")
      Partiduo::Auth::Config.origin_allowed?("https://client1.compta.example").should be_true
      Partiduo::Auth::Config.origin_allowed?("http://client1.compta.example").should be_false
    end
    with_env("PARTIDUO_DOMAIN", "partiduo.example") do
      Partiduo::Auth::Config.rp_id.should eq("partiduo.example")
    end
    Partiduo::Auth::Config.origin_allowed?("http://demo.partiduo.localhost:8000").should be_true
    Partiduo::Auth::Config.origin_allowed?("https://partiduo.localhost.evil.test").should be_false
    Partiduo::Auth::Config.origin_allowed?("https://evilpartiduo.localhost").should be_false
  end

  {% for algorithm in [{"ES256", false}, {"RS256", true}] %}
    it "enrôle une passkey {{ algorithm[0].id }} avec des codes de récupération, puis connecte au niveau 3" do
      created = AuthSpec.create_user
      actor = AuthSpec.actor(AuthSpec.session_token)
      authenticator, enrollment = AuthSpec.enroll_passkey(actor, rsa: {{ algorithm[1] }})
      enrollment.passkey.name.should eq("Portable")
      enrollment.passkey.transports.should eq(["internal", "hybrid"])
      enrollment.recovery_codes.size.should eq(10) # jamais une passkey seule (D7)
      Partiduo::Auth::Passkey.all.first!.cose_algorithm.should eq({{ algorithm[1] ? -257 : -7 }})

      result = AuthSpec.passkey_login(authenticator)
      view = result.value!
      view.level.should eq(3)
      view.suggest_passkey.should be_false
      AuthSpec.actor(view.session_token!).user_id.should eq(created.user.id)
    end
  {% end %}

  it "accepte un compteur de signature toujours nul (authentificateurs Apple)" do
    AuthSpec.create_user
    authenticator, _enrollment = AuthSpec.enroll_passkey(AuthSpec.actor(AuthSpec.session_token))
    authenticator.sign_count.should eq(0)
    3.times { AuthSpec.passkey_login(authenticator).success?.should be_true }
  end

  it "refuse un compteur qui recule après avoir été non nul (clé clonée)" do
    AuthSpec.create_user
    authenticator, _enrollment = AuthSpec.enroll_passkey(AuthSpec.actor(AuthSpec.session_token))
    authenticator.sign_count = 5_u32
    AuthSpec.passkey_login(authenticator).success?.should be_true
    Partiduo::Auth::Passkey.all.first!.sign_count.should eq(5)
    authenticator.sign_count = 3_u32
    AuthSpec.passkey_login(authenticator).error_keys.should eq(["auth.errors.passkey.cloned"])
  end

  it "exige la vérification de l'utilisateur (UV)" do
    AuthSpec.create_user
    actor = AuthSpec.actor(AuthSpec.session_token)
    authenticator = AuthSpec::Authenticator.new
    options = Partiduo::Api::Auth.begin_passkey_registration(actor)
    input = authenticator.register(options, flags: AuthSpec::FLAG_UP | AuthSpec::FLAG_AT)
    Partiduo::Api::Auth.finish_passkey_registration(actor, input).error_keys.should eq(["auth.errors.passkey.invalid"])

    authenticator, _enrollment = AuthSpec.enroll_passkey(actor)
    options = Partiduo::Api::Auth.begin_passkey_login(Partiduo::Api::Actor.anonymous)
    assertion = authenticator.assert(options, flags: AuthSpec::FLAG_UP)
    Partiduo::Api::Auth.login_passkey(Partiduo::Api::Actor.anonymous, assertion).error_keys
      .should eq(["auth.errors.passkey.invalid"])
  end

  it "refuse une origine hors du domaine, un autre RP ID, une signature fausse, un défi rejoué" do
    AuthSpec.create_user
    actor = AuthSpec.actor(AuthSpec.session_token)
    authenticator = AuthSpec::Authenticator.new
    options = Partiduo::Api::Auth.begin_passkey_registration(actor)
    Partiduo::Api::Auth.finish_passkey_registration(actor, authenticator.register(options, origin: "https://partiduo.evil.test"))
      .error_keys.should eq(["auth.errors.passkey.origin"])
    options = Partiduo::Api::Auth.begin_passkey_registration(actor)
    Partiduo::Api::Auth.finish_passkey_registration(actor, authenticator.register(options, rp_id: "evil.test"))
      .error_keys.should eq(["auth.errors.passkey.invalid"])

    authenticator, _enrollment = AuthSpec.enroll_passkey(actor)
    anonymous = Partiduo::Api::Actor.anonymous
    options = Partiduo::Api::Auth.begin_passkey_login(anonymous)
    Partiduo::Api::Auth.login_passkey(anonymous, authenticator.assert(options, tamper: true)).error_keys
      .should eq(["auth.errors.passkey.invalid"])

    options = Partiduo::Api::Auth.begin_passkey_login(anonymous)
    assertion = authenticator.assert(options)
    Partiduo::Api::Auth.login_passkey(anonymous, assertion).success?.should be_true
    Partiduo::Api::Auth.login_passkey(anonymous, assertion).error_keys.should eq(["auth.errors.passkey.challenge"])
  end

  it "refuse une clé inconnue et une poignée d'utilisateur qui ne correspond pas" do
    AuthSpec.create_user
    AuthSpec.create_user("bob@example.com", first_name: "Bob", last_name: "Durand")
    alice, _enrollment = AuthSpec.enroll_passkey(AuthSpec.actor(AuthSpec.session_token))
    bob_actor = AuthSpec.actor(AuthSpec.session_token("bob@example.com"))
    bob_handle = Partiduo::Api::Auth.begin_passkey_registration(bob_actor).user_handle

    AuthSpec.passkey_login(AuthSpec::Authenticator.new).error_keys.should eq(["auth.errors.passkey.unknown"])
    options = Partiduo::Api::Auth.begin_passkey_login(Partiduo::Api::Actor.anonymous)
    Partiduo::Api::Auth.login_passkey(Partiduo::Api::Actor.anonymous, alice.assert(options, user_handle: bob_handle))
      .error_keys.should eq(["auth.errors.passkey.unknown"])
  end

  it "exige le TOTP (ou un code de récupération) pour le mot de passe dès qu'une passkey est active" do
    AuthSpec.create_user
    _authenticator, enrollment = AuthSpec.enroll_passkey(AuthSpec.actor(AuthSpec.session_token))
    step = AuthSpec.login.value!
    step.status.should eq("second_factor_required")
    step.second_factors.should eq(["recovery_code"])

    final = Partiduo::Api::Auth.login_second_factor(Partiduo::Api::Actor.anonymous,
      Partiduo::Api::Auth::SecondFactorInput.new(pending_token: step.pending_token!,
        code: enrollment.recovery_codes.first, kind: "recovery_code"))
    final.value!.level.should eq(2)
  end

  it "élève une session par passkey (parcours d'élévation)" do
    AuthSpec.create_user
    token = AuthSpec.session_token
    authenticator, _enrollment = AuthSpec.enroll_passkey(AuthSpec.actor(token))
    options = Partiduo::Api::Auth.begin_passkey_login(Partiduo::Api::Actor.anonymous)
    view = Partiduo::Api::Auth.elevate_with_passkey(Partiduo::Api::Actor.anonymous, token, authenticator.assert(options)).value!
    view.level.should eq(3)
    view.method.should eq("passkey")
    AuthSpec.actor(token).level.should eq(3)
  end

  it "n'élève pas une session avec la passkey d'un autre utilisateur" do
    AuthSpec.create_user
    AuthSpec.create_user("bob@example.com", first_name: "Bob", last_name: "Durand")
    bob, _enrollment = AuthSpec.enroll_passkey(AuthSpec.actor(AuthSpec.session_token("bob@example.com")))
    alice_token = AuthSpec.session_token
    options = Partiduo::Api::Auth.begin_passkey_login(Partiduo::Api::Actor.anonymous)
    Partiduo::Api::Auth.elevate_with_passkey(Partiduo::Api::Actor.anonymous, alice_token, bob.assert(options))
      .error_keys.should eq(["auth.errors.passkey.unknown"])
  end

  it "affiche le niveau atteint et ce qui manque (page sécurité du compte)" do
    AuthSpec.create_user
    token = AuthSpec.session_token
    before = Partiduo::Api::Auth.security_overview(AuthSpec.actor(token))
    before.achievable_level.should eq(1)
    before.session_level.should eq(1)
    before.missing.should eq(["totp", "passkey"])
    before.methods.should eq(["password"])
    before.suggest_passkey.should be_true

    Partiduo::Api::Auth.dismiss_passkey_prompt(AuthSpec.actor(token)).success?.should be_true
    Partiduo::Api::Auth.security_overview(AuthSpec.actor(token)).suggest_passkey.should be_false

    AuthSpec.enroll_passkey(AuthSpec.actor(token))
    after = Partiduo::Api::Auth.security_overview(AuthSpec.actor(token))
    after.achievable_level.should eq(3)
    after.methods.should eq(["password", "passkey"])
    after.missing.should eq(["totp"])
    after.passkeys.size.should eq(1)
    after.recovery_codes_remaining.should eq(10)
  end

  it "retire une passkey depuis une session de niveau 2 au moins" do
    AuthSpec.create_user
    token = AuthSpec.session_token
    authenticator, enrollment = AuthSpec.enroll_passkey(AuthSpec.actor(token))
    expect_raises(Partiduo::Api::Auth::ElevationRequired) do
      Partiduo::Api::Auth.remove_passkey(AuthSpec.actor(token), enrollment.passkey.id)
    end
    level3 = AuthSpec.actor(AuthSpec.passkey_login(authenticator).value!.session_token!)
    Partiduo::Api::Auth.remove_passkey(level3, enrollment.passkey.id).success?.should be_true
    Partiduo::Auth::Passkey.all.count.should eq(0)
  end
end
