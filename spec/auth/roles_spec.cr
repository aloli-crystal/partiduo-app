# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private def create_accountant(password : String? = AuthSpec::PASSWORD, access_ends_on : Time? = nil)
  AuthSpec.create_user("expert@cabinet.example", role: "accountant", profile: "ADMIN",
    first_name: "Claire", last_name: "Expert", password: password, access_ends_on: access_ends_on)
end

describe "Rôle comptable (ADR-002 D4)" do
  it "est nominatif : prénom et nom obligatoires" do
    input = Partiduo::Api::Auth::UserInput.new(email: "cabinet@example.com", role: "accountant")
    result = Partiduo::Api::Auth.create_user(AuthSpec.system, input)
    result.errors_for("first_name").map(&.key).should eq(["auth.errors.user.nominative"])
    result.errors_for("last_name").map(&.key).should eq(["auth.errors.user.nominative"])
  end

  it "exige le niveau 3 : une session par mot de passe n'a aucun droit" do
    create_accountant
    view = AuthSpec.login("expert@cabinet.example").value!
    view.required_level.should eq(3)
    view.level.should eq(1)
    view.elevation_required.should be_true
    actor = AuthSpec.actor(view.session_token!)
    actor.authenticated?.should be_true
    actor.permissions.should be_empty
    expect_raises(Partiduo::Api::Forbidden) { Partiduo::Api::Auth.audit_events(actor) }
    Partiduo::Api::Auth.ledger_access(actor, 1_i64).should eq("X")
  end

  it "obtient ses droits après élévation par passkey, sans les droits administratifs" do
    create_accountant
    token = AuthSpec.login("expert@cabinet.example").value!.session_token!
    authenticator, _enrollment = AuthSpec.enroll_passkey(AuthSpec.actor(token)) # enrôlement permis sans droits
    view = AuthSpec.passkey_login(authenticator).value!
    view.level.should eq(3)
    view.elevation_required.should be_false

    actor = AuthSpec.actor(view.session_token!)
    actor.can?("accounting.entry.post").should eq(Partiduo::Modules.active?("ACCOUNTING"))
    actor.permissions.select { |name| Partiduo::Auth::Permissions.administrative?(name) }.should be_empty
    actor.can?("auth.users.manage").should be_false
    actor.can?("core.settings.manage").should be_false
    Partiduo::Api::Auth.ledger_access(actor, 1_i64).should eq("W")
  end

  it "classe comme administratives les permissions AUTH et les .manage du socle" do
    Partiduo::Auth::Permissions.administrative?("auth.users.manage").should be_true
    Partiduo::Auth::Permissions.administrative?("core.settings.manage").should be_true
    Partiduo::Auth::Permissions.administrative?("core.users.manage").should be_true
    Partiduo::Auth::Permissions.administrative?("accounting.entry.post").should be_false
  end

  it "perd l'accès après sa date de fin" do
    created = create_accountant(access_ends_on: Time.utc.at_beginning_of_day)
    AuthSpec.login("expert@cabinet.example").success?.should be_true # jusqu'au jour inclus
    token = AuthSpec.login("expert@cabinet.example").value!.session_token!

    user = AuthSpec.user_model(created.user.id)
    user.access_ends_on = Time.utc.at_beginning_of_day - 1.day
    user.save!
    AuthSpec.login("expert@cabinet.example").error_keys.should eq(["auth.errors.login.access_denied"])
    AuthSpec.actor(token).authenticated?.should be_false
  end

  it "refuse une date de fin déjà passée" do
    input = Partiduo::Api::Auth::UserInput.new(email: "expert@cabinet.example", role: "accountant",
      first_name: "Claire", last_name: "Expert", access_ends_on: Time.utc - 2.days)
    Partiduo::Api::Auth.create_user(AuthSpec.system, input).errors_for("access_ends_on").map(&.key)
      .should eq(["auth.errors.user.access_ends_on_past"])
  end

  it "est révoqué immédiatement, toutes sessions coupées, puis rouvert par la société" do
    created = create_accountant
    token = AuthSpec.login("expert@cabinet.example").value!.session_token!
    admin = AuthSpec.create_user("patron@societe.example", first_name: "Paul", last_name: "Patron")
    admin_actor = AuthSpec.actor(AuthSpec.session_token("patron@societe.example"))

    Partiduo::Api::Auth.revoke_access(admin_actor, created.user.id).value!.revoked.should be_true
    AuthSpec.actor(token).authenticated?.should be_false
    AuthSpec.login("expert@cabinet.example").error_keys.should eq(["auth.errors.login.access_denied"])
    Partiduo::Api::Auth.revoke_access(admin_actor, admin.user.id).error_keys.should eq(["auth.errors.user.self"])

    Partiduo::Api::Auth.restore_access(admin_actor, created.user.id).value!.revoked.should be_false
    AuthSpec.login("expert@cabinet.example").success?.should be_true
    events = Partiduo::Api::Auth.audit_events(admin_actor, Partiduo::Api::Auth::AuditQuery.new(state: "ADMIN"))
    events.map(&.action).should contain("user.revoke")
    events.find! { |event| event.action == "user.revoke" }.user_label.should eq("Paul Patron <patron@societe.example>")
  end

  it "rouvre l'accès d'un utilisateur qui a perdu ses moyens par une invitation" do
    created = create_accountant(password: nil)
    AuthSpec.login("expert@cabinet.example").error_keys.should eq(["auth.errors.login.invalid_credentials"])
    invitation = Partiduo::Api::Auth.issue_invitation(AuthSpec.system, created.user.id)
    view = Partiduo::Api::Auth.accept_invitation(Partiduo::Api::Actor.anonymous, invitation.token).value!
    view.level.should eq(0)
    view.elevation_required.should be_true
    Partiduo::Api::Auth.accept_invitation(Partiduo::Api::Actor.anonymous, invitation.token).error_keys
      .should eq(["auth.errors.token.invalid"])

    enrollment_actor = AuthSpec.actor(view.session_token!)
    enrollment_actor.permissions.should be_empty
    authenticator, _enrollment = AuthSpec.enroll_passkey(enrollment_actor)
    AuthSpec.passkey_login(authenticator).value!.level.should eq(3)
  end
