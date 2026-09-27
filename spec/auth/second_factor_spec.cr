# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Compléments de couverture du second facteur (D-AUTH-007) : anti-rejeu du
# TOTP (`last_otp_counter` repassé en `after:`) et cycle de vie des codes de
# récupération (ADR-002 D7).

private def second_factor(pending : String, code : String, kind : String = "totp")
  Partiduo::Api::Auth.login_second_factor(Partiduo::Api::Actor.anonymous,
    Partiduo::Api::Auth::SecondFactorInput.new(pending_token: pending, code: code, kind: kind))
end

private def pending_token : String
  AuthSpec.login.value!.pending_token!
end

# Session de niveau 2 ouverte par un code TOTP de l'instant `time`.
private def level2_token(secret : String, time : Time = Time.utc) : String
  second_factor(pending_token, AuthSpec.totp_code(secret, time)).value!.session_token!
end

describe "TOTP : anti-rejeu (D-AUTH-007)" do
  it "refuse à la connexion le code qui a servi à confirmer l'enrôlement" do
    created = AuthSpec.create_user
    actor = AuthSpec.actor(AuthSpec.session_token)
    enrollment = Partiduo::Api::Auth.begin_totp_enrollment(actor)
    code = AuthSpec.totp_code(enrollment.secret_base32)
    Partiduo::Api::Auth.confirm_totp_enrollment(actor, code).success?.should be_true

    second_factor(pending_token, code).error_keys.should eq(["auth.errors.login.invalid_code"])
    AuthSpec.user_model(created.user.id).failed_attempts.should eq(1) # un rejeu compte comme un échec
  end

  it "refuse un code antérieur au dernier accepté, même dans la fenêtre de dérive" do
    AuthSpec.create_user
    secret, _codes = AuthSpec.enable_totp(AuthSpec.actor(AuthSpec.session_token))
    level2_token(secret)
    second_factor(pending_token, AuthSpec.totp_code(secret, Time.utc - 30.seconds)).error_keys
      .should eq(["auth.errors.login.invalid_code"])
  end

  it "accepte le code de la période suivante (dérive d'horloge), puis refuse celui de la période courante" do
    created = AuthSpec.create_user
    secret, _codes = AuthSpec.enable_totp(AuthSpec.actor(AuthSpec.session_token))
    level2_token(secret, Time.utc + 30.seconds)
    counter = AuthSpec.user_model(created.user.id).last_otp_counter

    second_factor(pending_token, AuthSpec.totp_code(secret)).error_keys.should eq(["auth.errors.login.invalid_code"])
    AuthSpec.user_model(created.user.id).last_otp_counter.should eq(counter)
  end

  it "refuse un code hors de la fenêtre de dérive" do
    AuthSpec.create_user
    secret, _codes = AuthSpec.enable_totp(AuthSpec.actor(AuthSpec.session_token))
    second_factor(pending_token, AuthSpec.totp_code(secret, Time.utc - 2.minutes)).error_keys
      .should eq(["auth.errors.login.invalid_code"])
    second_factor(pending_token, AuthSpec.totp_code(secret, Time.utc + 2.minutes)).error_keys
      .should eq(["auth.errors.login.invalid_code"])
  end

  it "partage le compteur entre connexion, élévation et désactivation" do
    AuthSpec.create_user
    password_token = AuthSpec.session_token
    secret, _codes = AuthSpec.enable_totp(AuthSpec.actor(password_token))
    code = AuthSpec.totp_code(secret)
    token = second_factor(pending_token, code).value!.session_token!

    Partiduo::Api::Auth.elevate_with_totp(Partiduo::Api::Actor.anonymous, password_token, code).error_keys
      .should eq(["auth.errors.login.invalid_code"])
    Partiduo::Api::Auth.disable_totp(AuthSpec.actor(token), code).error_keys
      .should eq(["auth.errors.login.invalid_code"])
    AuthSpec.login.value!.status.should eq("second_factor_required") # toujours actif
  end

  it "n'accepte le jeton de second facteur qu'une fois" do
    AuthSpec.create_user
    secret, _codes = AuthSpec.enable_totp(AuthSpec.actor(AuthSpec.session_token))
    pending = pending_token
    second_factor(pending, AuthSpec.totp_code(secret)).success?.should be_true
    second_factor(pending, AuthSpec.totp_code(secret, Time.utc + 30.seconds)).error_keys
      .should eq(["auth.errors.login.expired"])
  end

  it "refuse une sorte de second facteur inconnue" do
    AuthSpec.create_user
    secret, _codes = AuthSpec.enable_totp(AuthSpec.actor(AuthSpec.session_token))
    second_factor(pending_token, AuthSpec.totp_code(secret), "sms").error_keys
      .should eq(["auth.errors.login.invalid_code"])
  end

  it "garde le secret actif tant qu'un nouvel enrôlement n'est pas confirmé" do
    AuthSpec.create_user
    token = AuthSpec.session_token
    secret, _codes = AuthSpec.enable_totp(AuthSpec.actor(token))
    # Remplacer un TOTP actif exige le niveau 2.
    expect_raises(Partiduo::Api::Auth::ElevationRequired) { Partiduo::Api::Auth.begin_totp_enrollment(AuthSpec.actor(token)) }
    Partiduo::Api::Auth.elevate_with_totp(Partiduo::Api::Actor.anonymous, token,
      AuthSpec.totp_code(secret)).success?.should be_true
    actor = AuthSpec.actor(token)
    replacement = Partiduo::Api::Auth.begin_totp_enrollment(actor)
    replacement.secret_base32.should_not eq(secret)
    Partiduo::Api::Auth.pending_totp_enrollment(actor).try(&.secret_base32).should eq(replacement.secret_base32)

    second_factor(pending_token, AuthSpec.totp_code(replacement.secret_base32)).error_keys
      .should eq(["auth.errors.login.invalid_code"])
    second_factor(pending_token, AuthSpec.totp_code(secret, Time.utc + 30.seconds)).success?.should be_true
  end

  it "refuse de remplacer le TOTP actif depuis une session de niveau 1" do
    AuthSpec.create_user
    token = AuthSpec.session_token
    secret, _codes = AuthSpec.enable_totp(AuthSpec.actor(token))
    expect_raises(Partiduo::Api::Auth::ElevationRequired) do
      Partiduo::Api::Auth.confirm_totp_enrollment(AuthSpec.actor(token), AuthSpec.totp_code(secret))
    end
  end

  it "ne donne le second facteur TOTP qu'à un compte qui l'a confirmé" do
    created = AuthSpec.create_user
    enrollment = Partiduo::Api::Auth.begin_totp_enrollment(AuthSpec.actor(AuthSpec.session_token))
    AuthSpec.user_model(created.user.id).totp_enabled?.should be_false
    view = AuthSpec.login.value!
    view.authenticated?.should be_true # le mot de passe suffit encore
    Partiduo::Api::Auth.elevate_with_totp(Partiduo::Api::Actor.anonymous, view.session_token!,
      AuthSpec.totp_code(enrollment.secret_base32)).error_keys.should eq(["auth.errors.login.invalid_code"])
  end
