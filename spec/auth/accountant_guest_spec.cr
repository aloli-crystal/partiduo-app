# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Accès invité en lecture du comptable (ADR-006 D4, D-GUEST-001) : profil
# par défaut `ACCOUNTANT_GUEST`, permissions de lecture seules.

private def guest_permissions : Set(String)
  user = AuthSpec.create_user(email: "cabinet@example.com", role: "accountant", profile: "ACCOUNTANT_GUEST",
    first_name: "Claire", last_name: "Expert").user
  Partiduo::Auth::Permissions.of_user(AuthSpec.user_model(user.id))
end

describe "Comptable invité en lecture (ADR-006 D4)" do
  it "crée le profil par défaut avec les seules permissions de lecture" do
    profile = Partiduo::Api::Auth.ensure_default_profiles(AuthSpec.system).find!(&.code.==("ACCOUNTANT_GUEST"))
    profile.admin.should be_false
    profile.name.should eq("Comptable invité (lecture)")
    profile.permissions.should_not be_empty
    profile.permissions.all?(&.ends_with?(".read")).should be_true
    profile.permissions.none? { |name| Partiduo::Auth::Permissions.administrative?(name) }.should be_true
  end

  it "n'accorde aucune saisie, quel que soit le module actif" do
    permissions = guest_permissions
    permissions.should_not be_empty
    permissions.each(&.should(end_with(".read")))
    permissions.includes?("cards.card.read").should be_true
    permissions.includes?("accounting.report.read").should eq(Partiduo::Modules.active?("ACCOUNTING"))
    permissions.includes?("invoicing.export.read").should eq(Partiduo::Modules.active?("INVOICING"))
  end
end

describe_module "INVOICING", "Comptable invité : transmission des factures" do
  it "lit les documents et les exports, sans pouvoir créer de document" do
    setup = InvoicingSpec.setup
    InvoicingSpec.issued(setup)
    user = AuthSpec.create_user(email: "cabinet@example.com", role: "accountant", profile: "ACCOUNTANT_GUEST",
      first_name: "Claire", last_name: "Expert").user
    permissions = Partiduo::Auth::Permissions.of_user(AuthSpec.user_model(user.id))
    actor = Partiduo::Api::Actor.user(user.id, permissions.to_a, level: 3)
    Partiduo::Api::Invoicing.documents(actor).size.should eq(1)
    day = Time.utc(2026, 9, 1)
    Partiduo::Api::Invoicing.sales_journal_csv(actor, day, day + 29.days).filename.should end_with(".csv")
    expect_raises(Partiduo::Api::Forbidden) do
      Partiduo::Api::Invoicing.create_document(actor, Partiduo::Api::Invoicing::DocumentInput.new(kind: "invoice", customer_card_id: setup.customer.id))
    end
  end
end