end

describe "Utilisateurs (ADR-002 D1, D6)" do
  it "crée un utilisateur sans mot de passe, avec une invitation : la passkey d'abord" do
    created = AuthSpec.create_user(password: nil)
    created.user.has_password.should be_false
    created.invitation.purpose.should eq("invitation")
    created.invitation.expires_at.should be > Time.utc + 6.days

    token = Partiduo::Api::Auth.accept_invitation(Partiduo::Api::Actor.anonymous, created.invitation.token).value!.session_token!
    actor = AuthSpec.actor(token)
    Partiduo::Api::Auth.security_overview(actor).missing.should eq(["passkey"])
    # Mot de passe en repli, sans « mot de passe actuel » dans une session d'enrôlement.
    Partiduo::Api::Auth.change_password(actor, Partiduo::Api::Auth::ChangePasswordInput.new(new_password: AuthSpec::PASSWORD))
      .success?.should be_true
    AuthSpec.login.success?.should be_true
  end

  it "valide l'adresse, son unicité, le rôle, la langue et le profil" do
    AuthSpec.create_user
    input = Partiduo::Api::Auth::UserInput.new(email: "ALICE@example.com", role: "chef", locale: "de", profile_id: 999_i64)
    result = Partiduo::Api::Auth.create_user(AuthSpec.system, input)
    result.errors_for("email").map(&.key).should eq(["auth.errors.user.email_taken"])
    result.errors_for("role").map(&.key).should eq(["auth.errors.user.role_invalid"])
    result.errors_for("locale").map(&.key).should eq(["auth.errors.user.locale_invalid"])
    result.errors_for("profile_id").map(&.key).should eq(["auth.errors.user.profile_unknown"])
    Partiduo::Api::Auth.create_user(AuthSpec.system, Partiduo::Api::Auth::UserInput.new(email: "pas-une-adresse"))
      .error_keys.should eq(["auth.errors.user.email_invalid"])
  end

  it "applique la politique de mot de passe à la création" do
    input = Partiduo::Api::Auth::UserInput.new(email: "bob@example.com", password: "court")
    Partiduo::Api::Auth.create_user(AuthSpec.system, input).errors_for("password").map(&.key)
      .should contain("auth.errors.password.too_short")
  end

  it "réserve l'administration des utilisateurs à auth.users.manage" do
    AuthSpec.create_user
    expect_raises(Partiduo::Api::Forbidden) { Partiduo::Api::Auth.users(actor_with) }
    expect_raises(Partiduo::Api::Forbidden) { Partiduo::Api::Auth.users(Partiduo::Api::Actor.anonymous) }
    Partiduo::Api::Auth.users(actor_with("auth.users.manage")).map(&.email).should eq(["alice@example.com"])
  end

  it "coupe les sessions quand le rôle ou le profil change" do
    created = AuthSpec.create_user
    token = AuthSpec.session_token
    input = Partiduo::Api::Auth::UserInput.new(email: "alice@example.com", first_name: "Alice", last_name: "Martin",
      role: "member", profile_id: AuthSpec.profile_id("ACCOUNTANT"))
    Partiduo::Api::Auth.update_user(AuthSpec.system, created.user.id, input).value!.profile_id
      .should eq(AuthSpec.profile_id("ACCOUNTANT"))
    AuthSpec.actor(token).authenticated?.should be_false
  end

  it "applique le niveau minimum de la politique de l'instance" do
    AuthSpec.create_user
    policy = Partiduo::Auth::Policy.new(%w[password passkey federated], 2, 480)
    user = Partiduo::Auth::User.all.first!
    Partiduo::Auth::Levels.required(user, policy).should eq(2)
    policy.allows?("passkey").should be_true
    Partiduo::Auth::Policy.new(%w[password], 1, 480).allows?("passkey").should be_false
  end
end
