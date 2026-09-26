# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Enregistre une pièce de spec le temps du bloc, puis la retire du registre.
def with_spec_manifest(& : Partiduo::Modules::Manifest ->) : Nil
  code = "SPEC#{Random::Secure.hex(3).upcase}"
  manifest = Partiduo::Modules.register { code code }
  begin
    yield manifest
  ensure
    Partiduo::Modules.manifests.delete(code)
  end
end

describe Partiduo::Modules do
  it "enregistre le socle et les modules officiels" do
    %w[CORE CARDS VAT ACCOUNTING INVOICING ANALYTIC].each do |code|
      Partiduo::Modules.registered?(code).should be_true
    end
    Partiduo::Modules["ACCOUNTING"].kind.should eq(Partiduo::Modules::Kind::Module)
    Partiduo::Modules["CORE"].socle?.should be_true
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

  it "lève ModuleDisabled pour une pièce inactive" do
    with_active_modules("invoicing") do
      Partiduo::Modules.require_active!("INVOICING")
      error = expect_raises(Partiduo::Api::ModuleDisabled) { Partiduo::Modules.require_active!("ACCOUNTING") }
      error.module_code.should eq("ACCOUNTING")
    end
  end

  describe ".check!" do
    it "accepte les trois configurations de la CI (ADR-006 D7)" do
      ["accounting,analytic", "invoicing", "accounting,invoicing,analytic", "none"].each do |codes|
        with_active_modules(codes) { Partiduo::Modules.check! }
      end
    end

    it "refuse une dépendance manquante" do
      with_active_modules("analytic") do
        expect_raises(Partiduo::Modules::ConfigurationError, /ANALYTIC requiert ACCOUNTING, inactif/) do
          Partiduo::Modules.check!
        end
      end
    end

    it "refuse un module inconnu" do
      with_active_modules("accounting,compta") do
        expect_raises(Partiduo::Modules::ConfigurationError, /inconnu : compta/) { Partiduo::Modules.check! }
      end
    end

    it "refuse d'activer une pièce du socle" do
      with_active_modules("core") do
        expect_raises(Partiduo::Modules::ConfigurationError, /CORE appartient au socle/) { Partiduo::Modules.check! }
      end
    end

    it "refuse une dépendance alternative dont aucune pièce n'est active" do
      with_spec_manifest do |manifest|
        manifest.depends_on_any "INVOICING", "ACCOUNTING"
        with_active_modules("#{manifest.code.downcase}") do
          expect_raises(Partiduo::Modules::ConfigurationError, /l'un de INVOICING, ACCOUNTING/) { Partiduo::Modules.check! }
        end
        with_active_modules("#{manifest.code.downcase},invoicing") { Partiduo::Modules.check! }
      end
    end

    it "refuse une version du cœur hors contrainte" do
      with_spec_manifest do |manifest|
        manifest.requires_core ">= 99.0"
        with_active_modules("#{manifest.code.downcase}") do
          expect_raises(Partiduo::Modules::ConfigurationError, /requiert le cœur >= 99.0/) { Partiduo::Modules.check! }
        end
      end
    end

    it "refuse une dépendance de version incompatible ou inconnue" do
      with_spec_manifest do |manifest|
        manifest.depends_on "ACCOUNTING", version: "~> 9.0"
        manifest.depends_on "DOCUMENT"
        with_active_modules("#{manifest.code.downcase},accounting") do
          error = expect_raises(Partiduo::Modules::ConfigurationError) { Partiduo::Modules.check! }
          error.message.to_s.should contain("requiert ACCOUNTING ~> 9.0, version #{Partiduo::VERSION}")
          error.message.to_s.should contain("requiert DOCUMENT, inconnu")
        end
      end
    end

    it "n'examine pas les dépendances d'une pièce inactive" do
      with_spec_manifest do |manifest|
        manifest.depends_on "DOCUMENT"
        with_active_modules("invoicing") { Partiduo::Modules.check! }
      end
    end

    it "refuse une version de pièce mal formée" do
      with_spec_manifest do |manifest|
        manifest.version "1.0"
        expect_raises(Partiduo::Modules::ConfigurationError, /version invalide « 1.0 »/) { Partiduo::Modules.check! }
      end
    end

    it "refuse une permission ou un menu déclarés deux fois" do
      with_spec_manifest do |manifest|
        manifest.permission "accounting.entry.post"
        manifest.menu "ACC_CHART", parent: "REFERENCE"
        error = expect_raises(Partiduo::Modules::ConfigurationError) { Partiduo::Modules.check! }
        error.message.to_s.should contain("permission accounting.entry.post déclarée par ACCOUNTING et #{manifest.code}")
        error.message.to_s.should contain("menu ACC_CHART déclaré par ACCOUNTING et #{manifest.code}")
      end
    end

    it "refuse un menu orphelin ou dont la permission n'est pas déclarée" do
      with_spec_manifest do |manifest|
        manifest.menu "SPEC_PAGE", parent: "NULLE_PART", permission: "spec.page.view"
        error = expect_raises(Partiduo::Modules::ConfigurationError) { Partiduo::Modules.check! }
        error.message.to_s.should contain("menu SPEC_PAGE rattaché à NULLE_PART, inconnu")
        error.message.to_s.should contain("menu SPEC_PAGE exige spec.page.view, non déclarée")
      end
    end
  end

  describe "permissions" do
    it "décrit chaque permission par son nom, sa pièce et sa clé de libellé" do
      entry = Partiduo::Modules.permission_entry("accounting.entry.post")
      entry.try(&.module_code).should eq("ACCOUNTING")
      entry.try(&.label).should eq("accounting.permissions.entry.post")
      Partiduo::Modules.permission_entry("accounting.entry.delete").should be_nil
      Partiduo::Modules.permission_catalog.map(&.name).should contain("invoicing.invoice.issue")
    end

    it "signale les permissions inconnues" do
      Partiduo::Modules.unknown_permissions(["accounting.entry.post", "compta.tout", "compta.tout"])
        .should eq(["compta.tout"])
    end

    it "ne garde comme effectives que les permissions des pièces actives" do
      with_active_modules("invoicing") do
        granted = ["accounting.entry.post", "invoicing.invoice.issue", "cards.card.read", "compta.tout"]
        Partiduo::Modules.effective_permissions(granted).should eq(Set{"invoicing.invoice.issue", "cards.card.read"})
        Partiduo::Modules.active_permissions.should_not contain("accounting.entry.post")
      end
    end

    it "traduit chaque permission et chaque entrée de menu en fr, en et nl" do
      missing = [] of String
      Partiduo::Modules.manifests.each_value do |manifest|
        keys = manifest.permission_entries.map(&.label) + manifest.menus.map(&.label)
        Partiduo::LOCALES.each do |locale|
          I18n.with_locale(locale) do
            keys.each { |key| missing << "#{locale}: #{key}" if I18n.t(key).includes?("missing") }
          end
        end
      end
      missing.should eq([] of String)
    end
  end

  describe Partiduo::Modules::Manifest do
    it "rejette un code de module ou de menu mal formé" do
      expect_raises(ArgumentError) { Partiduo::Modules::Manifest.new.code("skel") }
      manifest = Partiduo::Modules::Manifest.new
      manifest.code "SKEL"
      expect_raises(ArgumentError) { manifest.menu "skel" }
    end

    it "rejette une permission mal nommée" do
      manifest = Partiduo::Modules::Manifest.new
      manifest.code "SKEL"
      expect_raises(ArgumentError) { manifest.permission "Skel.View" }
      expect_raises(ArgumentError) { manifest.permission "skel" }
    end

    it "rejette une dépendance alternative à une seule pièce" do
      expect_raises(ArgumentError) { Partiduo::Modules::Manifest.new.depends_on_any("ACCOUNTING") }
    end

    it "rejette un abonnement à un événement inconnu" do
      expect_raises(ArgumentError, /événement inconnu/) { Partiduo::Modules::Manifest.new.on("entry.deleted") { } }
    end

    it "déduit les clés i18n par défaut" do
      manifest = Partiduo::Modules::Manifest.new
      manifest.code "SKEL"
      manifest.permission "skel.page.view"
      manifest.permission "skel.page.view"
      manifest.menu "SKEL_HOME", parent: "EXTENSION", route: "skel:index"
      manifest.name.should eq("skel.module.name")
      manifest.permission_entries.map(&.label).should eq(["skel.permissions.page.view"])
      manifest.menus.first.label.should eq("skel.menu.skel_home")
      manifest.menus.first.module_code.should eq("SKEL")
    end
  end

  describe Partiduo::Modules::Version do
    it "applique les contraintes à la manière de shards" do
      Partiduo::Modules::Version.satisfies?("0.1.3", "~> 0.1").should be_true
      Partiduo::Modules::Version.satisfies?("1.0.0", "~> 0.1").should be_false
      Partiduo::Modules::Version.satisfies?("0.1.3", "~> 0.1.2").should be_true
      Partiduo::Modules::Version.satisfies?("0.2.0", "~> 0.1.2").should be_false
      Partiduo::Modules::Version.satisfies?("0.1.0", ">= 0.1.0, < 1.0").should be_true
      Partiduo::Modules::Version.satisfies?("0.1.0", "0.1.0").should be_true
      Partiduo::Modules::Version.valid?("0.1.0").should be_true
      Partiduo::Modules::Version.valid?("0.1").should be_false
    end
  end
end
