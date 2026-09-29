# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Compléments de couverture du registre (ADR-003 D2, ADR-006 D2, D7 ; D-018,
# D-020) : activation enregistrée, dépendances alternatives et de version par
# le contrat, permissions conservées d'un module désactivé, cohérence des
# trois configurations de la CI.

private def modules_admin : Partiduo::Api::Actor
  Partiduo::Api::Actor.user(42_i64, ["core.modules.manage"])
end

# Pièce d'essai enregistrée le temps du bloc (extension par défaut).
private def with_test_piece(& : Partiduo::Modules::Manifest ->) : Nil
  code = "ACT#{Random::Secure.hex(3).upcase}"
  manifest = Partiduo::Modules.register { code code }
  begin
    yield manifest
  ensure
    Partiduo::Modules.manifests.delete(code)
  end
end

describe "Registre : activation enregistrée (D-018)" do
  it "rend inactive une extension sans ligne dès que la table décrit l'instance" do
    with_test_piece do |piece|
      with_active_modules("invoicing,#{piece.code.downcase}") do
        Partiduo::Modules.active?(piece.code).should be_true # table vide : PARTIDUO_MODULES
        Partiduo::Api::Modules.activate(modules_admin, "accounting").success?.should be_true
        # La table a été écrite pour les pièces connues à cet instant : la
        # pièce d'essai y figure, active comme dans PARTIDUO_MODULES.
        Partiduo::Modules.active?(piece.code).should be_true
        Partiduo::Modules::Activation.get!(code: piece.code).active.should be_true
      end

      with_test_piece do |late|
        # Pièce compilée après l'écriture de la table : inactive tant que
        # l'administrateur ne l'active pas, même citée dans PARTIDUO_MODULES.
        with_active_modules("#{late.code.downcase}") do
          Partiduo::Modules.active?(late.code).should be_false
          Partiduo::Api::Modules.activate(modules_admin, late.code).value!.active.should be_true
          Partiduo::Modules.active?(late.code).should be_true
        end
      end
    end
  end

  it "accepte d'activer une pièce active et de désactiver une pièce inactive, sans rien écrire" do
    with_active_modules("invoicing") do
      Partiduo::Api::Modules.activate(modules_admin, "invoicing").value!.active.should be_true
      Partiduo::Api::Modules.deactivate(modules_admin, "accounting").value!.active.should be_false
      Partiduo::Modules::Activation.all.exists?.should be_false
    end
  end

  it "note l'auteur de chaque changement" do
    with_active_modules("invoicing") do
      Partiduo::Api::Modules.activate(modules_admin, "ACCOUNTING")
      Partiduo::Api::Modules.deactivate(Partiduo::Api::Actor.system, "INVOICING")
      Partiduo::Modules::Activation.get!(code: "ACCOUNTING").changed_by_id.should eq(42_i64)
      Partiduo::Modules::Activation.get!(code: "INVOICING").changed_by_id.should be_nil
      Partiduo::Modules::Activation.get!(code: "INVOICING").active.should be_false
    end
  end

  it "accepte un code en minuscules" do
    with_active_modules("invoicing") do
      Partiduo::Api::Modules.activate(modules_admin, "accounting").value!.code.should eq("ACCOUNTING")
      Partiduo::Api::Modules.get(Partiduo::Api::Actor.system, "accounting").active.should be_true
    end
  end
end

describe "Registre : dépendances par le contrat (ADR-003 D2)" do
  it "exige l'une des pièces d'une dépendance alternative" do
    with_test_piece do |piece|
      piece.depends_on_any "INVOICING", "ACCOUNTING"
      with_active_modules("none") do
        result = Partiduo::Api::Modules.activate(modules_admin, piece.code)
        result.errors_for("code").map(&.key).should eq(["modules.errors.activation.missing_dependency"])
        result.errors.first.params["dependency"].should eq("INVOICING | ACCOUNTING")
      end
      with_active_modules("accounting") do
        Partiduo::Api::Modules.activate(modules_admin, piece.code).success?.should be_true
      end
    end
  end

  it "refuse de retirer la seule alternative active d'une pièce, pas l'une de deux" do
    with_test_piece do |piece|
      piece.depends_on_any "INVOICING", "ACCOUNTING"
      with_active_modules("invoicing,accounting,#{piece.code.downcase}") do
        Partiduo::Api::Modules.deactivate(modules_admin, "ACCOUNTING").success?.should be_true
        result = Partiduo::Api::Modules.deactivate(modules_admin, "INVOICING")
        result.error_keys.should eq(["modules.errors.activation.required_by"])
        result.errors.first.params.should eq({"module" => "INVOICING", "dependent" => piece.code})
        Partiduo::Modules.active?("INVOICING").should be_true
      end
    end
  end

  it "refuse une dépendance de version incompatible" do
    with_test_piece do |piece|
      piece.depends_on "ACCOUNTING", version: "~> 9.0"
      with_active_modules("accounting") do
        result = Partiduo::Api::Modules.activate(modules_admin, piece.code)
        result.error_keys.should eq(["modules.errors.activation.incompatible"])
        result.errors.first.params["detail"].should contain("ACCOUNTING ~> 9.0")
        Partiduo::Modules.active?(piece.code).should be_false
      end
    end
  end

  it "signale à la fois les dépendances manquantes, sans examiner les versions" do
    with_test_piece do |piece|
      piece.depends_on "ACCOUNTING", version: "~> 9.0"
      piece.depends_on "INVOICING"
      with_active_modules("none") do
        result = Partiduo::Api::Modules.activate(modules_admin, piece.code)
        result.error_keys.should eq(["modules.errors.activation.missing_dependency"] * 2)
        result.errors.map(&.params["dependency"]).should eq(["ACCOUNTING", "INVOICING"])
      end
    end
  end

  it "désactive une pièce : ses commandes et requêtes lèvent ModuleDisabled, ses données restent" do
    with_active_modules("accounting,invoicing") do
      AccountingSpec.load("fr")
      Partiduo::Api::Modules.deactivate(modules_admin, "ACCOUNTING").success?.should be_true
      expect_raises(Partiduo::Api::ModuleDisabled) { Partiduo::Api::Accounting.chart(Partiduo::Api::Actor.system) }

      Partiduo::Api::Modules.activate(modules_admin, "ACCOUNTING").success?.should be_true
      Partiduo::Api::Accounting.chart(Partiduo::Api::Actor.system).size.should eq(169) # rien n'a été supprimé
    end
  end
