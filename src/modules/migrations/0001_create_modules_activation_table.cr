# SPDX-License-Identifier: AGPL-3.0-or-later

class Migration::Modules::V0001 < Marten::Migration
  def plan
    create_table :modules_activation do
      column :id, :big_int, primary_key: true, auto: true
      column :code, :string, max_size: 64, unique: true
      column :active, :bool, default: false
      column :changed_by_id, :big_int, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end
  end
end
