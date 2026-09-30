# SPDX-License-Identifier: AGPL-3.0-or-later

# Livre-journal et immobilisations modifiables tant que l'exercice est
# ouvert (DECISIONS D-LIB2-001, D-LIB2-002). L'exercice d'une ligne est
# l'année civile de sa date (celle de la 2035) ; il est *figé* :
#
# * quand il est clôturé au socle — chacune de ses dates tombe alors dans
#   une période close (`core_period.closed_at`), ce que le déclencheur
#   vérifiait déjà pour l'inscription ;
# * ou quand sa 2035 est transmise (`liberal_year.transmitted_at`, noté à
#   l'événement `tax_return.transmitted` publié par l'extension qui la
#   transmet).
#
# Le déclencheur `liberal_register_guard` :
#
# * refuse la modification ou la suppression d'une ligne, d'une
#   immobilisation ou d'une cession dont la date (d'acquisition pour une
#   immobilisation) tombe dans une période close du socle ou dans une année
#   dont la 2035 est transmise ;
# * refuse l'inscription, ou le déplacement, vers une telle date ;
# * prend en partage le verrou consultatif `liberal_year`, qu'un nouveau
#   déclencheur `liberal_year_guard` prend en exclusif sur `liberal_year` :
#   la transmission notée attend que les écritures en cours dans les
#   registres soient validées, et toute écriture suivante la voit.
#
# Les réintégrations et déductions d'une année transmise sont figées aussi
# (`liberal_adjustment_guard`). `modified_at` et `modified_by_id` gardent la
# trace de la dernière modification d'une ligne ou d'une immobilisation.
#
# Retour : les déclencheurs de la migration 0001 (registres intangibles dès
# l'inscription) sont rétablis et `liberal_year` supprimée.
class Migration::Liberal::V0003 < Marten::Migration
  depends_on :liberal, "0002_official_form_lines"

  LOCK_KEY = "hashtext('liberal_year')"

  GUARD = <<-SQL
    CREATE OR REPLACE FUNCTION liberal_register_guard() RETURNS trigger LANGUAGE plpgsql AS $$
    DECLARE
      old_day date;
      new_day date;
    BEGIN
      PERFORM pg_advisory_xact_lock_shared(#{LOCK_KEY});
      IF TG_OP IN ('UPDATE', 'DELETE') THEN
        IF TG_TABLE_NAME = 'liberal_asset' THEN
          old_day := OLD.acquired_on;
        ELSE
          old_day := OLD.date;
        END IF;
        IF EXISTS (SELECT 1 FROM core_period
                   WHERE old_day BETWEEN starts_on AND ends_on AND closed_at IS NOT NULL)
           OR EXISTS (SELECT 1 FROM liberal_year
                      WHERE year = extract(year FROM old_day)::int AND transmitted_at IS NOT NULL) THEN
          RAISE EXCEPTION 'liberal: ligne % d''un exercice figé, intangible : corriger par contre-passation', OLD.id
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;
      END IF;
      IF TG_OP IN ('INSERT', 'UPDATE') THEN
        IF TG_TABLE_NAME = 'liberal_asset' THEN
          new_day := NEW.acquired_on;
        ELSE
          new_day := NEW.date;
        END IF;
        IF EXISTS (SELECT 1 FROM core_period
                   WHERE new_day BETWEEN starts_on AND ends_on AND closed_at IS NOT NULL) THEN
          RAISE EXCEPTION 'liberal: période close au %', new_day
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;
        IF EXISTS (SELECT 1 FROM liberal_year
                   WHERE year = extract(year FROM new_day)::int AND transmitted_at IS NOT NULL) THEN
          RAISE EXCEPTION 'liberal: 2035 de l''année % transmise', extract(year FROM new_day)::int
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
    CREATE OR REPLACE FUNCTION liberal_register_guard() RETURNS trigger LANGUAGE plpgsql AS $$
    DECLARE
      day date;
    BEGIN
      IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'liberal: ligne % du registre intangible, corriger par contre-passation', OLD.id
          USING ERRCODE = 'integrity_constraint_violation';
      END IF;
      IF TG_TABLE_NAME = 'liberal_asset' THEN
        day := NEW.acquired_on;
      ELSE
        day := NEW.date;
      END IF;
      IF EXISTS (SELECT 1 FROM core_period
                 WHERE day BETWEEN starts_on AND ends_on AND closed_at IS NOT NULL) THEN
        RAISE EXCEPTION 'liberal: période close au %', day
          USING ERRCODE = 'integrity_constraint_violation';
      END IF;
      RETURN NEW;
    END
    $$
    SQL

  ADJUSTMENT_GUARD = <<-SQL
    CREATE OR REPLACE FUNCTION liberal_adjustment_guard() RETURNS trigger LANGUAGE plpgsql AS $$
    DECLARE
      target int;
    BEGIN
      PERFORM pg_advisory_xact_lock_shared(#{LOCK_KEY});
      target := CASE TG_OP WHEN 'INSERT' THEN NEW.year ELSE OLD.year END;
      IF TG_OP = 'UPDATE' AND NEW.year <> OLD.year THEN
        RAISE EXCEPTION 'liberal: année d''une réintégration non modifiable'
          USING ERRCODE = 'integrity_constraint_violation';
      END IF;
      IF EXISTS (SELECT 1 FROM core_period
                 WHERE closed_at IS NOT NULL
                   AND starts_on <= make_date(target, 12, 31) AND ends_on >= make_date(target, 1, 1)) THEN
        RAISE EXCEPTION 'liberal: année % close', target
          USING ERRCODE = 'integrity_constraint_violation';
      END IF;
      IF EXISTS (SELECT 1 FROM liberal_year WHERE year = target AND transmitted_at IS NOT NULL) THEN
        RAISE EXCEPTION 'liberal: 2035 de l''année % transmise, année close', target
          USING ERRCODE = 'integrity_constraint_violation';
      END IF;
      IF TG_OP = 'DELETE' THEN
        RETURN OLD;
      END IF;
      RETURN NEW;
    END
    $$
    SQL

  PREVIOUS_ADJUSTMENT_GUARD = <<-SQL
    CREATE OR REPLACE FUNCTION liberal_adjustment_guard() RETURNS trigger LANGUAGE plpgsql AS $$
    DECLARE
      target int;
    BEGIN
      target := CASE TG_OP WHEN 'INSERT' THEN NEW.year ELSE OLD.year END;
      IF TG_OP = 'UPDATE' AND NEW.year <> OLD.year THEN
        RAISE EXCEPTION 'liberal: année d''une réintégration non modifiable'
          USING ERRCODE = 'integrity_constraint_violation';
      END IF;
      IF EXISTS (SELECT 1 FROM core_period
                 WHERE closed_at IS NOT NULL
                   AND starts_on <= make_date(target, 12, 31) AND ends_on >= make_date(target, 1, 1)) THEN
        RAISE EXCEPTION 'liberal: année % close', target
          USING ERRCODE = 'integrity_constraint_violation';
      END IF;
      IF TG_OP = 'DELETE' THEN
        RETURN OLD;
      END IF;
      RETURN NEW;
    END
    $$
    SQL

  YEAR_GUARD = <<-SQL
    CREATE FUNCTION liberal_year_guard() RETURNS trigger LANGUAGE plpgsql AS $$
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
    create_table :liberal_year do
      column :id, :big_int, primary_key: true, auto: true
      column :year, :int, unique: true
      column :transmitted_at, :date_time, null: true
      column :transmitted_by_id, :big_int, null: true
      column :reference, :string, max_size: 128, default: ""
      column :transmitted_fingerprint, :string, max_size: 64, default: ""
      column :frozen_fingerprint, :string, max_size: 64, default: ""
      column :frozen_at, :date_time, null: true
    end

    add_column :liberal_line, :modified_at, :date_time, null: true
    add_column :liberal_line, :modified_by_id, :big_int, null: true
    add_column :liberal_asset, :modified_at, :date_time, null: true
    add_column :liberal_asset, :modified_by_id, :big_int, null: true

    execute("ALTER TABLE liberal_year ADD CONSTRAINT liberal_year_values_check CHECK (year BETWEEN 1900 AND 2999)",
      "SELECT 1")
    execute(GUARD, PREVIOUS_GUARD)
    execute(ADJUSTMENT_GUARD, PREVIOUS_ADJUSTMENT_GUARD)
    execute(YEAR_GUARD, "DROP FUNCTION IF EXISTS liberal_year_guard() CASCADE")
    execute("CREATE TRIGGER liberal_year_guard BEFORE INSERT OR UPDATE OR DELETE ON liberal_year " \
            "FOR EACH ROW EXECUTE FUNCTION liberal_year_guard()",
      "DROP TRIGGER IF EXISTS liberal_year_guard ON liberal_year")
  end
end
