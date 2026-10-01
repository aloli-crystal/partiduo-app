# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

describe "Préférences de l'utilisateur (D-AUTH-016)" do
  it "rend le défaut du rôle tant que rien n'est choisi : simplifiée pour la société, complète pour le comptable" do
    AuthSpec.create_user
    AuthSpec.create_user("expert@cabinet.example", role: "accountant", first_name: "Claire", last_name: "Expert")
    member = Partiduo::Api::Auth.preferences(AuthSpec.actor(AuthSpec.session_token))
    member.interface.should eq(Partiduo::Api::Auth::INTERFACE_SIMPLE)
    member.interface_chosen.should be_false
    member.full_interface?.should be_false
    # Session du comptable sous le niveau exigé : ses préférences restent ouvertes.
    accountant = Partiduo::Api::Auth.preferences(AuthSpec.actor(AuthSpec.session_token("expert@cabinet.example")))
    accountant.interface.should eq(Partiduo::Api::Auth::INTERFACE_FULL)
    accountant.interface_chosen.should be_false
  end

  it "enregistre la préférence avec le compte : elle suit la personne d'une session à l'autre" do
    created = AuthSpec.create_user
    first = AuthSpec.actor(AuthSpec.session_token)
    saved = Partiduo::Api::Auth.update_preferences(first, Partiduo::Api::Auth::PreferencesInput.new(interface: "full")).value!
    saved.interface.should eq("full")
    saved.interface_chosen.should be_true
    AuthSpec.user_model(created.user.id).interface.should eq("full")

    other_device = AuthSpec.actor(AuthSpec.session_token)
    Partiduo::Api::Auth.preferences(other_device).full_interface?.should be_true
    # Sans interface dans la saisie : la préférence enregistrée est gardée.
    Partiduo::Api::Auth.update_preferences(other_device, Partiduo::Api::Auth::PreferencesInput.new).value!
      .interface.should eq("full")
    Partiduo::Api::Auth.update_preferences(other_device, Partiduo::Api::Auth::PreferencesInput.new(interface: "simple")).value!
      .interface.should eq("simple")
    Partiduo::Api::Auth.preferences(first).interface_chosen.should be_true
  end

  it "ne change que la préférence de l'acteur : celle des autres reste la leur" do
    AuthSpec.create_user
    bob = AuthSpec.create_user("bob@example.com", first_name: "Bob")
    alice = AuthSpec.actor(AuthSpec.session_token)
    Partiduo::Api::Auth.update_preferences(alice, Partiduo::Api::Auth::PreferencesInput.new(interface: "full")).success?.should be_true
    AuthSpec.user_model(bob.user.id).interface.should be_nil
    Partiduo::Api::Auth.preferences(AuthSpec.actor(AuthSpec.session_token("bob@example.com"))).interface.should eq("simple")
  end

  it "refuse une interface inconnue sans rien réécrire, et l'acteur non authentifié ou technique" do
    created = AuthSpec.create_user
    actor = AuthSpec.actor(AuthSpec.session_token)
    Partiduo::Api::Auth.update_preferences(actor, Partiduo::Api::Auth::PreferencesInput.new(interface: "expert"))
      .error_keys.should eq(["auth.errors.preferences.interface_invalid"])
    AuthSpec.user_model(created.user.id).interface.should be_nil
    expect_raises(Partiduo::Api::Forbidden) { Partiduo::Api::Auth.preferences(Partiduo::Api::Actor.anonymous) }
    expect_raises(Partiduo::Api::Forbidden) { Partiduo::Api::Auth.preferences(AuthSpec.system) }
    expect_raises(Partiduo::Api::Forbidden) do
      Partiduo::Api::Auth.update_preferences(Partiduo::Api::Actor.anonymous, Partiduo::Api::Auth::PreferencesInput.new(interface: "full"))
    end
  end
end
