# SPDX-License-Identifier: AGPL-3.0-or-later

# Journal des événements rejouables (D-INT-002) : une ligne ne se modifie pas.
class Migration::Modules::V0002 < Marten::Migration
  depends_on :modules, "0001_create_modules_activation_table"

  def plan
    create_table :modules_event_log do
      column :id, :big_int, primary_key: true, auto: true
      column :name, :string, max_size: 64, index: true
      column :payload, :json
      column :actor_user_id, :big_int, null: true
      column :created_at, :date_time
    end

    execute(
      <<-SQL,
        CREATE FUNCTION modules_event_log_frozen() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          RAISE EXCEPTION 'modules_event_log : une entrée du journal ne se modifie pas';
        END;
        $$
        SQL
      "DROP FUNCTION IF EXISTS modules_event_log_frozen()"
    )
    execute(
      <<-SQL,
        CREATE TRIGGER modules_event_log_guard BEFORE UPDATE ON modules_event_log
          FOR EACH ROW EXECUTE FUNCTION modules_event_log_frozen()
        SQL
      "DROP TRIGGER IF EXISTS modules_event_log_guard ON modules_event_log"
    )
  end
end
