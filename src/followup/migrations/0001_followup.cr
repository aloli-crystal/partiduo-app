# SPDX-License-Identifier: AGPL-3.0-or-later

# Lot 6 — Suivi, successeur de `action_gestion`, `document_type`,
# `action_gestion_comment`, `action_person`, `action_gestion_related`,
# `action_gestion_operation`, `tags` et `action_tags` (hors GED : `document`
# relève de l'extension `partiduo-document`).
#
# Intégrité en base :
#
# * état (`todo`, `follow`, `closed`, `abandoned`) et priorité (1 à 3)
#   contrôlés ; couleur d'étiquette de 1 à 10 ; prochain numéro d'un type au
#   moins 1 ;
# * une action cite des fiches du socle, qui ne peuvent plus disparaître ;
# * une paire d'actions liées est rangée (`least_id < greatest_id`) ;
# * les profils ACCOUNTANT existants reçoivent les permissions du Suivi.
class Migration::Followup::V0001 < Marten::Migration
  depends_on :cards, "0001_cards"
  depends_on :auth, "0002_auth_security"

  CONSTRAINTS = [
    {<<-SQL, "SELECT 1"},
      ALTER TABLE followup_action
        ADD CONSTRAINT followup_action_state_check CHECK (state IN ('todo', 'follow', 'closed', 'abandoned')),
        ADD CONSTRAINT followup_action_priority_check CHECK (priority BETWEEN 1 AND 3),
        ADD CONSTRAINT followup_action_card_fk FOREIGN KEY (card_id)
          REFERENCES cards_card (id) DEFERRABLE INITIALLY DEFERRED,
        ADD CONSTRAINT followup_action_contact_fk FOREIGN KEY (contact_card_id)
          REFERENCES cards_card (id) DEFERRABLE INITIALLY DEFERRED
      SQL
    {"ALTER TABLE followup_action_card ADD CONSTRAINT followup_action_card_card_fk FOREIGN KEY (card_id) " \
     "REFERENCES cards_card (id) DEFERRABLE INITIALLY DEFERRED", "SELECT 1"},
    {"ALTER TABLE followup_relation ADD CONSTRAINT followup_relation_order_check CHECK (least_id < greatest_id)",
     "SELECT 1"},
    {"ALTER TABLE followup_tag ADD CONSTRAINT followup_tag_color_check CHECK (color BETWEEN 1 AND 10)", "SELECT 1"},
    {"ALTER TABLE followup_action_type ADD CONSTRAINT followup_action_type_number_check CHECK (next_number >= 1)",
     "SELECT 1"},
    {"CREATE INDEX followup_action_card_id ON followup_action (card_id)", "DROP INDEX IF EXISTS followup_action_card_id"},
    {"CREATE INDEX followup_action_remind ON followup_action (remind_on) WHERE state IN ('todo', 'follow')",
     "DROP INDEX IF EXISTS followup_action_remind"},
    {"CREATE INDEX followup_link_reference ON followup_link (reference)", "DROP INDEX IF EXISTS followup_link_reference"},
    {"INSERT INTO auth_profile_permission (profile_id, permission) " \
     "SELECT p.id, v.permission FROM auth_profile p, " \
     "(VALUES ('followup.action.read'), ('followup.action.write'), ('followup.settings.write')) AS v (permission) " \
     "WHERE p.code = 'ACCOUNTANT' ON CONFLICT (profile_id, permission) DO NOTHING", "SELECT 1"},
  ]

  def plan
    create_table :followup_tag do
      column :id, :big_int, primary_key: true, auto: true
      column :label, :string, max_size: 60, unique: true
      column :description, :text, default: ""
      column :active, :bool, default: true
      column :color, :int, default: 1
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :followup_action_type do
      column :id, :big_int, primary_key: true, auto: true
      column :code, :string, max_size: 10, unique: true
      column :label, :string, max_size: 80
      column :next_number, :int, default: 1
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :followup_action do
      column :id, :big_int, primary_key: true, auto: true
      column :reference, :string, max_size: 40, unique: true
      column :title, :string, max_size: 255
      column :date, :date
      column :hour, :string, max_size: 5, default: ""
      column :priority, :int, default: 2
      column :state, :string, max_size: 10, default: "todo"
      column :remind_on, :date, null: true
      column :card_id, :big_int, null: true
      column :contact_card_id, :big_int, null: true
      column :owner_id, :big_int, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
      column :action_type_id, :reference, to_table: :followup_action_type, to_column: :id
    end

    create_table :followup_comment do
      column :id, :big_int, primary_key: true, auto: true
      column :text, :text
      column :author_id, :big_int, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
      column :action_id, :reference, to_table: :followup_action, to_column: :id
    end

    create_table :followup_action_card do
      column :id, :big_int, primary_key: true, auto: true
      column :card_id, :big_int
      column :action_id, :reference, to_table: :followup_action, to_column: :id
    end

    create_table :followup_relation do
      column :id, :big_int, primary_key: true, auto: true
      column :least_id, :reference, to_table: :followup_action, to_column: :id
      column :greatest_id, :reference, to_table: :followup_action, to_column: :id
    end

    create_table :followup_link do
      column :id, :big_int, primary_key: true, auto: true
      column :reference, :string, max_size: 40
      column :action_id, :reference, to_table: :followup_action, to_column: :id
    end

    create_table :followup_action_tag do
      column :id, :big_int, primary_key: true, auto: true
      column :action_id, :reference, to_table: :followup_action, to_column: :id
      column :tag_id, :reference, to_table: :followup_tag, to_column: :id
    end

    add_unique_constraint :followup_action_card, :followup_action_card_unique, [:action_id, :card_id]

    add_unique_constraint :followup_relation, :followup_relation_unique, [:least_id, :greatest_id]

    add_unique_constraint :followup_link, :followup_link_unique, [:action_id, :reference]

    add_unique_constraint :followup_action_tag, :followup_action_tag_unique, [:action_id, :tag_id]

    CONSTRAINTS.each { |(forward, backward)| execute(forward, backward) }
  end
end
