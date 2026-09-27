# SPDX-License-Identifier: AGPL-3.0-or-later

# Lot 6 — Stock, successeur de `stock_repository`, `stock_goods`,
# `stock_change` et de l'attribut « code stock » des fiches (`ATTR_DEF_STOCK`).
#
# Intégrité en base :
#
# * un mouvement a un sens `in` ou `out`, une quantité strictement positive,
#   un coût unitaire nul ou positif ; il cite une fiche du socle, qui ne peut
#   plus disparaître ;
# * un article suivi disparaît avec sa fiche (lien accessoire, D-ACC-001) ;
# * une opération manuelle est `change` ou `inventory` ;
# * paramètres : une seule ligne (`singleton`, D-ANA-017), créée ici ;
# * les profils ACCOUNTANT existants reçoivent les permissions du Stock.
class Migration::Stock::V0001 < Marten::Migration
  depends_on :cards, "0001_cards"
  depends_on :core, "0003_period_guard_fiscal_year_move"
  depends_on :auth, "0002_auth_security"

  CONSTRAINTS = [
    {<<-SQL, "SELECT 1"},
      ALTER TABLE stock_movement
        ADD CONSTRAINT stock_movement_direction_check CHECK (direction IN ('in', 'out')),
        ADD CONSTRAINT stock_movement_quantity_check CHECK (quantity > 0),
        ADD CONSTRAINT stock_movement_unit_cost_check CHECK (unit_cost IS NULL OR unit_cost >= 0),
        ADD CONSTRAINT stock_movement_card_fk FOREIGN KEY (card_id)
          REFERENCES cards_card (id) DEFERRABLE INITIALLY DEFERRED
      SQL
    {"ALTER TABLE stock_item ADD CONSTRAINT stock_item_card_fk FOREIGN KEY (card_id) " \
     "REFERENCES cards_card (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED", "SELECT 1"},
    {"ALTER TABLE stock_change ADD CONSTRAINT stock_change_kind_check CHECK (kind IN ('change', 'inventory'))",
     "SELECT 1"},
    {"ALTER TABLE stock_setting ALTER COLUMN singleton SET NOT NULL, " \
     "ADD CONSTRAINT stock_setting_singleton UNIQUE (singleton), " \
     "ADD CONSTRAINT stock_setting_singleton_check CHECK (singleton)", "SELECT 1"},
    {"INSERT INTO stock_setting (singleton, created_at, updated_at) VALUES (true, now(), now()) " \
     "ON CONFLICT (singleton) DO NOTHING", "SELECT 1"},
    {"CREATE INDEX stock_movement_code_date ON stock_movement (stock_code, date)",
     "DROP INDEX IF EXISTS stock_movement_code_date"},
    {"CREATE INDEX stock_movement_repository_date ON stock_movement (repository_id, date)",
     "DROP INDEX IF EXISTS stock_movement_repository_date"},
    {"CREATE INDEX stock_movement_source ON stock_movement (source) WHERE source <> ''",
     "DROP INDEX IF EXISTS stock_movement_source"},
    {"CREATE INDEX stock_movement_card ON stock_movement (card_id)", "DROP INDEX IF EXISTS stock_movement_card"},
    {"INSERT INTO auth_profile_permission (profile_id, permission) " \
     "SELECT p.id, v.permission FROM auth_profile p, " \
     "(VALUES ('stock.movement.read'), ('stock.movement.write'), ('stock.settings.write')) AS v (permission) " \
     "WHERE p.code = 'ACCOUNTANT' ON CONFLICT (profile_id, permission) DO NOTHING", "SELECT 1"},
  ]

  def plan
    create_table :stock_item do
      column :id, :big_int, primary_key: true, auto: true
      column :card_id, :big_int, unique: true
      column :stock_code, :string, max_size: 40
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :stock_repository do
      column :id, :big_int, primary_key: true, auto: true
      column :name, :string, max_size: 100, unique: true
      column :address, :text, default: ""
      column :city, :string, max_size: 100, default: ""
      column :country_code, :string, max_size: 2, default: ""
      column :phone, :string, max_size: 40, default: ""
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :stock_setting do
      column :id, :big_int, primary_key: true, auto: true
      column :singleton, :bool, default: true
      column :created_at, :date_time
      column :updated_at, :date_time
      column :default_repository_id, :reference, to_table: :stock_repository, to_column: :id, null: true
    end

    create_table :stock_change do
      column :id, :big_int, primary_key: true, auto: true
      column :kind, :string, max_size: 12, default: "change"
      column :date, :date
      column :comment, :text, default: ""
      column :created_by_id, :big_int, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
      column :repository_id, :reference, to_table: :stock_repository, to_column: :id
    end

    create_table :stock_movement do
      column :id, :big_int, primary_key: true, auto: true
      column :card_id, :big_int
      column :stock_code, :string, max_size: 40
      column :direction, :string, max_size: 3
      column :quantity, :decimal, max_digits: 20, decimal_places: 4
      column :unit_cost, :decimal, max_digits: 20, decimal_places: 4, null: true
      column :date, :date
      column :comment, :text, default: ""
      column :source, :string, max_size: 40, default: ""
      column :created_by_id, :big_int, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
      column :repository_id, :reference, to_table: :stock_repository, to_column: :id
      column :change_id, :reference, to_table: :stock_change, to_column: :id, null: true
    end

    CONSTRAINTS.each { |(forward, backward)| execute(forward, backward) }
  end
end
