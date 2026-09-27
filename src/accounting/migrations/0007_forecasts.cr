# SPDX-License-Identifier: AGPL-3.0-or-later

# Lot 6 — prévisions budgétaires, successeur de `forecast`,
# `forecast_category` et `forecast_item` (les éléments à `fi_pid` non nul
# deviennent des montants par période, `accounting_forecast_amount`,
# D-FCT-002). Les périodes citées sont celles du socle : clés étrangères
# vers `core_period`, qui ne peuvent plus disparaître.
class Migration::Accounting::V0007 < Marten::Migration
  depends_on :accounting, "0006_entry_line_input_index"
  depends_on :core, "0003_period_guard_fiscal_year_move"

  CONSTRAINTS = [
    {<<-SQL, "SELECT 1"},
      ALTER TABLE accounting_forecast
        ADD CONSTRAINT accounting_forecast_start_fk FOREIGN KEY (start_period_id)
          REFERENCES core_period (id) DEFERRABLE INITIALLY DEFERRED,
        ADD CONSTRAINT accounting_forecast_end_fk FOREIGN KEY (end_period_id)
          REFERENCES core_period (id) DEFERRABLE INITIALLY DEFERRED
      SQL
    {"ALTER TABLE accounting_forecast_amount ADD CONSTRAINT accounting_forecast_amount_period_fk " \
     "FOREIGN KEY (period_id) REFERENCES core_period (id) DEFERRABLE INITIALLY DEFERRED", "SELECT 1"},
  ]

  def plan
    create_table :accounting_forecast do
      column :id, :big_int, primary_key: true, auto: true
      column :name, :string, max_size: 255
      column :start_period_id, :big_int
      column :end_period_id, :big_int
      column :created_by_id, :big_int, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :accounting_forecast_category do
      column :id, :big_int, primary_key: true, auto: true
      column :label, :string, max_size: 255
      column :position, :int, default: 0
      column :forecast_id, :reference, to_table: :accounting_forecast, to_column: :id
    end

    create_table :accounting_forecast_item do
      column :id, :big_int, primary_key: true, auto: true
      column :label, :string, max_size: 255
      column :formula, :text
      column :amount, :decimal, max_digits: 20, decimal_places: 4, default: "0.0"
      column :initial_amount, :decimal, max_digits: 20, decimal_places: 4, default: "0.0"
      column :position, :int, default: 0
      column :category_id, :reference, to_table: :accounting_forecast_category, to_column: :id
    end

    create_table :accounting_forecast_amount do
      column :id, :big_int, primary_key: true, auto: true
      column :period_id, :big_int
      column :amount, :decimal, max_digits: 20, decimal_places: 4
      column :item_id, :reference, to_table: :accounting_forecast_item, to_column: :id
    end

    add_unique_constraint :accounting_forecast_amount, :accounting_forecast_amount_unique, [:item_id, :period_id]

    CONSTRAINTS.each { |(forward, backward)| execute(forward, backward) }
  end
end
