# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private def profile_input(name = "Saisie", permissions = [] of String, admin = false)
  Partiduo::Api::Auth::ProfileInput.new(name: name, permissions: permissions, admin: admin)
end

describe "Profils et droits (héritiers de profile_menu, ADR-003 D4)" do
  it "crée les profils par défaut une seule fois" do
    first = Partiduo::Api::Auth.ensure_default_profiles(AuthSpec.system)
    first.map(&.code).should eq(["ADMIN", "ACCOUNTANT"])
    first.first.admin.should be_true
    accountant = first.last
    accountant.permissions.should_not be_empty
    accountant.permissions.none? { |name| Partiduo::Auth::Permissions.administrative?(name) }.should be_true
    Partiduo::Api::Auth.ensure_default_profiles(AuthSpec.system).map(&.id).should eq(first.map(&.id))
  end

  it "enregistre des permissions déclarées par les manifestes, refuse les inconnues" do
    admin = actor_with("auth.profiles.manage")
    bad = Partiduo::Api::Auth.create_profile(admin, profile_input(permissions: ["auth.audit.view", "faute.de.frappe"]))
    bad.errors_for("permissions[1]").map(&.key).should eq(["auth.errors.profile.permission_unknown"])
    bad.errors_for("permissions[1]").first.params["permission"].should eq("faute.de.frappe")

    view = Partiduo::Api::Auth.create_profile(admin, profile_input(permissions: ["auth.audit.view"])).value!
    view.permissions.should eq(["auth.audit.view"])
    Partiduo::Api::Auth.create_profile(admin, profile_input).errors_for("name").map(&.key)
      .should eq(["auth.errors.profile.name_taken"])
  end

  it "donne à l'acteur les permissions de son profil" do
    profile = Partiduo::Api::Auth.create_profile(AuthSpec.system, profile_input(permissions: ["auth.audit.view"])).value!
    input = Partiduo::Api::Auth::UserInput.new(email: "bob@example.com", first_name: "Bob", last_name: "Durand",
      profile_id: profile.id, password: AuthSpec::PASSWORD)
    Partiduo::Api::Auth.create_user(AuthSpec.system, input).value!
    actor = AuthSpec.actor(AuthSpec.session_token("bob@example.com"))
    actor.permissions.should eq(Set{"auth.audit.view"})
    Partiduo::Api::Auth.audit_events(actor).should_not be_empty
    expect_raises(Partiduo::Api::Forbidden) { Partiduo::Api::Auth.users(actor) }
  end

  it "donne au profil administrateur toutes les permissions des pièces actives" do
    AuthSpec.create_user
    actor = AuthSpec.actor(AuthSpec.session_token)
    actor.permissions.should eq(Partiduo::Modules.active_permissions.to_set)
  end

  it "n'accorde que les permissions des pièces actives" do
    profile = Partiduo::Api::Auth.create_profile(AuthSpec.system,
      profile_input(permissions: ["auth.audit.view", "accounting.entry.post"])).value!
    model = Partiduo::Auth::Profile.get!(id: profile.id)
    with_active_modules("invoicing") do
      Partiduo::Auth::Permissions.of_profile(model).should eq(Set{"auth.audit.view"})
    end
  end

  it "refuse de supprimer un profil attribué" do
    AuthSpec.create_user
    admin = actor_with("auth.profiles.manage")
    Partiduo::Api::Auth.delete_profile(admin, AuthSpec.profile_id).error_keys.should eq(["auth.errors.profile.in_use"])
    Partiduo::Api::Auth.delete_profile(admin, AuthSpec.profile_id("ACCOUNTANT")).success?.should be_true
  end
end

