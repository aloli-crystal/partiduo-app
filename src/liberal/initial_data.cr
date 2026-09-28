# SPDX-License-Identifier: AGPL-3.0-or-later

# Jeu de données initial du module liberal (convention C6) : natures par
# défaut (une par rubrique de la 2035-A) dans la langue de l'instance et table
# de correspondance rubrique → ligne des formulaires, datée par millésime
# (`data/form_lines.yml`). Exécuté par `Partiduo::Api::Core.provision` si le
# module est actif.
Partiduo::Api::InitialData.register("LIBERAL", "defaults", order: 41) do |context|
  Partiduo::Api::Liberal.load_defaults(context.actor, context.locale)
end
