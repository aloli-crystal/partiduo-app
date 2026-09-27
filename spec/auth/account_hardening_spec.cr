# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Relecture des lots P, 0 et 1 : limitation des tentatives dans la sécurité
# du compte, sessions coupées par un changement de sécurité, acteur sous le
# niveau exigé (D-AUTH-012, D-AUTH-013).

private BAD_PASSWORD = "Mauvais42MotDePasse"

private def failures(user_id : Int64) : Int32
  (AuthSpec.user_model(user_id).failed_attempts || 0).to_i32
end

private def change_password(token : String, current : String, new_password : String = "Nouveau42MotDePasseSur")
  Partiduo::Api::Auth.change_password(AuthSpec.actor(token),
    Partiduo::Api::Auth::ChangePasswordInput.new(new_password, current))
end

describe "Sécurité du compte : limitation des tentatives (D-AUTH-012)" do
  it "temporise la vérification du mot de passe actuel" do
    created = AuthSpec.create_user
    token = AuthSpec.session_token
    3.times { change_password(token, BAD_PASSWORD).error_keys.should eq(["auth.errors.password.current_invalid"]) }
    failures(created.user.id).should eq(3)
    change_password(token, AuthSpec::PASSWORD).error_keys.should eq(["auth.errors.login.throttled"])
    failures(created.user.id).should eq(3)
  end

  it "bloque au dixième échec et coupe alors les sessions" do
    created = AuthSpec.create_user
    token = AuthSpec.session_token
    keys = [] of String
    10.times do
      keys = change_password(token, BAD_PASSWORD).error_keys
      AuthSpec.user_model(created.user.id).tap(&.last_failed_at=(Time.utc - 1.hour)).save!
    end
    keys.should eq(["auth.errors.login.locked"])
    AuthSpec.actor(token).authenticated?.should be_false
  end

  it "temporise la désactivation du TOTP" do
    created = AuthSpec.create_user
    token = AuthSpec.session_token
    secret, _codes = AuthSpec.enable_totp(AuthSpec.actor(token))
    Partiduo::Api::Auth.elevate_with_totp(Partiduo::Api::Actor.anonymous, token, AuthSpec.totp_code(secret)).success?.should be_true
    actor = AuthSpec.actor(token)
    3.times { Partiduo::Api::Auth.disable_totp(actor, "000000").error_keys.should eq(["auth.errors.login.invalid_code"]) }
    Partiduo::Api::Auth.disable_totp(actor, AuthSpec.totp_code(secret, Time.utc + 30.seconds)).error_keys
      .should eq(["auth.errors.login.throttled"])
    failures(created.user.id).should eq(3)
  end
end

describe "Sécurité du compte : sessions coupées par un changement de sécurité" do
  it "coupe les autres sessions au changement de mot de passe, garde la courante" do
    AuthSpec.create_user
    current = AuthSpec.session_token
    stolen = AuthSpec.session_token
    change_password(current, AuthSpec::PASSWORD).success?.should be_true
    AuthSpec.actor(current).authenticated?.should be_true
    AuthSpec.actor(stolen).authenticated?.should be_false
  end

  it "coupe toutes les sessions quand l'administrateur change le mot de passe ou l'adresse" do
    created = AuthSpec.create_user
    token = AuthSpec.session_token
    input = Partiduo::Api::Auth::UserInput.new(email: "alice.martin@example.com", first_name: "Alice",
      last_name: "Martin", role: "member", profile_id: AuthSpec.profile_id)
    Partiduo::Api::Auth.update_user(AuthSpec.system, created.user.id, input).success?.should be_true
    AuthSpec.actor(token).authenticated?.should be_false
  end

  it "coupe les autres sessions au retrait d'une passkey et à la désactivation du TOTP" do
    AuthSpec.create_user
    token = AuthSpec.session_token
    other = AuthSpec.session_token
    secret, _codes = AuthSpec.enable_totp(AuthSpec.actor(token))
    Partiduo::Api::Auth.elevate_with_totp(Partiduo::Api::Actor.anonymous, token, AuthSpec.totp_code(secret)).success?.should be_true
    Partiduo::Api::Auth.disable_totp(AuthSpec.actor(token), AuthSpec.totp_code(secret, Time.utc + 30.seconds)).success?.should be_true
    AuthSpec.actor(token).authenticated?.should be_true
    AuthSpec.actor(other).authenticated?.should be_false
  end
end

describe "Acteur sous le niveau exigé (D-AUTH-013)" do
  it "n'ouvre que les opérations du compte à une session sous le niveau exigé" do
    AuthSpec.create_user("expert@cabinet.example", role: "accountant")
    actor = AuthSpec.actor(AuthSpec.session_token("expert@cabinet.example"))
    actor.authenticated?.should be_true
    actor.elevated.should be_false

    expect_raises(Partiduo::Api::Forbidden) { Partiduo::Api::Core.settings(actor) }
    expect_raises(Partiduo::Api::Forbidden) { Partiduo::Api::Core.fiscal_years(actor) }
    expect_raises(Partiduo::Api::Forbidden) { Partiduo::Api::Core.currencies(actor) }
    Partiduo::Api::Modules.menu(actor)
    Partiduo::Api::Auth.security_overview(actor).session_level.should eq(1)
  end

  it "n'ouvre que les opérations du compte à la session d'enrôlement" do
    created = AuthSpec.create_user(password: nil)
    invitation = created.invitation.token
    view = Partiduo::Api::Auth.accept_invitation(Partiduo::Api::Actor.anonymous, invitation).value!
    actor = AuthSpec.actor(view.session_token!)
    actor.elevated.should be_false
    expect_raises(Partiduo::Api::Forbidden) { Partiduo::Api::Core.settings(actor) }
    Partiduo::Api::Auth.security_overview(actor).session_level.should eq(0)
  end
end
