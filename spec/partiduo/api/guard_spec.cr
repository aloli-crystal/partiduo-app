# SPDX-License-Identifier: AGPL-3.0-or-later

require "../../spec_helper"

describe Partiduo::Api::Guard do
  it "laisse passer un acteur qui a la permission" do
    Partiduo::Api::Guard.authorize!(actor_with("core.settings.manage"), "core.settings.manage")
  end

  it "refuse un acteur sans la permission" do
    error = expect_raises(Partiduo::Api::Forbidden) do
      Partiduo::Api::Guard.authorize!(actor_with, "core.settings.manage")
    end
    error.permission.should eq("core.settings.manage")
    error.key.should eq("partiduo.api.errors.forbidden")
  end

  it "refuse un acteur anonyme, même sans permission requise" do
    expect_raises(Partiduo::Api::Forbidden) do
      Partiduo::Api::Guard.authorize!(Partiduo::Api::Actor.anonymous, nil)
    end
  end

  it "accorde tout à l'acteur système" do
    Partiduo::Api::Guard.authorize!(Partiduo::Api::Actor.system, "core.users.manage")
  end

  it "refuse une permission qu'aucun manifeste ne déclare" do
    expect_raises(ArgumentError, /non déclarée/) do
      Partiduo::Api::Guard.authorize!(Partiduo::Api::Actor.system, "core.faute.de.frappe")
    end
  end

  it "refuse l'appel d'un module inactif" do
    with_active_modules("invoicing") do
      error = expect_raises(Partiduo::Api::ModuleDisabled) do
        Partiduo::Api::Guard.authorize!(Partiduo::Api::Actor.system, nil, module_code: "ACCOUNTING")
      end
      error.module_code.should eq("ACCOUNTING")
    end
  end
end
