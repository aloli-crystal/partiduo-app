# SPDX-License-Identifier: AGPL-3.0-or-later

# Registres modifiables tant que leur période n'est pas close (ADR-007 D1,
# DECISIONS D-MIC2-001) : la « période » d'une ligne est la période de
# déclaration URSSAF (mois ou trimestre) qui contient sa date. Elle est
# close quand elle est déclarée (`micro_declaration`, notée à la main ou
# après la transmission par l'extension URSSAF) ou quand la période du socle
# qui contient la date est close (`core_period.closed_at`).
#
# Le déclencheur `micro_register_guard` :
#
# * refuse la modification ou la suppression d'une ligne dont la date tombe
#   dans une période close ou déclarée ;
# * refuse l'inscription d'une ligne, ou le déplacement d'une ligne, dans une
#   période close ou déclarée ;
# * prend le verrou consultatif `micro_declaration` en partage : une
#   déclaration notée (verrou exclusif, déclencheur
#   `micro_declaration_guard`) attend que les écritures en cours dans les
#   registres soient validées, et toute écriture suivante voit la
#   déclaration.
#
# `modified_at` et `modified_by_id` gardent la trace de la dernière
# modification d'une ligne.
#
# Retour : le déclencheur de la migration 0001 (registres intangibles dès
# l'inscription) est rétabli.
class Migration::Micro::V0003 < Marten::Migration
  depends_on :micro, "0002_official_values"

  LOCK_KEY = "hashtext('micro_declaration')"

  GUARD = <<-SQL
    CREATE OR REPLACE FUNCTION micro_register_guard() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      PERFORM pg_advisory_xact_lock_shared(#{LOCK_KEY});
      IF TG_OP IN ('UPDATE', 'DELETE') THEN
        IF EXISTS (SELECT 1 FROM core_period
                   WHERE OLD.date BETWEEN starts_on AND ends_on AND closed_at IS NOT NULL)
           OR EXISTS (SELECT 1 FROM micro_declaration WHERE OLD.date BETWEEN starts_on AND ends_on) THEN
          RAISE EXCEPTION 'micro: ligne % d''une période close ou déclarée, intangible : corriger par contre-passation', OLD.number
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;
      END IF;
      IF TG_OP IN ('INSERT', 'UPDATE') THEN
        IF EXISTS (SELECT 1 FROM core_period
                   WHERE NEW.date BETWEEN starts_on AND ends_on AND closed_at IS NOT NULL) THEN
          RAISE EXCEPTION 'micro: période close au %', NEW.date
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;
        IF EXISTS (SELECT 1 FROM micro_declaration WHERE NEW.date BETWEEN starts_on AND ends_on) THEN
          RAISE EXCEPTION 'micro: période déclarée au %', NEW.date
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;
      END IF;
      IF TG_OP = 'DELETE' THEN
        RETURN OLD;
      END IF;
      RETURN NEW;
    END
    $$
    SQL

  PREVIOUS_GUARD = <<-SQL
    CREATE OR REPLACE FUNCTION micro_register_guard() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'micro: ligne % du registre intangible, corriger par contre-passation', OLD.number
          USING ERRCODE = 'integrity_constraint_violation';
      END IF;
      IF EXISTS (SELECT 1 FROM core_period
                 WHERE NEW.date BETWEEN starts_on AND ends_on AND closed_at IS NOT NULL) THEN
        RAISE EXCEPTION 'micro: période close au %', NEW.date
          USING ERRCODE = 'integrity_constraint_violation';
      END IF;
      RETURN NEW;
    END
    $$
    SQL

  DECLARATION_GUARD = <<-SQL
    CREATE FUNCTION micro_declaration_guard() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      PERFORM pg_advisory_xact_lock(#{LOCK_KEY});
      IF TG_OP = 'DELETE' THEN
        RETURN OLD;
      END IF;
      RETURN NEW;
    END
    $$
    SQL

  def plan
    add_column :micro_receipt, :modified_at, :date_time, null: true
    add_column :micro_receipt, :modified_by_id, :big_int, null: true
    add_column :micro_purchase, :modified_at, :date_time, null: true
    add_column :micro_purchase, :modified_by_id, :big_int, null: true

    execute(GUARD, PREVIOUS_GUARD)
    execute(DECLARATION_GUARD, "DROP FUNCTION IF EXISTS micro_declaration_guard() CASCADE")
    execute("CREATE TRIGGER micro_declaration_guard BEFORE INSERT OR UPDATE OR DELETE ON micro_declaration " \
            "FOR EACH ROW EXECUTE FUNCTION micro_declaration_guard()",
      "DROP TRIGGER IF EXISTS micro_declaration_guard ON micro_declaration")
  end
end
