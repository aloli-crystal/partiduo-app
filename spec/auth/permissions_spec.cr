# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Compléments de couverture des permissions (ADR-003 D4, C2, D-REF-013) :
# chaque requête du contrat exige sa permission et elle seule ; le profil
# ACCOUNTANT par défaut ouvre le référentiel sans rien d'administratif.

private alias Api = Partiduo::Api

# Requêtes gardées : {permission, module, appel}.
private QUERIES = [
  {"vat.rate.read", "VAT", ->(actor : Api::Actor) { Api::Vat.rates(actor); nil }},
  {"cards.card.read", "CARDS", ->(actor : Api::Actor) { Api::Cards.categories(actor); nil }},
  {"cards.card.read", "CARDS", ->(actor : Api::Actor) { Api::Cards.cards(actor); nil }},
  {"auth.users.manage", "AUTH", ->(actor : Api::Actor) { Api::Auth.users(actor); nil }},
  {"auth.profiles.manage", "AUTH", ->(actor : Api::Actor) { Api::Auth.profiles(actor); nil }},
  {"auth.providers.manage", "AUTH", ->(actor : Api::Actor) { Api::Auth.identity_providers(actor); nil }},
  {"auth.audit.view", "AUTH", ->(actor : Api::Actor) { Api::Auth.audit_events(actor); nil }},
  {"accounting.account.read", "ACCOUNTING", ->(actor : Api::Actor) { Api::Accounting.chart(actor); nil }},
  {"accounting.ledger.read", "ACCOUNTING", ->(actor : Api::Actor) { Api::Accounting.ledgers(actor); nil }},
]

describe "Permissions des requêtes du contrat (C2)" do
  QUERIES.each do |permission, module_code, query|
    it "#{permission} ouvre sa requête (#{module_code}), et elle seule" do
      unless Partiduo::Modules.active?(module_code)
        expect_raises(Api::ModuleDisabled) { query.call(actor_with(permission)) }
        next
      end
      expect_raises(Api::Forbidden) { query.call(Api::Actor.anonymous) }
      expect_raises(Api::Forbidden) { query.call(actor_with) }
      others = Partiduo::Modules.active_permissions.reject(&.==(permission))
      expect_raises(Api::Forbidden) { query.call(Api::Actor.user(1_i64, others)) }
      query.call(actor_with(permission))
      query.call(Api::Actor.system)
    end
  end

  it "ouvre les lectures sans permission à tout utilisateur authentifié, pas à l'anonyme" do
    Api::Core.currencies(actor_with).should be_a(Array(Api::Core::CurrencyView))
    Api::Core.fiscal_years(actor_with).should be_a(Array(Api::Core::FiscalYearView))
    Api::Modules.list(actor_with).should_not be_empty
    expect_raises(Api::Forbidden) { Api::Core.currencies(Api::Actor.anonymous) }
    expect_raises(Api::Forbidden) { Api::Core.fiscal_years(Api::Actor.anonymous) }
  end

  it "refuse tout à un acteur authentifié sans session (identifiant nul)" do
    anonymous_user = Api::Actor.new(user_id: nil, permissions: Set{"vat.rate.read"})
    expect_raises(Api::Forbidden) { Api::Vat.rates(anonymous_user) }
  end
end

describe "Profil ACCOUNTANT par défaut (D-REF-013)" do
  it "ouvre le référentiel du socle sans aucune permission administrative" do
    profile = Api::Auth.ensure_default_profiles(Api::Actor.system).find!(&.code.==("ACCOUNTANT"))
    %w[cards.card.read cards.card.write vat.rate.read core.fiscal_year.write core.period.close
      core.currency.write core.attachment.read core.attachment.write].each do |name|
      profile.permissions.should contain(name)
    end
    profile.permissions.none? { |name| Partiduo::Auth::Permissions.administrative?(name) }.should be_true
    profile.admin.should be_false
  end

  it "donne au comptable de niveau 3 le référentiel mais pas les réglages de la société" do
    AuthSpec.create_user("expert@cabinet.example", role: "accountant", profile: "ACCOUNTANT",
      first_name: "Claire", last_name: "Expert")
    token = AuthSpec.session_token("expert@cabinet.example")
    authenticator, _enrollment = AuthSpec.enroll_passkey(AuthSpec.actor(token))
    actor = AuthSpec.actor(AuthSpec.passkey_login(authenticator).value!.session_token!)

    Api::Vat.rates(actor).should be_a(Array(Api::Vat::RateView))
    actor.can?("core.fiscal_year.write").should be_true
    expect_raises(Api::Forbidden) { Api::Core.update_settings(actor, settings_input) }
    expect_raises(Api::Forbidden) { Api::Modules.activate(actor, "ACCOUNTING") }
    expect_raises(Api::Forbidden) { Api::Auth.users(actor) }

    settings_menu = Api::Modules.menu(actor).find(&.code.==("SETTINGS")).try(&.children.map(&.code)) || [] of String
    settings_menu.should_not contain("CORE_COMPANY")
    settings_menu.should_not contain("CORE_USERS")
    settings_menu.should_not contain("CORE_MODULES")
    settings_menu.should contain("CORE_FISCAL_YEARS")
  end
end
