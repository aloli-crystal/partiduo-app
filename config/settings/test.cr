# SPDX-License-Identifier: AGPL-3.0-or-later

Marten.configure :test do |config|
  # La base de test est vidée et reconstruite à chaque exécution des specs.
  # Nom par défaut : partiduo_test ; chaque agent ou job de CI passe la sienne
  # par DATABASE_URL. Le spec_helper refuse une base dont le nom ne contient
  # pas « test ».
  config.database do |db|
    db.from_url(Partiduo::Config.database_url)
  end
  config.cache_store = Marten::Cache::Store::Null.new
  config.emailing.backend = Marten::Emailing::Backend::Development.new(collect_emails: true, print_emails: false)
end