end

describe "Codes de récupération (ADR-002 D7)" do
  it "ne conserve que l'empreinte des codes" do
    created = AuthSpec.create_user
    _secret, codes = AuthSpec.enable_totp(AuthSpec.actor(AuthSpec.session_token))
    digests = Partiduo::Auth::RecoveryCode.filter(user_id: created.user.id).map(&.code_digest.to_s)
    digests.size.should eq(10)
    digests.all?(/\A[0-9a-f]{64}\z/).should be_true
    codes.each do |code|
      digests.should_not contain(code)
      digests.should contain(Partiduo::Auth::Secrets.digest(Partiduo::Auth::RecoveryCodes.normalize(code)))
    end
  end

  it "accepte un code saisi avec espaces et minuscules, et ouvre une session « recovery_code » de niveau 2" do
    AuthSpec.create_user
    _secret, codes = AuthSpec.enable_totp(AuthSpec.actor(AuthSpec.session_token))
    typed = " " + codes.first.downcase.gsub('-', ' ') + " "
    view = second_factor(pending_token, typed, "recovery_code").value!
    view.level.should eq(2)
    Partiduo::Api::Auth.session(view.session_token!).try(&.method).should eq("recovery_code")
  end

  it "refuse le code d'un autre utilisateur" do
    AuthSpec.create_user
    AuthSpec.create_user("bob@example.com", first_name: "Bob", last_name: "Durand")
    AuthSpec.enable_totp(AuthSpec.actor(AuthSpec.session_token))
    _bob_secret, bob_codes = AuthSpec.enable_totp(AuthSpec.actor(AuthSpec.session_token("bob@example.com")))
    second_factor(pending_token, bob_codes.first, "recovery_code").error_keys
      .should eq(["auth.errors.login.invalid_code"])
  end

  it "invalide les anciens codes quand on les régénère" do
    AuthSpec.create_user
    secret, old_codes = AuthSpec.enable_totp(AuthSpec.actor(AuthSpec.session_token))
    level2 = AuthSpec.actor(level2_token(secret))
    new_codes = Partiduo::Api::Auth.regenerate_recovery_codes(level2).value!.codes
    (new_codes & old_codes).should be_empty

    second_factor(pending_token, old_codes.last, "recovery_code").error_keys.should eq(["auth.errors.login.invalid_code"])
    second_factor(pending_token, new_codes.last, "recovery_code").success?.should be_true
    Partiduo::Api::Auth.security_overview(level2).recovery_codes_remaining.should eq(9)
  end

  it "n'en génère pas de nouveaux à l'enrôlement d'une passkey s'il en reste" do
    AuthSpec.create_user
    token = AuthSpec.session_token
    _secret, codes = AuthSpec.enable_totp(AuthSpec.actor(token))
    _authenticator, enrollment = AuthSpec.enroll_passkey(AuthSpec.actor(token))
    enrollment.recovery_codes.should be_empty
    second_factor(pending_token, codes.first, "recovery_code").success?.should be_true
  end

  it "signale leur épuisement et retire le repli du mot de passe" do
    AuthSpec.create_user
    token = AuthSpec.session_token
    _secret, codes = AuthSpec.enable_totp(AuthSpec.actor(token))
    codes.each { |code| second_factor(pending_token, code, "recovery_code").success?.should be_true }

    AuthSpec.login.value!.second_factors.should eq(["totp"])
    overview = Partiduo::Api::Auth.security_overview(AuthSpec.actor(token))
    overview.recovery_codes_remaining.should eq(0)
    overview.missing.should contain("recovery_codes")
  end

  it "exige la passkey quand le mot de passe n'a plus de second facteur possible" do
    created = AuthSpec.create_user
    token = AuthSpec.session_token
    authenticator, enrollment = AuthSpec.enroll_passkey(AuthSpec.actor(token))
    enrollment.recovery_codes.each { |code| second_factor(pending_token, code, "recovery_code").success?.should be_true }

    AuthSpec.login.error_keys.should eq(["auth.errors.login.passkey_required"])
    AuthSpec.user_model(created.user.id).failed_attempts.should eq(0) # pas un échec : le mot de passe était bon
    level3 = AuthSpec.actor(AuthSpec.passkey_login(authenticator).value!.session_token!)
    Partiduo::Api::Auth.regenerate_recovery_codes(level3).value!.codes.size.should eq(10)
    AuthSpec.login.value!.second_factors.should eq(["recovery_code"])
  end

  it "consigne l'enrôlement, l'usage et la régénération" do
    created = AuthSpec.create_user
    secret, codes = AuthSpec.enable_totp(AuthSpec.actor(AuthSpec.session_token))
    second_factor(pending_token, codes.first, "recovery_code")
    Partiduo::Api::Auth.regenerate_recovery_codes(AuthSpec.actor(level2_token(secret)))
    actions = Partiduo::Api::Auth.audit_events(AuthSpec.system, Partiduo::Api::Auth::AuditQuery.new(user_id: created.user.id))
      .map(&.action)
    actions.should contain("totp.enable")
    actions.should contain("login.second_factor")
    actions.should contain("recovery_codes.generate")
  end
end
