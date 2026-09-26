# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Modules
    # État d'activation d'un module ou d'une extension, enregistré par
    # l'administrateur de l'instance (ADR-006 D2). Interne : on le lit et on
    # l'écrit par `Partiduo::Modules` et `Partiduo::Api::Modules`.
    #
    # Dès qu'une ligne existe, la table décrit *entièrement* l'ensemble actif :
    # une pièce sans ligne est inactive. Table vide : `PARTIDUO_MODULES` (D-018).
    class Activation < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :code, :string, max_size: 64, unique: true
      field :active, :bool, default: false
      # Utilisateur qui a fait le dernier changement (`nil` : outil en ligne de commande).
      field :changed_by_id, :big_int, blank: true, null: true

      with_timestamp_fields
    end
  end
end
