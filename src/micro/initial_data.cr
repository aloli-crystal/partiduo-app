# SPDX-License-Identifier: AGPL-3.0-or-later

# Jeu de données initial du module micro (convention C6) : natures par
# défaut dans la langue de l'instance, taux URSSAF, seuils et cases de la
# 2042-C-PRO datés (`data/parameters.yml`). Exécuté par
# `Partiduo::Api::Core.provision` si le module est actif.
Partiduo::Api::InitialData.register("MICRO", "parameters", order: 40) do |context|
  Partiduo::Api::Micro.load_defaults(context.actor, context.locale)
end