describe "Droits par journal (héritiers de user_sec_jrn)" do
  it "ouvre tous les journaux en écriture tant que la sécurité des journaux est désactivée" do
    created = AuthSpec.create_user(profile: "ACCOUNTANT")
    Partiduo::Api::Auth.user_ledger_access(AuthSpec.system, created.user.id, 7_i64).should eq("W")
  end

  it "applique W, R, X une fois la sécurité activée, X par défaut" do
    created = AuthSpec.create_user(profile: "ACCOUNTANT")
    admin = AuthSpec.system
    Partiduo::Api::Auth.set_ledger_security(admin, created.user.id, true).value!.ledger_security.should be_true
    Partiduo::Api::Auth.user_ledger_access(admin, created.user.id, 7_i64).should eq("X")
    Partiduo::Api::Auth.set_ledger_access(admin, created.user.id, 7_i64, "r").value!.access.should eq("R")
    Partiduo::Api::Auth.set_ledger_access(admin, created.user.id, 8_i64, "W").success?.should be_true
    Partiduo::Api::Auth.set_ledger_access(admin, created.user.id, 9_i64, "Z").error_keys
      .should eq(["auth.errors.ledger.access_invalid"])
    Partiduo::Api::Auth.ledger_accesses(admin, created.user.id).map { |row| {row.ledger_id, row.access} }
      .should eq([{7_i64, "R"}, {8_i64, "W"}])

    actor = AuthSpec.actor(AuthSpec.session_token)
    Partiduo::Api::Auth.ledger_access(actor, 7_i64).should eq("R")
    Partiduo::Api::Auth.ledger_access(actor, 8_i64).should eq("W")
    Partiduo::Api::Auth.ledger_access(actor, 9_i64).should eq("X")
  end

  it "ouvre tous les journaux au profil administrateur, sécurité activée ou non" do
    created = AuthSpec.create_user
    Partiduo::Api::Auth.set_ledger_security(AuthSpec.system, created.user.id, true)
    Partiduo::Api::Auth.user_ledger_access(AuthSpec.system, created.user.id, 7_i64).should eq("W")
  end

  it "refuse en base un droit inconnu" do
    created = AuthSpec.create_user
    expect_raises(Exception, /auth_ledger_access_access_check/) do
      Marten::DB::Connection.default.open do |db|
        db.exec("INSERT INTO auth_ledger_access (user_id, ledger_id, access) VALUES ($1, 1, 'Z')", created.user.id)
      end
    end
  end
end

describe "Journal d'audit nominatif (héritier d'audit_connect)" do
  it "est en ajout seul : la base refuse modification et suppression" do
    AuthSpec.create_user
    AuthSpec.login
    count = Partiduo::Auth::AuditEvent.all.count
    count.should be > 0
    Marten::DB::Connection.default.open do |db|
      expect_raises(Exception, /ajout seul/) { db.exec("UPDATE auth_audit_event SET detail = 'x'") }
      expect_raises(Exception, /ajout seul/) { db.exec("DELETE FROM auth_audit_event") }
    end
    Partiduo::Auth::AuditEvent.all.count.should eq(count)
  end

  it "reçoit les actions nominatives des modules" do
    AuthSpec.create_user
    actor = AuthSpec.actor(AuthSpec.session_token)
    Partiduo::Api::Auth.audit(actor, "entry.post", "ACCOUNTING", "écriture 42")
    event = Partiduo::Api::Auth.audit_events(actor, Partiduo::Api::Auth::AuditQuery.new(module_code: "ACCOUNTING")).first
    event.action.should eq("entry.post")
    event.state.should eq("AUDIT")
    event.user_id.should eq(actor.user_id)
    event.user_label.should eq("Alice Martin <alice@example.com>")
    event.detail.should eq("écriture 42")
  end

  it "refuse l'écriture anonyme et la lecture sans auth.audit.view" do
    expect_raises(Partiduo::Api::Forbidden) do
      Partiduo::Api::Auth.audit(Partiduo::Api::Actor.anonymous, "x", "CORE")
    end
    expect_raises(Partiduo::Api::Forbidden) { Partiduo::Api::Auth.audit_events(actor_with) }
  end
end
