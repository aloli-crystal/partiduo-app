# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Followup
    # Type d'action (`document_type`) : préfixe des références (`dt_prefix`,
    # unique, en majuscules), libellé, prochain numéro de la série
    # (`seq_doc_type_<id>`, tenu ici sous verrou, D-FUP-003). Modèle interne :
    # l'interface passe par `Partiduo::Api::Followup`.
    class ActionType < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :code, :string, max_size: 10, unique: true
      field :label, :string, max_size: 80
      field :next_number, :int, default: 1

      with_timestamp_fields
    end

    # Étiquette (`tags`) : libellé unique, description, active ou non,
    # couleur (1 à 10).
    class Tag < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :label, :string, max_size: 60, unique: true
      field :description, :text, blank: true, default: ""
      field :active, :bool, default: true
      field :color, :int, default: 1

      with_timestamp_fields
    end

    # Action de suivi (`action_gestion`) : type, référence attribuée à la
    # création (`ag_ref`), titre, date et heure, priorité (1 haute, 2 normale,
    # 3 basse), état (`todo`, `follow`, `closed`, `abandoned` —
    # `document_state`), date de rappel, fiche destinataire (`f_id_dest`,
    # vide = action interne), contact (`ag_contact`), auteur (`ag_owner`).
    # Les fiches sont citées par identifiant (clés étrangères posées par la
    # migration).
    class Action < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :action_type, :many_to_one, to: Partiduo::Followup::ActionType, related: :actions, on_delete: :protect
      field :reference, :string, max_size: 40, unique: true
      field :title, :string, max_size: 255
      field :date, :date
      field :hour, :string, max_size: 5, blank: true, default: ""
      field :priority, :int, default: 2
      field :state, :string, max_size: 10, default: "todo"
      field :remind_on, :date, null: true, blank: true
      field :card_id, :big_int, null: true, blank: true
      field :contact_card_id, :big_int, null: true, blank: true
      field :owner_id, :big_int, null: true, blank: true

      with_timestamp_fields
    end

    # Commentaire d'une action (`action_gestion_comment`), horodaté, avec
    # son auteur.
    class Comment < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :action, :many_to_one, to: Partiduo::Followup::Action, related: :comments, on_delete: :cascade
      field :text, :text
      field :author_id, :big_int, null: true, blank: true

      with_timestamp_fields
    end

    # Autre fiche concernée par une action (`action_person`).
    class ActionCard < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :action, :many_to_one, to: Partiduo::Followup::Action, related: :concerned, on_delete: :cascade
      field :card_id, :big_int

      db_unique_constraint :followup_action_card_unique, field_names: [:action, :card_id]
    end

    # Actions liées (`action_gestion_related`) : paire non orientée, rangée
    # du plus petit identifiant (`least`) au plus grand (`greatest`).
    class Relation < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :least, :many_to_one, to: Partiduo::Followup::Action, related: :relations_up, on_delete: :cascade
      field :greatest, :many_to_one, to: Partiduo::Followup::Action, related: :relations_down, on_delete: :cascade

      db_unique_constraint :followup_relation_unique, field_names: [:least, :greatest]
    end

    # Opération rattachée (`action_gestion_operation`) : référence d'un
    # objet d'un module (`entry:<id>`, `invoice:<id>`…), sans clé étrangère —
    # le Suivi ne dépend d'aucun module (D-FUP-005).
    class Link < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :action, :many_to_one, to: Partiduo::Followup::Action, related: :links, on_delete: :cascade
      field :reference, :string, max_size: 40

      db_unique_constraint :followup_link_unique, field_names: [:action, :reference]
    end

    # Étiquette d'une action (`action_tags`).
    class ActionTag < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :action, :many_to_one, to: Partiduo::Followup::Action, related: :action_tags, on_delete: :cascade
      field :tag, :many_to_one, to: Partiduo::Followup::Tag, related: :action_tags, on_delete: :cascade

      db_unique_constraint :followup_action_tag_unique, field_names: [:action, :tag]
    end
  end
end
