# SPDX-License-Identifier: AGPL-3.0-or-later

class Migration::Core::V0001 < Marten::Migration
  def plan
    create_table :core_settings do
      column :id, :big_int, primary_key: true, auto: true
      column :company_name, :string, max_size: 255
      column :legal_form, :string, max_size: 64, default: ""
      column :share_capital, :decimal, max_digits: 20, decimal_places: 4, null: true
      column :rcs, :string, max_size: 128, default: ""
      column :siren, :string, max_size: 9, default: ""
      column :vat_number, :string, max_size: 32, default: ""
      column :street, :string, max_size: 255, default: ""
      column :street_number, :string, max_size: 32, default: ""
      column :postcode, :string, max_size: 16, default: ""
      column :city, :string, max_size: 128, default: ""
      column :country_code, :string, max_size: 2
      column :phone, :string, max_size: 32, default: ""
      column :email, :string, max_size: 254, default: ""
      column :tax_regime, :string, max_size: 2
      column :default_locale, :string, max_size: 8
      column :domain, :string, max_size: 253
      column :auth_methods, :string, max_size: 64
      column :auth_minimum_level, :int
      column :session_duration_minutes, :int
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    # Ligne unique (ADR-001 : `Settings` est une ligne de configuration) : un
    # index unique sur une expression constante interdit une seconde ligne.
    # Régime et niveau d'authentification contraints en base.
    execute(
      "CREATE UNIQUE INDEX core_settings_single_row ON core_settings ((true))",
      "DROP INDEX IF EXISTS core_settings_single_row"
    )
    execute(
      <<-SQL,
        ALTER TABLE core_settings
          ADD CONSTRAINT core_settings_tax_regime_check CHECK (tax_regime IN ('fr', 'be')),
          ADD CONSTRAINT core_settings_auth_level_check CHECK (auth_minimum_level BETWEEN 1 AND 3),
          ADD CONSTRAINT core_settings_share_capital_check CHECK (share_capital IS NULL OR share_capital >= 0)
        SQL
      <<-SQL
        ALTER TABLE core_settings
          DROP CONSTRAINT IF EXISTS core_settings_tax_regime_check,
          DROP CONSTRAINT IF EXISTS core_settings_auth_level_check,
          DROP CONSTRAINT IF EXISTS core_settings_share_capital_check
        SQL
    )
  end
end
