# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Compléments de couverture du niveau exigé (ADR-002 D2, D4, D6 ;
# D-AUTH-003, D-AUTH-010) : le rôle comptable n'obtient ses droits qu'au
# niveau 3, quel que soit le chemin suivi ; le niveau minimum de l'instance
# s'applique aux autres utilisateurs.

private EXPERT = "expert@cabinet.example"

private def create_accountant(profile : String? = "ADMIN") : Partiduo::Api::Auth::UserCreatedView
  AuthSpec.create_user(EXPERT, role: "accountant", profile: profile, first_name: "Claire", last_name: "Expert")
end

private def second_factor(pending : String, code : String, kind : String = "totp")
  Partiduo::Api::Auth.login_second_factor(Partiduo::Api::Actor.anonymous,
    Partiduo::Api::Auth::SecondFactorInput.new(pending_token: pending, code: code, kind: kind))
end

describe "Comptable : niveau 3 exigé (ADR-002 D4)" do
  it "exige le niveau 3 même quand la politique de l'instance se contente du niveau 1" do
    provision_instance(settings_input(auth_minimum_level: 1))
    created = create_accountant
    Partiduo::Auth::Levels.required(AuthSpec.user_model(created.user.id)).should eq(3)
    Partiduo::Api::Auth.session(AuthSpec.session_token(EXPERT)).try(&.required_level).should eq(3)
  end

  it "reste sans droits après mot de passe et TOTP (niveau 2)" do
    create_accountant
    password_session = AuthSpec.session_token(EXPERT)
    secret, _codes = AuthSpec.enable_totp(AuthSpec.actor(password_session)) # enrôlement permis sans droits

    step = AuthSpec.login(EXPERT).value!
    step.status.should eq("second_factor_required")
    step.required_level.should eq(3)
    view = second_factor(step.pending_token!, AuthSpec.totp_code(secret)).value!
    view.level.should eq(2)
    view.elevation_required.should be_true

    actor = AuthSpec.actor(view.session_token!)
    actor.level.should eq(2)
    actor.permissions.should be_empty
    Partiduo::Api::Auth.ledger_access(actor, 1_i64).should eq("X")
    expect_raises(Partiduo::Api::Forbidden) { Partiduo::Api::Auth.users(actor) }
  end

  it "reste sans droits après une élévation par TOTP, puis les obtient par passkey" do
    create_accountant
    token = AuthSpec.session_token(EXPERT)
    secret, _codes = AuthSpec.enable_totp(AuthSpec.actor(token))
    authenticator, _enrollment = AuthSpec.enroll_passkey(AuthSpec.actor(token))

    anonymous = Partiduo::Api::Actor.anonymous
    totp = Partiduo::Api::Auth.elevate_with_totp(anonymous, token, AuthSpec.totp_code(secret)).value!
    totp.level.should eq(2)
    totp.elevation_required.should be_true
    AuthSpec.actor(token).permissions.should be_empty

    options = Partiduo::Api::Auth.begin_passkey_login(anonymous)
    passkey = Partiduo::Api::Auth.elevate_with_passkey(anonymous, token, authenticator.assert(options)).value!
    passkey.level.should eq(3)
    passkey.elevation_required.should be_false
    actor = AuthSpec.actor(token)
    actor.permissions.should_not be_empty
    actor.permissions.none? { |name| Partiduo::Auth::Permissions.administrative?(name) }.should be_true
  end

  it "reste sans droits après un code de récupération (niveau 2)" do
    create_accountant
    _authenticator, enrollment = AuthSpec.enroll_passkey(AuthSpec.actor(AuthSpec.session_token(EXPERT)))
    step = AuthSpec.login(EXPERT).value!
    view = second_factor(step.pending_token!, enrollment.recovery_codes.first, "recovery_code").value!
    view.level.should eq(2)
    AuthSpec.actor(view.session_token!).permissions.should be_empty
  end

  it "ne garde que les permissions non administratives de son profil, même cochées" do
    profile = Partiduo::Api::Auth.create_profile(AuthSpec.system, Partiduo::Api::Auth::ProfileInput.new(
      name: "Cabinet", permissions: ["auth.users.manage", "auth.audit.view", "core.settings.manage", "cards.card.read"])).value!
    input = Partiduo::Api::Auth::UserInput.new(email: EXPERT, first_name: "Claire", last_name: "Expert",
      role: "accountant", profile_id: profile.id, password: AuthSpec::PASSWORD)
    Partiduo::Api::Auth.create_user(AuthSpec.system, input).value!

    token = AuthSpec.session_token(EXPERT)
    authenticator, _enrollment = AuthSpec.enroll_passkey(AuthSpec.actor(token))
    actor = AuthSpec.actor(AuthSpec.passkey_login(authenticator).value!.session_token!)
    actor.permissions.should eq(Set{"cards.card.read"})
  end

  it "est soumis aux droits par journal même avec le profil administrateur" do
    created = create_accountant
    token = AuthSpec.session_token(EXPERT)
    authenticator, _enrollment = AuthSpec.enroll_passkey(AuthSpec.actor(token))
    actor = AuthSpec.actor(AuthSpec.passkey_login(authenticator).value!.session_token!)
    Partiduo::Api::Auth.ledger_access(actor, 1_i64).should eq("W") # sécurité des journaux désactivée

    system = AuthSpec.system
    Partiduo::Api::Auth.set_ledger_security(system, created.user.id, true).success?.should be_true
    Partiduo::Api::Auth.set_ledger_access(system, created.user.id, 1_i64, "R").success?.should be_true
    Partiduo::Api::Auth.ledger_access(actor, 1_i64).should eq("R")
    Partiduo::Api::Auth.ledger_access(actor, 2_i64).should eq("X")
  end

  it "perd ses droits de niveau 3 quand la date de fin est dépassée, session ouverte comprise" do
    created = create_accountant
    token = AuthSpec.session_token(EXPERT)
    authenticator, _enrollment = AuthSpec.enroll_passkey(AuthSpec.actor(token))
    level3 = AuthSpec.passkey_login(authenticator).value!.session_token!
    AuthSpec.actor(level3).permissions.should_not be_empty

    AuthSpec.user_model(created.user.id).tap { |user| user.access_ends_on = Time.utc.at_beginning_of_day - 1.day }.save!
    AuthSpec.actor(level3).authenticated?.should be_false
    AuthSpec.passkey_login(authenticator).error_keys.should eq(["auth.errors.login.access_denied"])
  end

  it "retrouve le niveau 1 quand il redevient membre" do
    created = create_accountant
    token = AuthSpec.session_token(EXPERT)
    AuthSpec.actor(token).permissions.should be_empty
    input = Partiduo::Api::Auth::UserInput.new(email: EXPERT, first_name: "Claire", last_name: "Expert",
      role: "member", profile_id: AuthSpec.profile_id("ADMIN"))
    Partiduo::Api::Auth.update_user(AuthSpec.system, created.user.id, input).value!.role.should eq("member")

    AuthSpec.actor(token).authenticated?.should be_false # sessions coupées au changement de rôle
    view = AuthSpec.login(EXPERT).value!
    view.required_level.should eq(1)
    AuthSpec.actor(view.session_token!).can?("auth.users.manage").should be_true
  end
