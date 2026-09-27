# SPDX-License-Identifier: AGPL-3.0-or-later

# Outils des specs du référentiel comptable (lot 1) : tout passe par le contrat.
module AccountingSpec
  alias Api = Partiduo::Api::Accounting

  def self.system : Partiduo::Api::Actor
    Partiduo::Api::Actor.system
  end

  # Devise de tenue du socle, exigée par les journaux.
  def self.base_currency : Nil
    Partiduo::Api::Core.ensure_base_currency(system, "EUR", "Euro")
    nil
  end

  # Catégories de fiches par défaut du socle, puis plan comptable, comptes par
  # défaut, comptes de base des catégories et journaux d'un régime.
  def self.load(regime : String = "fr", locale : String = "fr") : Api::InitialDataView
    base_currency
    Partiduo::Api::Cards.load_default_categories(system)
    Api.load_initial_data(system, regime, locale).value!
  end

  def self.create_account(number : String, label : String = "Compte #{number}", parent : String? = nil,
                          kind : Api::AccountKind? = nil, direct_use : Bool = true) : Api::AccountView
    Api.create_account(system, Api::AccountInput.new(number, label, parent, kind, direct_use)).value!
  end

  def self.ledger_input(name : String = "Achats", kind : Api::LedgerKind = Api::LedgerKind::Purchase, **overrides) : Api::LedgerInput
    Api::LedgerInput.new(**{name: name, kind: kind}.merge(overrides))
  end

  def self.create_ledger(name : String = "Achats", kind : Api::LedgerKind = Api::LedgerKind::Purchase, **overrides) : Api::LedgerView
    base_currency
    Api.create_ledger(system, ledger_input(name, kind, **overrides)).value!
  end

  # Utilisateur réel (les droits par journal sont tenus par le socle) et son acteur.
  def self.user_actor(email : String, *permissions : String, profile : String? = nil) : {Int64, Partiduo::Api::Actor}
    user = AuthSpec.create_user(email: email, profile: profile).user
    {user.id, Partiduo::Api::Actor.user(user.id, permissions.to_a, level: 3)}
  end
end
