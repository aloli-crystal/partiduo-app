# SPDX-License-Identifier: AGPL-3.0-or-later

# Lot 2F — écritures issues de la Facturation (DECISIONS D-2F-006, D-2F-010) :
#
# * `accounting_entry.reversed` : l'écriture a été extournée. Posé par la
#   base à l'insertion de l'extourne (`accounting_entry_mark_reversed`) et
#   jamais retiré (`accounting_entry_reversed_guard`) ;
# * `accounting_entry_source` : une référence (`invoice:42`, `payment:7`…)
#   ne porte qu'une écriture *en vigueur* (ni extourne, ni extournée). C'est
#   l'idempotence des abonnés de la Facturation tenue par PostgreSQL : deux
#   comptabilisations concurrentes du même événement ne passent pas deux
#   écritures ; une écriture extournée libère sa référence, qui peut être
#   comptabilisée de nouveau ;
# * `accounting_billing_dismissal` : événements du journal du socle écartés
#   de l'historique à comptabiliser (D-INT-003).
class Migration::Accounting::V0004 < Marten::Migration
  depends_on :accounting, "0003_entries_and_matching"
  depends_on :modules, "0002_event_log"

  def plan
    add_column :accounting_entry, :reversed, :bool, default: false

    create_table :accounting_billing_dismissal do
      column :id, :big_int, primary_key: true, auto: true
      column :event_id, :reference, to_table: :modules_event_log, to_column: :id, unique: true
      column :reason, :text, default: ""
      column :created_by_id, :big_int, null: true
      column :created_at, :date_time
    end

    execute(
      "UPDATE accounting_entry e SET reversed = true WHERE EXISTS " \
      "(SELECT 1 FROM accounting_entry r WHERE r.reversal_of_id = e.id)",
      "SELECT 1"
    )
    execute(
      <<-SQL,
        CREATE FUNCTION accounting_entry_mark_reversed() RETURNS trigger
        LANGUAGE plpgsql AS $$
        BEGIN
          IF NEW.reversal_of_id IS NOT NULL THEN
            UPDATE accounting_entry SET reversed = true WHERE id = NEW.reversal_of_id;
          END IF;
          RETURN NULL;
        END;
        $$
        SQL
      "DROP FUNCTION IF EXISTS accounting_entry_mark_reversed() CASCADE"
    )
    execute(
      <<-SQL,
        CREATE TRIGGER accounting_entry_mark_reversed
          AFTER INSERT ON accounting_entry
          FOR EACH ROW EXECUTE FUNCTION accounting_entry_mark_reversed()
        SQL
      "DROP TRIGGER IF EXISTS accounting_entry_mark_reversed ON accounting_entry"
    )
    # Une écriture extournée le reste, même si un modèle relu avant
    # l'extourne est enregistré de nouveau.
    execute(
      <<-SQL,
        CREATE FUNCTION accounting_entry_reversed_guard() RETURNS trigger
        LANGUAGE plpgsql AS $$
        BEGIN
          NEW.reversed := OLD.reversed OR NEW.reversed;
          RETURN NEW;
        END;
        $$
        SQL
      "DROP FUNCTION IF EXISTS accounting_entry_reversed_guard() CASCADE"
    )
    execute(
      <<-SQL,
        CREATE TRIGGER accounting_entry_reversed_guard
          BEFORE UPDATE OF reversed ON accounting_entry
          FOR EACH ROW EXECUTE FUNCTION accounting_entry_reversed_guard()
        SQL
      "DROP TRIGGER IF EXISTS accounting_entry_reversed_guard ON accounting_entry"
    )
    execute(
      <<-SQL,
        CREATE UNIQUE INDEX accounting_entry_source ON accounting_entry (source)
          WHERE source <> '' AND reversal_of_id IS NULL AND NOT reversed
        SQL
      "DROP INDEX IF EXISTS accounting_entry_source"
    )
    # Lecture par référence (`Billing.pending`, `sale_entry`, filtre
    # `EntryQuery#source`), extournes comprises.
    execute(
      "CREATE INDEX accounting_entry_source_all ON accounting_entry (source) WHERE source <> ''",
      "DROP INDEX IF EXISTS accounting_entry_source_all"
    )
  end
end