end

describe "Niveau minimum de l'instance (ADR-002 D2)" do
  it "prive de droits une session sous le niveau exigé, jusqu'à l'élévation" do
    provision_instance(settings_input(auth_minimum_level: 2))
    AuthSpec.create_user
    view = AuthSpec.login.value!
    view.required_level.should eq(2)
    view.elevation_required.should be_true
    token = view.session_token!
    AuthSpec.actor(token).permissions.should be_empty

    secret, _codes = AuthSpec.enable_totp(AuthSpec.actor(token))
    Partiduo::Api::Auth.elevate_with_totp(Partiduo::Api::Actor.anonymous, token,
      AuthSpec.totp_code(secret, Time.utc + 30.seconds)).value!.elevation_required.should be_false
    AuthSpec.actor(token).can?("auth.users.manage").should be_true
  end

  it "donne tous ses droits à une session de niveau 3 sous une politique de niveau 3" do
    provision_instance(settings_input(auth_minimum_level: 3))
    AuthSpec.create_user
    token = AuthSpec.session_token
    AuthSpec.actor(token).permissions.should be_empty
    authenticator, _enrollment = AuthSpec.enroll_passkey(AuthSpec.actor(token))
    AuthSpec.actor(AuthSpec.passkey_login(authenticator).value!.session_token!).can?("auth.users.manage").should be_true
  end
end
