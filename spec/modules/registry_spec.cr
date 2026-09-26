# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

describe Partiduo::Modules do
  it "enregistre le socle et les modules officiels" do
    %w[CORE CARDS VAT ACCOUNTING INVOICING ANALYTIC].each do |code|
      Partiduo::Modules.registered?(code).should be_true
    end
    Partiduo::Modules["ACCOUNTING"].kind.should eq(Partiduo::Modules::Kind::Module)
    Partiduo::Modules["ANALYTIC"].depends_on.should eq(["ACCOUNTING"])
  end

  it "active toujours le socle, et les modules selon PARTIDUO_MODULES" do
    with_active_modules("invoicing") do
      Partiduo::Modules.active?("CORE").should be_true
      Partiduo::Modules.active?("INVOICING").should be_true
      Partiduo::Modules.active?("ACCOUNTING").should be_false
      Partiduo::Modules.active?("INCONNU").should be_false
    end

    with_active_modules(nil) do
      Partiduo::Modules.active?("ACCOUNTING").should be_true
      Partiduo::Modules.active?("INVOICING").should be_true
    end

    with_active_modules("none") do
      Partiduo::Modules.active_manifests.all?(&.socle?).should be_true
    end
  end

  it "accepte les trois configurations de la CI (ADR-006 D7)" do
    ["accounting,analytic", "invoicing", "accounting,invoicing,analytic"].each do |codes|
      with_active_modules(codes) { Partiduo::Modules.check! }
    end
  end

  it "refuse au démarrage une dépendance manquante" do
    with_active_modules("analytic") do
      expect_raises(Partiduo::Modules::ConfigurationError, /ANALYTIC requiert ACCOUNTING/) do
        Partiduo::Modules.check!
      end
    end
  end

  it "refuse au démarrage un module inconnu" do
    with_active_modules("accounting,compta") do
      expect_raises(Partiduo::Modules::ConfigurationError, /inconnu : compta/) { Partiduo::Modules.check! }
    end
  end

  it "rejette un code de module mal formé" do
    expect_raises(ArgumentError) { Partiduo::Modules::Manifest.new.code("skel") }
  end

  describe Partiduo::Modules::Version do
    it "applique les contraintes à la manière de shards" do
      Partiduo::Modules::Version.satisfies?("0.1.3", "~> 0.1").should be_true
      Partiduo::Modules::Version.satisfies?("1.0.0", "~> 0.1").should be_false
      Partiduo::Modules::Version.satisfies?("0.1.3", "~> 0.1.2").should be_true
      Partiduo::Modules::Version.satisfies?("0.2.0", "~> 0.1.2").should be_false
      Partiduo::Modules::Version.satisfies?("0.1.0", ">= 0.1.0, < 1.0").should be_true
      Partiduo::Modules::Version.satisfies?("0.1.0", "0.1.0").should be_true
    end
  end
end

describe Partiduo::Events do
  it "ne connaît que les événements de la liste fermée" do
    expect_raises(ArgumentError, /événement inconnu/) { Partiduo::Events.publish("entry.deleted") }
  end

  it "n'appelle que les abonnés des pièces actives" do
    received = [] of String
    code = "SPEC#{Random::Secure.hex(3).upcase}"
    Partiduo::Modules.register do
      code code
      kind Partiduo::Modules::Kind::Extension
      on("entry.posted") { |event| received << event["entry_id"] }
    end

    with_active_modules("#{code.downcase}") do
      Partiduo::Events.publish("entry.posted", {"entry_id" => "7"})
    end
    with_active_modules("accounting") do
      Partiduo::Events.publish("entry.posted", {"entry_id" => "8"})
    end

    received.should eq(["7"])
  ensure
    Partiduo::Modules.manifests.delete(code) if code
  end
end
