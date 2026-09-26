# SPDX-License-Identifier: AGPL-3.0-or-later

# Réglages du projet autonome partiduo-app : ligne de commande (migrations,
# provisionnement) et specs. Aucun serveur HTTP ici (ADR-005 D1).
Marten.configure do |config|
  config.secret_key = ENV["MARTEN_SECRET_KEY"]? || "__insecure_partiduo_app_dev_only__"
  Partiduo.apply_settings(config)
  config.middleware = [] of Marten::Middleware.class
end