end

describe "Permissions d'un module désactivé (D-020)" do
  it "restent cochées dans le profil, sont ignorées, puis reviennent à la réactivation" do
    with_active_modules("accounting,invoicing") do
      profile = Partiduo::Api::Auth.create_profile(AuthSpec.system, Partiduo::Api::Auth::ProfileInput.new(
        name: "Saisie", permissions: ["accounting.entry.post", "invoicing.invoice.read"])).value!
      Partiduo::Api::Auth.create_user(AuthSpec.system, Partiduo::Api::Auth::UserInput.new(
        email: "bob@example.com", first_name: "Bob", last_name: "Durand", profile_id: profile.id,
        password: AuthSpec::PASSWORD)).value!
      token = AuthSpec.session_token("bob@example.com")
      AuthSpec.actor(token).permissions.should eq(Set{"accounting.entry.post", "invoicing.invoice.read"})

      Partiduo::Api::Modules.deactivate(modules_admin, "ACCOUNTING").success?.should be_true
      AuthSpec.actor(token).permissions.should eq(Set{"invoicing.invoice.read"}) # sans nouvelle connexion
      Partiduo::Api::Auth.profile(AuthSpec.system, profile.id).permissions.should contain("accounting.entry.post")
      Partiduo::Api::Modules.permissions(modules_admin).map(&.name).should_not contain("accounting.entry.post")

      Partiduo::Api::Modules.activate(modules_admin, "ACCOUNTING").success?.should be_true
      AuthSpec.actor(token).permissions.should eq(Set{"accounting.entry.post", "invoicing.invoice.read"})
    end
  end

  it "d'un module inactif peuvent être cochées dans un profil (catalogue complet)" do
    with_active_modules("invoicing") do
      result = Partiduo::Api::Auth.create_profile(AuthSpec.system, Partiduo::Api::Auth::ProfileInput.new(
        name: "Préparé", permissions: ["accounting.entry.post"]))
      result.success?.should be_true
      Partiduo::Modules.effective_permissions(["accounting.entry.post", "invoicing.invoice.read"])
        .should eq(Set{"invoicing.invoice.read"})
    end
  end

  it "ne donnent aucune entrée de menu tant que le module est inactif" do
    with_active_modules("invoicing") do
      actor = actor_with("accounting.account.read", "cards.card.read")
      Partiduo::Api::Modules.menu(actor).flat_map(&.children).map(&.code).should_not contain("ACC_CHART")
    end
  end
end

describe "Les trois configurations de la CI (ADR-006 D7)" do
  {
    "accounting,analytic"           => { %w[ACCOUNTING ANALYTIC], %w[INVOICING] },
    "invoicing"                     => { %w[INVOICING], %w[ACCOUNTING ANALYTIC] },
    "accounting,invoicing,analytic" => { %w[ACCOUNTING INVOICING ANALYTIC], [] of String },
  }.each do |configuration, (active, inactive)|
    it "est cohérente pour #{configuration}" do
      with_active_modules(configuration) do
        Partiduo::Modules.check!
        listed = Partiduo::Api::Modules.list(Partiduo::Api::Actor.system)
        active.each { |code| listed.find!(&.code.==(code)).active.should be_true }
        inactive.each { |code| listed.find!(&.code.==(code)).active.should be_false }
        %w[CORE CARDS VAT AUTH].each { |code| Partiduo::Modules.active?(code).should be_true }

        permissions = Partiduo::Modules.active_permissions
        active.each { |code| permissions.should contain(Partiduo::Modules[code].permission_entries.first.name) }
        inactive.each do |code|
          Partiduo::Modules[code].permission_entries.each { |entry| permissions.should_not contain(entry.name) }
          expect_raises(Partiduo::Api::ModuleDisabled) do
            Partiduo::Api::Guard.authorize!(Partiduo::Api::Actor.system, nil, module_code: code)
          end
        end

        AuthSpec.create_user
        AuthSpec.actor(AuthSpec.session_token).permissions.should eq(permissions.to_set)
        menu_modules = Partiduo::Api::Modules.menu(Partiduo::Api::Actor.system)
          .flat_map(&.children).map(&.module_code).uniq!
        inactive.each { |code| menu_modules.should_not contain(code) }
        active.each { |code| menu_modules.should contain(code) }
      end
    end
  end
end
