# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  # Applications Marten du cœur, à placer en tête de `installed_apps` du projet
  # qui compile la distribution (interface, extensions).
  INSTALLED_APPS = [
    Partiduo::Modules::App,
    Partiduo::Auth::App,
    Partiduo::Core::App,
    Partiduo::Cards::App,
    Partiduo::Vat::App,
    Partiduo::Accounting::App,
    Partiduo::Invoicing::App,
    Partiduo::Analytic::App,
  ] of Marten::Apps::Config.class

  # Langues livrées (ADR-005 D7) ; les 21 autres langues de l'UE s'ajoutent par
  # un fichier de traduction.
  LOCALES = %w[fr en nl]

  # Réglages Marten communs à tout projet qui embarque le cœur. À appeler dans
  # un bloc `Marten.configure` ; le projet ajoute ensuite ses propres
  # applications :
  #
  # ```
  # Marten.configure do |config|
  #   Partiduo.apply_settings(config)
  #   config.installed_apps = Partiduo::INSTALLED_APPS + [Ui::App]
  # end
  # ```
  def self.apply_settings(config : Marten::Conf::GlobalSettings) : Nil
    config.installed_apps = INSTALLED_APPS
    config.database do |db|
      db.from_url(Partiduo::Config.database_url)
    end
    config.i18n.default_locale = :fr
    config.i18n.available_locales = LOCALES
    config.auth.user_model = Partiduo::Auth::User
  end
end
