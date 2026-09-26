# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

describe Partiduo::Api::Core do
  describe ".instance" do
    it "décrit l'instance et ses modules" do
      with_active_modules("invoicing") do
        view = Partiduo::Api::Core.instance(actor_with)

        view.version.should eq(Partiduo::VERSION)
        view.domain.should eq(Partiduo::Config.domain)
        accounting = view.modules.find!(&.code.==("ACCOUNTING"))
        accounting.active.should be_false
        accounting.kind.should eq("module")
        view.modules.find!(&.code.==("INVOICING")).active.should be_true
        view.modules.find!(&.code.==("CORE")).active.should be_true
      end
    end

    it "refuse un acteur anonyme" do
      expect_raises(Partiduo::Api::Forbidden) { Partiduo::Api::Core.instance(Partiduo::Api::Actor.anonymous) }
    end
  end
end

describe Partiduo::Config do
  it "se connecte à PostgreSQL par socket Unix, sur une base de test" do
    Partiduo::Config.database_url.should contain("test")
    Marten::DB::Connection.default.open do |db|
      db.scalar("SELECT current_database()").as(String).should contain("test")
    end
  end
end

describe Partiduo::Auth::User do
  it "enregistre un utilisateur dans la table créée par les migrations" do
    user = Partiduo::Auth::User.new(email: "comptable@example.org")
    user.set_password("une phrase de passe assez longue")
    user.save!

    Partiduo::Auth::User.get!(email: "comptable@example.org").check_password("une phrase de passe assez longue").should be_true
  end
end
