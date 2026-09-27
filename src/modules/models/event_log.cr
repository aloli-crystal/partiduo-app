# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Modules
    # Journal des événements rejouables (`Partiduo::Events::JOURNALED`) : chaque
    # publication y laisse sa charge utile, que des abonnés soient actifs ou
    # non. Un module activé plus tard y retrouve ce qu'il a manqué (ADR-006 D2 :
    # la Comptabilité activée après des mois de facturation seule propose de
    # comptabiliser l'historique). Ajout seul ; lu par `Partiduo::Events.journal`.
    class EventLog < Marten::Model
      db_table "modules_event_log"

      field :id, :big_int, primary_key: true, auto: true
      field :name, :string, max_size: 64, index: true
      field :payload, :json
      # Utilisateur à l'origine de l'opération (`nil` : outil en ligne de commande).
      field :actor_user_id, :big_int, blank: true, null: true
      field :created_at, :date_time
    end
  end
end
