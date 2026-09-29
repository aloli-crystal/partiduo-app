# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Actions réservées à un profil (`action_gestion.ag_dest` d'origine ;
# DECISIONS D-FUP-001 révisée, D-R5-016).

private alias Api = Partiduo::Api::Followup
private alias Auth = Partiduo::Api::Auth

private PERMISSIONS = %w[followup.action.read followup.action.write]

# Utilisateur d'un nouveau profil aux droits du suivi (sans paramétrage).
private def member(email : String, profile : String) : {Partiduo::Api::Actor, Int64}
  view = Auth.create_profile(Partiduo::Api::Actor.system, Auth::ProfileInput.new(name: profile, permissions: PERMISSIONS)).value!
  created = Auth.create_user(Partiduo::Api::Actor.system, Auth::UserInput.new(email: email, first_name: "X",
    last_name: profile, profile_id: view.id, password: AuthSpec::PASSWORD)).value!
  {Partiduo::Api::Actor.user(created.user.id, PERMISSIONS), view.id}
end

describe_module "FOLLOWUP", "Suivi : actions réservées à un profil" do
  it "ne montre une action réservée qu'au profil, à son auteur et à qui paramètre le suivi" do
    Api.load_default_action_types(Partiduo::Api::Actor.system, "fr")
    type = Api.action_types(Partiduo::Api::Actor.system).find!(&.code.==("PRP"))
    sales, sales_profile = member("vente@example.com", "Ventes")
    accounts, _ = member("compta@example.com", "Comptabilité")
    author, _ = member("auteur@example.com", "Direction")
    input = Api::ActionInput.new(action_type_id: type.id, date: Time.utc(2026, 9, 20), title: "Négociation salariale",
      visible_profile_id: sales_profile, remind_on: Time.utc(2026, 9, 1))
    reserved = Api.create_action(author, input).value!
    reserved.visible_profile_id.should eq(sales_profile)
    open = Api.create_action(author, input.copy_with(title: "Note commune", visible_profile_id: nil)).value!

    Api.actions(sales).map(&.title).sort!.should eq(["Note commune", "Négociation salariale"])
    Api.actions(author).size.should eq(2)
    Api.actions(accounts).map(&.title).should eq(["Note commune"])
    Api.count_actions(accounts).should eq(1)
    Api.actions(Partiduo::Api::Actor.system).size.should eq(2)
    expect_raises(Partiduo::Api::NotFound) { Api.action(accounts, reserved.id) }
    expect_raises(Partiduo::Api::NotFound) { Api.add_comment(accounts, reserved.id, "vu") }
    expect_raises(Partiduo::Api::NotFound) { Api.set_state(accounts, reserved.id, "closed") }
    expect_raises(Partiduo::Api::NotFound) { Api.relate(accounts, open.id, reserved.id) }
    Api.action_by_reference(accounts, reserved.reference).should be_nil
    Api.reminders(accounts, Time.utc(2026, 9, 29)).late.map(&.title).should eq(["Note commune"])
    String.new(Api.export_actions(accounts).content).should_not contain("Négociation salariale")
    Api.add_comment(sales, reserved.id, "Proposition envoyée").success?.should be_true
  end

  it "refuse un profil inconnu et rend l'action visible de tous quand son profil disparaît" do
    Api.load_default_action_types(Partiduo::Api::Actor.system, "fr")
    type = Api.action_types(Partiduo::Api::Actor.system).find!(&.code.==("PRP"))
    input = Api::ActionInput.new(action_type_id: type.id, date: Time.utc(2026, 9, 20), visible_profile_id: 999_999_i64)
    result = Api.create_action(Partiduo::Api::Actor.system, input)
    result.error_keys.should eq(["followup.errors.action.profile_unknown"])
    ReferentialSpec.expect_translated(result)
    profile = Auth.create_profile(Partiduo::Api::Actor.system, Auth::ProfileInput.new(name: "Temporaire")).value!
    action = Api.create_action(Partiduo::Api::Actor.system, input.copy_with(visible_profile_id: profile.id)).value!
    Auth.delete_profile(Partiduo::Api::Actor.system, profile.id).value!
    Api.action(Partiduo::Api::Actor.system, action.id).visible_profile_id.should be_nil
    Api.visibility_profiles(actor_with(Api::READ)).map(&.name).should_not contain("Temporaire")
  end
end
