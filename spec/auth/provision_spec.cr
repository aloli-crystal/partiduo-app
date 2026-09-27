# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

describe "Provisionnement : profils et administrateur (D-SET-005)" do
  it "crée les profils par défaut et l'administrateur invité, sans mot de passe" do
    provision_instance(admin_email: "Patron@Societe.example")
    system = Partiduo::Api::Actor.system
    Partiduo::Api::Auth.profiles(system).map(&.code).sort!.should eq(["ACCOUNTANT", "ADMIN"])

    admin = Partiduo::Api::Auth.user_by_email(system, "patron@societe.example") || raise "administrateur absent"
    admin.has_password.should be_false
    admin.profile_id.should eq(AuthSpec.profile_id("ADMIN"))

    invitation = Partiduo::Api::Auth.issue_invitation(system, admin.id)
    view = Partiduo::Api::Auth.accept_invitation(Partiduo::Api::Actor.anonymous, invitation.token).value!
    view.level.should eq(0)
    Partiduo::Api::Auth.security_overview(AuthSpec.actor(view.session_token!)).missing.should eq(["passkey"])
  end

  it "rend à l'opérateur l'invitation de l'administrateur, utilisable une fois (D-J1-001)" do
    view = provision_instance(admin_email: "Patron@Societe.example")
    view.invitations.size.should eq(1)
    invitation = view.invitations.first
    invitation.email.should eq("patron@societe.example")
    invitation.expires_at.should be > Time.utc + 6.days

    anonymous = Partiduo::Api::Actor.anonymous
    login = Partiduo::Api::Auth.accept_invitation(anonymous, invitation.token).value!
    login.level.should eq(0)
    Partiduo::Api::Auth.accept_invitation(anonymous, invitation.token).failure?.should be_true
  end

  it "crée les profils sans administrateur désigné" do
    view = provision_instance
    view.invitations.should be_empty
    Partiduo::Api::Auth.users(Partiduo::Api::Actor.system).should be_empty
    Partiduo::Api::Auth.profiles(Partiduo::Api::Actor.system).size.should eq(2)
  end
end
