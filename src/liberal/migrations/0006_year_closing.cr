# SPDX-License-Identifier: AGPL-3.0-or-later

# Clôture réversible de l'exercice libéral (DECISIONS D-LIB5-001 à
# D-LIB5-004). Trois états dans `liberal_year.state` :
#
# * `open` (ouvert) : lignes modifiables et supprimables ;
# * `closed` (clôturé par le professionnel, `close_year`) : lignes figées ;
#   l'exercice se rouvre (`reopen_year`) tant que sa 2035 n'est pas
#   transmise ;
# * `locked` (verrouillé) : 2035 transmise (`tax_return.transmitted`),
#   définitif ; seul le rejet de ce dépôt (`tax_return.rejected`) le rend à
#   l'état `closed`.
#
# `closed_at`/`closed_by_id` (clôture en vigueur), `reopened_at`/
# `reopened_by_id` (dernière réouverture) ; chaque passage est gardé dans
# `liberal_year_change` (qui, quand, quoi). Les déclencheurs refusent toute
# modification dans un exercice `closed` ou `locked` (au lieu d'une année
# seulement transmise) ; `liberal_year_guard` refuse en base de rouvrir un
# exercice verrouillé. La clôture au socle (périodes closes) reste un verrou
# de plus, que le module ne lève pas.
#
# Une année déjà transmise devient `locked`, sa clôture datée de la
# transmission. Retour : déclencheurs de la migration 0003 rétablis,
# colonnes et historique supprimés.
class Migration::Liberal::V0006 < Marten::Migration
  depends_on :liberal, "0005_drop_settings_interface"

  LOCK_KEY = Migration::Liberal::V0003::LOCK_KEY

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
                      WHERE year = extract(year FROM old_day)::int AND state <> 'open') THEN
          RAISE EXCEPTION 'liberal: ligne % d''un exercice figé, intangible : rouvrir l''exercice ou corriger par contre-passation', OLD.id
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
                   WHERE year = extract(year FROM new_day)::int AND state <> 'open') THEN
          RAISE EXCEPTION 'liberal: exercice % clôturé ou verrouillé', extract(year FROM new_day)::int
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
      IF EXISTS (SELECT 1 FROM liberal_year WHERE year = target AND state <> 'open') THEN
        RAISE EXCEPTION 'liberal: exercice % clôturé ou verrouillé', target
          USING ERRCODE = 'integrity_constraint_violation';
      END IF;
      IF TG_OP = 'DELETE' THEN
        RETURN OLD;
      END IF;
      RETURN NEW;
    END
    $$
    SQL

  # Verrou exclusif (la clôture, la réouverture et la transmission attendent
  # les écritures en cours dans les registres) ; un exercice verrouillé ne
  # redevient pas ouvert : seul le rejet de la transmission le rend clôturé.
  YEAR_GUARD = <<-SQL
    CREATE OR REPLACE FUNCTION liberal_year_guard() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      PERFORM pg_advisory_xact_lock(#{LOCK_KEY});
      IF TG_OP = 'UPDATE' AND OLD.state = 'locked' AND NEW.state = 'open' THEN
        RAISE EXCEPTION 'liberal: exercice % verrouillé par la transmission de sa 2035, il ne se rouvre pas', OLD.year
          USING ERRCODE = 'integrity_constraint_violation';
      END IF;
      IF TG_OP = 'DELETE' AND OLD.state <> 'open' THEN
        RAISE EXCEPTION 'liberal: exercice % clôturé, il ne se supprime pas', OLD.year
          USING ERRCODE = 'integrity_constraint_violation';
      END IF;
      IF TG_OP = 'DELETE' THEN
        RETURN OLD;
      END IF;
      RETURN NEW;
    END
    $$
    SQL

  PREVIOUS_YEAR_GUARD = <<-SQL
    CREATE OR REPLACE FUNCTION liberal_year_guard() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      PERFORM pg_advisory_xact_lock(#{LOCK_KEY});
      IF TG_OP = 'DELETE' THEN
        RETURN OLD;
      END IF;
      RETURN NEW;
    END
    $$
    SQL

  STATE_CHECK = "ALTER TABLE liberal_year ADD CONSTRAINT liberal_year_state_check CHECK (" \
                "state IN ('open', 'closed', 'locked') " \
                "AND (state = 'open') = (closed_at IS NULL) " \
                "AND (state = 'locked') = (transmitted_at IS NOT NULL))"

  def plan
    add_column :liberal_year, :state, :string, max_size: 8, default: "open"
    add_column :liberal_year, :closed_at, :date_time, null: true
    add_column :liberal_year, :closed_by_id, :big_int, null: true
    add_column :liberal_year, :reopened_at, :date_time, null: true
    add_column :liberal_year, :reopened_by_id, :big_int, null: true

    create_table :liberal_year_change do
      column :id, :big_int, primary_key: true, auto: true
      column :year, :int, index: true
      column :action, :string, max_size: 16
      column :at, :date_time
      column :user_id, :big_int, null: true
      column :reference, :string, max_size: 128, default: ""
    end

    execute("UPDATE liberal_year SET state = 'locked', closed_at = transmitted_at, closed_by_id = transmitted_by_id " \
            "WHERE transmitted_at IS NOT NULL", "SELECT 1")
    execute("INSERT INTO liberal_year_change (year, action, at, user_id, reference) " \
            "SELECT year, 'locked', transmitted_at, transmitted_by_id, reference FROM liberal_year " \
            "WHERE transmitted_at IS NOT NULL", "SELECT 1")
    execute(STATE_CHECK, "ALTER TABLE liberal_year DROP CONSTRAINT IF EXISTS liberal_year_state_check")
    execute("ALTER TABLE liberal_year_change ADD CONSTRAINT liberal_year_change_action_check " \
            "CHECK (action IN ('closed', 'reopened', 'locked', 'unlocked'))", "SELECT 1")
    execute(GUARD, Migration::Liberal::V0003::GUARD)
    execute(ADJUSTMENT_GUARD, Migration::Liberal::V0003::ADJUSTMENT_GUARD)
    execute(YEAR_GUARD, PREVIOUS_YEAR_GUARD)
  end
end
