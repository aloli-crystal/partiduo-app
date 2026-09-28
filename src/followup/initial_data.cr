# SPDX-License-Identifier: AGPL-3.0-or-later

# Jeu de données initial du Suivi (convention C6, D-SET-005) : types
# d'action d'origine (`document_type`) dans la langue de l'instance.
# Exécuté par `Partiduo::Api::Core.provision` si le module est actif.
Partiduo::Api::InitialData.register("FOLLOWUP", "action_types", order: 30) do |context|
  Partiduo::Api::Followup.load_default_action_types(context.actor, context.locale)
end
