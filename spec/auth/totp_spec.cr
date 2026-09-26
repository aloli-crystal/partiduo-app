# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private def second_factor(pending : String, code : String, kind : String = "totp")
  Partiduo::Api::Auth.login_second_factor(Partiduo::Api::Actor.anonymous,
    Partiduo::Api::Auth::SecondFactorInput.new(pending_token: pending, code: code, kind: kind))
end

describe "TOTP (RFC 6238) et codes de récupération" do
  it "émet un secret aux paramètres par défaut de la RFC 6238, avec QR code et base32" do
    AuthSpec.create_user
    actor = AuthSpec.actor(AuthSpec.session_token)
    enrollment = Partiduo::Api::Auth.begin_totp_enrollment(actor)

    enrollment.algorithm.should eq("SHA1")
    enrollment.digits.should eq(6)
    enrollment.period.should eq(30)
    enrollment.secret_base32.should match(/\A[A-Z2-7]{32}\z/) # 160 bits
    enrollment.issuer.should eq("Partiduo")
    enrollment.provisioning_uri.should start_with("otpauth://totp/Partiduo:alice%40example.com?secret=#{enrollment.secret_base32}")
    enrollment.provisioning_uri.should contain("algorithm=SHA1&digits=6&period=30")

    qr = enrollment.qr_code
    qr.size.should eq(qr.modules.size)
    qr.size.should eq(Partiduo::Auth::QrCode.encode(enrollment.provisioning_uri).size)
    qr.modules[0][0..6].should eq([true] * 7) # motif de repérage
  end

  it "active le TOTP après un code valide et génère les codes de récupération" do
    created = AuthSpec.create_user
    actor = AuthSpec.actor(AuthSpec.session_token)
    enrollment = Partiduo::Api::Auth.begin_totp_enrollment(actor)
    Partiduo::Api::Auth.confirm_totp_enrollment(actor, "000000").error_keys.should eq(["auth.errors.login.invalid_code"])
    AuthSpec.user_model(created.user.id).totp_enabled?.should be_false

    codes = Partiduo::Api::Auth.confirm_totp_enrollment(actor, AuthSpec.totp_code(enrollment.secret_base32)).value!.codes
    codes.size.should eq(10)
    codes.uniq.size.should eq(10)
    codes.first.should match(/\A[A-Z2-9]{4}-[A-Z2-9]{4}-[A-Z2-9]{4}-[A-Z2-9]{4}\z/)
    user = AuthSpec.user_model(created.user.id)
    user.totp_enabled?.should be_true
    user.last_otp_counter.should_not be_nil
  end

  it "exige le second facteur et monte la session au niveau 2" do
    AuthSpec.create_user
    secret, _codes = AuthSpec.enable_totp(AuthSpec.actor(AuthSpec.session_token))

    step = AuthSpec.login.value!
    step.status.should eq("second_factor_required")
    step.session_token.should be_nil
    step.second_factors.should eq(["totp", "recovery_code"])

    final = second_factor(step.pending_token!, AuthSpec.totp_code(secret)).value!
    final.authenticated?.should be_true
    final.level.should eq(2)
    AuthSpec.actor(final.session_token!).level.should eq(2)
  end

  it "refuse de rejouer un code déjà accepté (last_otp_counter repassé en after:)" do
    created = AuthSpec.create_user
    secret, _codes = AuthSpec.enable_totp(AuthSpec.actor(AuthSpec.session_token))
    code = AuthSpec.totp_code(secret)

    second_factor(AuthSpec.login.value!.pending_token!, code).success?.should be_true
    counter = AuthSpec.user_model(created.user.id).last_otp_counter

    replay = second_factor(AuthSpec.login.value!.pending_token!, code)
    replay.error_keys.should eq(["auth.errors.login.invalid_code"])
    replay.errors.first.field.should eq("code")
    AuthSpec.user_model(created.user.id).last_otp_counter.should eq(counter)
  end

  it "compte les codes faux comme des échecs (blocage au dixième)" do
    created = AuthSpec.create_user
    AuthSpec.enable_totp(AuthSpec.actor(AuthSpec.session_token))
    pending = AuthSpec.login.value!.pending_token!
    2.times { second_factor(pending, "000000").error_keys.should eq(["auth.errors.login.invalid_code"]) }
    AuthSpec.user_model(created.user.id).failed_attempts.should eq(2)
  end

  it "accepte chaque code de récupération une seule fois" do
    AuthSpec.create_user
    _secret, codes = AuthSpec.enable_totp(AuthSpec.actor(AuthSpec.session_token))

    ok = second_factor(AuthSpec.login.value!.pending_token!, codes.first.downcase.delete('-'), "recovery_code")
    ok.value!.level.should eq(2)
    reused = second_factor(AuthSpec.login.value!.pending_token!, codes.first, "recovery_code")
    reused.error_keys.should eq(["auth.errors.login.invalid_code"])

    security = Partiduo::Api::Auth.security_overview(AuthSpec.actor(ok.value!.session_token!))
    security.recovery_codes_remaining.should eq(9)
  end

  it "réserve la désactivation du TOTP et le renouvellement des codes à une session de niveau 2" do
    AuthSpec.create_user
    level1 = AuthSpec.actor(AuthSpec.session_token)
    secret, _codes = AuthSpec.enable_totp(level1)
    expect_raises(Partiduo::Api::Auth::ElevationRequired) { Partiduo::Api::Auth.regenerate_recovery_codes(level1) }

    step = AuthSpec.login.value!
    level2 = AuthSpec.actor(second_factor(step.pending_token!, AuthSpec.totp_code(secret)).value!.session_token!)
    Partiduo::Api::Auth.regenerate_recovery_codes(level2).value!.codes.size.should eq(10)
    Partiduo::Api::Auth.disable_totp(level2, AuthSpec.totp_code(secret, Time.utc + 30.seconds)).success?.should be_true
    AuthSpec.login.value!.authenticated?.should be_true
  end

  it "élève une session de mot de passe par un code TOTP" do
    AuthSpec.create_user
    token = AuthSpec.session_token
    secret, _codes = AuthSpec.enable_totp(AuthSpec.actor(token))
    view = Partiduo::Api::Auth.elevate_with_totp(Partiduo::Api::Actor.anonymous, token, AuthSpec.totp_code(secret)).value!
    view.level.should eq(2)
    AuthSpec.actor(token).level.should eq(2)
  end

  it "expire le jeton de second facteur" do
    AuthSpec.create_user
    secret, _codes = AuthSpec.enable_totp(AuthSpec.actor(AuthSpec.session_token))
    pending = AuthSpec.login.value!.pending_token!
    Partiduo::Auth::Challenge.all.update(expires_at: Time.utc - 1.minute)
    second_factor(pending, AuthSpec.totp_code(secret)).error_keys.should eq(["auth.errors.login.expired"])
  end
end
