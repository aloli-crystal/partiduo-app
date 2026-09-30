# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private def admin : Partiduo::Api::Actor
  actor_with("core.modules.manage")
end

describe Partiduo::Api::Modules do
  describe ".list" do
    it "décrit les pièces et leur état" do
      with_active_modules("invoicing") do
        views = Partiduo::Api::Modules.list(actor_with)
        views.find!(&.code.==("CORE")).active.should be_true
        views.find!(&.code.==("INVOICING")).active.should be_true
        analytic = views.find!(&.code.==("ANALYTIC"))
        analytic.active.should be_false
        analytic.kind.should eq("module")
        analytic.depends_on.should eq(["ACCOUNTING"])
        analytic.name_key.should eq("analytic.module.name")
        Partiduo::Api::Modules.get(actor_with, "invoicing").permissions.should contain("invoicing.invoice.issue")
      end
    end

    it "refuse un acteur anonyme et un code inconnu" do
      expect_raises(Partiduo::Api::Forbidden) { Partiduo::Api::Modules.list(Partiduo::Api::Actor.anonymous) }
      expect_raises(Partiduo::Api::NotFound) { Partiduo::Api::Modules.get(actor_with, "COMPTA") }
    end
  end

  describe ".activate et .deactivate" do
    it "exigent la permission core.modules.manage" do
      expect_raises(Partiduo::Api::Forbidden) { Partiduo::Api::Modules.activate(actor_with, "ACCOUNTING") }
      expect_raises(Partiduo::Api::Forbidden) { Partiduo::Api::Modules.deactivate(actor_with, "ACCOUNTING") }
    end

    it "enregistrent l'activation, qui prend le pas sur PARTIDUO_MODULES" do
      with_active_modules("invoicing") do
        result = Partiduo::Api::Modules.activate(admin, "accounting")
        result.success?.should be_true
        result.value!.active.should be_true

        Partiduo::Modules.active?("ACCOUNTING").should be_true
        Partiduo::Modules.active?("INVOICING").should be_true
        Partiduo::Modules.active?("ANALYTIC").should be_false
        Partiduo::Modules::Activation.get!(code: "ACCOUNTING").changed_by_id.should eq(1_i64)

        Partiduo::Api::Modules.deactivate(admin, "INVOICING").value!.active.should be_false
        Partiduo::Modules.active?("INVOICING").should be_false
        expect_raises(Partiduo::Api::ModuleDisabled) do
          Partiduo::Api::Guard.authorize!(admin, nil, module_code: "INVOICING")
        end
        Partiduo::Modules.check!
      end
    end

    it "refusent le socle" do
      result = Partiduo::Api::Modules.deactivate(admin, "CORE")
      result.error_keys.should eq(["modules.errors.activation.socle"])
      Partiduo::Api::Modules.activate(admin, "VAT").error_keys.should eq(["modules.errors.activation.socle"])
      Partiduo::Modules::Activation.all.exists?.should be_false
    end

    it "refusent d'activer une pièce dont une dépendance est inactive" do
      with_active_modules("invoicing") do
        result = Partiduo::Api::Modules.activate(admin, "ANALYTIC")
        result.failure?.should be_true
        error = result.errors_for("code").first
        error.key.should eq("modules.errors.activation.missing_dependency")
        error.params.should eq({"module" => "ANALYTIC", "dependency" => "ACCOUNTING"})
        I18n.with_locale("fr") { error.message.should eq("ANALYTIC requiert ACCOUNTING, qui n'est pas actif.") }
        Partiduo::Modules::Activation.all.exists?.should be_false
      end
    end

    it "refusent de désactiver une pièce requise par une pièce active" do
      with_active_modules("accounting,analytic") do
        result = Partiduo::Api::Modules.deactivate(admin, "ACCOUNTING")
        result.errors.map(&.params["dependent"]).should eq(["ANALYTIC"])
        Partiduo::Modules.active?("ACCOUNTING").should be_true

        Partiduo::Api::Modules.deactivate(admin, "ANALYTIC").success?.should be_true
        Partiduo::Api::Modules.deactivate(admin, "ACCOUNTING").success?.should be_true
        Partiduo::Modules.active_manifests.all?(&.socle?).should be_true
      end
    end

    it "lèvent NotFound pour un code inconnu" do
      expect_raises(Partiduo::Api::NotFound) { Partiduo::Api::Modules.activate(admin, "COMPTA") }
    end
  end

  describe ".permissions" do
    it "liste les permissions cochables des pièces actives" do
      with_active_modules("invoicing") do
        permissions = Partiduo::Api::Modules.permissions(admin)
        names = permissions.map(&.name)
        names.should contain("invoicing.invoice.issue")
        names.should contain("cards.card.read")
        names.should_not contain("accounting.entry.post")
        permissions.find!(&.name.==("invoicing.invoice.issue")).label_key.should eq("invoicing.permissions.invoice.issue")
      end
      expect_raises(Partiduo::Api::Forbidden) { Partiduo::Api::Modules.permissions(Partiduo::Api::Actor.anonymous) }
    end
  end

  describe ".menu" do
    it "ne montre que les pièces actives et les entrées permises" do
      with_active_modules("invoicing") do
        menu = Partiduo::Api::Modules.menu(actor_with("invoicing.invoice.read", "cards.card.read"))
        menu.map(&.code).should eq(%w[DASHBOARD BILLING REFERENCE])
        menu[0].route.should eq("core:dashboard")
        menu[1].children.map(&.code).should eq(%w[INV_DOCUMENTS INV_TO_INVOICE])
        menu[1].label_key.should eq("core.menu.billing")
        menu[2].children.map(&.code).should eq(%w[CARDS_LIST])
      end
    end

    it "suit la configuration Comptabilité seule" do
      with_active_modules("accounting,analytic") do
        codes = Partiduo::Api::Modules.menu(Partiduo::Api::Actor.system).map(&.code)
        codes.should eq(%w[DASHBOARD ENTRY CONSULT REFERENCE REPORTS VAT ANALYTIC SETTINGS])
      end
    end
  end
end
