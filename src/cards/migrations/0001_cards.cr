# SPDX-License-Identifier: AGPL-3.0-or-later

# Lot 1 : fiches (tiers, articles et services), catégories et attributs
# propres, adresses. L'EAV `fiche_detail` est démonté (ADR-001 D3) : colonnes
# typées + `extra jsonb` indexé en GIN.
class Migration::Cards::V0001 < Marten::Migration
  depends_on :vat, "0001_vat_rates"

  def plan
    create_table :cards_category do
      column :id, :big_int, primary_key: true, auto: true
      column :code, :string, max_size: 32, unique: true
      column :name, :string, max_size: 100
      column :kind, :string, max_size: 16
      column :description, :text, default: ""
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :cards_category_attribute do
      column :id, :big_int, primary_key: true, auto: true
      column :category_id, :reference, to_table: :cards_category, to_column: :id
      column :key, :string, max_size: 40
      column :label, :string, max_size: 100
      column :value_type, :string, max_size: 16
      column :required, :bool, default: false
      column :max_length, :int, null: true
      column :decimals, :int, null: true
      column :position, :int, default: 0
      column :created_at, :date_time
      column :updated_at, :date_time
      unique_constraint :cards_category_attribute_unique, [:category_id, :key]
    end

    create_table :cards_card do
      column :id, :big_int, primary_key: true, auto: true
      column :category_id, :reference, to_table: :cards_category, to_column: :id
      column :code, :string, max_size: 64, unique: true
      column :name, :string, max_size: 255
      column :description, :text, default: ""
      column :enabled, :bool, default: true
      column :vat_number, :string, max_size: 32, default: ""
      column :siren, :string, max_size: 9, default: ""
      column :siret, :string, max_size: 14, default: ""
      column :routing_id, :string, max_size: 100, default: ""
      column :iban, :string, max_size: 34, default: ""
      column :bic, :string, max_size: 11, default: ""
      column :email, :string, max_size: 254, default: ""
      column :phone, :string, max_size: 32, default: ""
      column :contact_name, :string, max_size: 128, default: ""
      column :unit_code, :string, max_size: 3, default: ""
      column :sale_price, :decimal, max_digits: 20, decimal_places: 4, null: true
      column :purchase_price, :decimal, max_digits: 20, decimal_places: 4, null: true
      column :vat_rate_id, :reference, to_table: :vat_rate, to_column: :id, null: true
      column :extra, :json
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :cards_address do
      column :id, :big_int, primary_key: true, auto: true
      column :card_id, :reference, to_table: :cards_card, to_column: :id
      column :kind, :string, max_size: 16
      column :position, :int, default: 0
      column :label, :string, max_size: 100, default: ""
      column :line1, :string, max_size: 255, default: ""
      column :line2, :string, max_size: 255, default: ""
      column :postcode, :string, max_size: 16, default: ""
      column :city, :string, max_size: 128, default: ""
      column :country_code, :string, max_size: 2
    end

    execute(<<-SQL)
        ALTER TABLE cards_category
          ADD CONSTRAINT cards_category_kind_check
            CHECK (kind IN ('customer', 'supplier', 'item', 'bank', 'employee', 'contact', 'other')),
          ADD CONSTRAINT cards_category_code_check CHECK (code ~ '^[A-Z][A-Z0-9_]{0,31}$')
      SQL
    execute(<<-SQL)
        CREATE UNIQUE INDEX cards_category_name_unique ON cards_category (lower(name))
      SQL
    execute(<<-SQL)
        ALTER TABLE cards_category_attribute
          ADD CONSTRAINT cards_category_attribute_type_check
            CHECK (value_type IN ('text', 'number', 'date', 'boolean', 'card')),
          ADD CONSTRAINT cards_category_attribute_key_check CHECK (key ~ '^[a-z][a-z0-9_]{0,39}$')
      SQL
    execute(<<-SQL)
        ALTER TABLE cards_card
          ADD CONSTRAINT cards_card_code_check CHECK (code <> '' AND code = upper(code)),
          ADD CONSTRAINT cards_card_name_check CHECK (btrim(name) <> ''),
          ADD CONSTRAINT cards_card_extra_object CHECK (jsonb_typeof(extra) = 'object'),
          ADD CONSTRAINT cards_card_siren_check CHECK (siren = '' OR siren ~ '^[0-9]{9}$'),
          ADD CONSTRAINT cards_card_siret_check CHECK (siret = '' OR siret ~ '^[0-9]{14}$'),
          ADD CONSTRAINT cards_card_prices_check CHECK (coalesce(sale_price, 0) >= 0 AND coalesce(purchase_price, 0) >= 0)
      SQL
    execute(<<-SQL)
        ALTER TABLE cards_card ALTER COLUMN extra SET DEFAULT '{}'::jsonb
      SQL
    execute(<<-SQL)
        CREATE INDEX cards_card_extra_gin ON cards_card USING gin (extra jsonb_path_ops)
      SQL
    execute(<<-SQL)
        CREATE INDEX cards_card_name_lower ON cards_card (lower(name))
      SQL
    execute(<<-SQL)
        CREATE INDEX cards_card_siren ON cards_card (siren) WHERE siren <> ''
      SQL
    execute(<<-SQL)
        ALTER TABLE cards_address
          ADD CONSTRAINT cards_address_kind_check CHECK (kind IN ('main', 'delivery')),
          ADD CONSTRAINT cards_address_country_check CHECK (country_code ~ '^[A-Z]{2}$')
      SQL
    execute(<<-SQL)
        CREATE UNIQUE INDEX cards_address_single_main ON cards_address (card_id) WHERE kind = 'main'
      SQL
    execute(<<-SQL)
        CREATE INDEX cards_address_card ON cards_address (card_id, kind, position)
      SQL
  end
end
