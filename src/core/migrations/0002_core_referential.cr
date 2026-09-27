# SPDX-License-Identifier: AGPL-3.0-or-later

# Lot 1 (référentiel du socle) : exercices et périodes, devises et cours,
# pièces jointes. L'intégrité des périodes est tenue par PostgreSQL : bornes
# ordonnées, aucun chevauchement (successeur du déclencheur
# `comptaproc.check_periode`), période close intouchable.
class Migration::Core::V0002 < Marten::Migration
  depends_on :core, "0001_create_core_settings_table"

  def plan
    create_table :core_fiscal_year do
      column :id, :big_int, primary_key: true, auto: true
      column :year, :int, unique: true
      column :label, :string, max_size: 64, unique: true
      column :closed_at, :date_time, null: true
      column :closed_by_id, :big_int, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :core_period do
      column :id, :big_int, primary_key: true, auto: true
      column :fiscal_year_id, :reference, to_table: :core_fiscal_year, to_column: :id
      column :starts_on, :date
      column :ends_on, :date
      column :closed_at, :date_time, null: true
      column :closed_by_id, :big_int, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :core_currency do
      column :id, :big_int, primary_key: true, auto: true
      column :code, :string, max_size: 3, unique: true
      column :name, :string, max_size: 80
      column :decimals, :int, default: 2
      column :base, :bool, default: false
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :core_currency_rate do
      column :id, :big_int, primary_key: true, auto: true
      column :currency_id, :reference, to_table: :core_currency, to_column: :id
      column :valid_from, :date
      column :rate, :decimal, max_digits: 20, decimal_places: 8
      column :created_at, :date_time
      column :updated_at, :date_time
      unique_constraint :core_currency_rate_unique, [:currency_id, :valid_from]
    end

    create_table :core_attachment do
      column :id, :big_int, primary_key: true, auto: true
      column :storage_name, :string, max_size: 255, unique: true
      column :filename, :string, max_size: 255
      column :content_type, :string, max_size: 128
      column :byte_size, :big_int
      column :sha256, :string, max_size: 64
      column :uploaded_by_id, :big_int, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    execute(<<-SQL)
        ALTER TABLE core_fiscal_year
          ADD CONSTRAINT core_fiscal_year_year_check CHECK (year BETWEEN 1900 AND 2100),
          ADD CONSTRAINT core_fiscal_year_label_check CHECK (btrim(label) <> '')
      SQL
    execute(<<-SQL)
        ALTER TABLE core_period
          ADD CONSTRAINT core_period_bounds_check CHECK (ends_on >= starts_on),
          ADD CONSTRAINT core_period_no_overlap
            EXCLUDE USING gist (daterange(starts_on, ends_on, '[]') WITH &&)
      SQL
    execute(<<-SQL)
        CREATE INDEX core_period_fiscal_year_starts ON core_period (fiscal_year_id, starts_on)
      SQL
    execute(<<-SQL)
        ALTER TABLE core_currency
          ADD CONSTRAINT core_currency_code_check CHECK (code ~ '^[A-Z]{3}$'),
          ADD CONSTRAINT core_currency_decimals_check CHECK (decimals BETWEEN 0 AND 4)
      SQL
    execute(<<-SQL)
        CREATE UNIQUE INDEX core_currency_single_base ON core_currency (base) WHERE base
      SQL
    execute(<<-SQL)
        ALTER TABLE core_currency_rate
          ADD CONSTRAINT core_currency_rate_positive CHECK (rate > 0)
      SQL
    execute(<<-SQL)
        ALTER TABLE core_attachment
          ADD CONSTRAINT core_attachment_size_check CHECK (byte_size >= 0),
          ADD CONSTRAINT core_attachment_sha256_check CHECK (sha256 ~ '^[0-9a-f]{64}$')
      SQL
    execute(
      <<-SQL,
        -- Une période close ne change plus : ni ses bornes, ni son exercice, et
        -- elle ne se supprime pas. Seule sa réouverture (closed_at remis à
        -- NULL) est admise ; un exercice clos interdit aussi la réouverture.
        CREATE FUNCTION core_period_guard() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          IF TG_OP = 'DELETE' THEN
            IF OLD.closed_at IS NOT NULL THEN
              RAISE EXCEPTION 'période % close : suppression refusée', OLD.id
                USING ERRCODE = 'check_violation';
            END IF;
            RETURN OLD;
          END IF;
          IF TG_OP = 'INSERT' THEN
            IF EXISTS (SELECT 1 FROM core_fiscal_year WHERE id = NEW.fiscal_year_id AND closed_at IS NOT NULL) THEN
              RAISE EXCEPTION 'exercice % clos : ajout de période refusé', NEW.fiscal_year_id
                USING ERRCODE = 'check_violation';
            END IF;
            RETURN NEW;
          END IF;
          IF OLD.closed_at IS NOT NULL AND (NEW.starts_on <> OLD.starts_on OR NEW.ends_on <> OLD.ends_on
                                            OR NEW.fiscal_year_id <> OLD.fiscal_year_id) THEN
            RAISE EXCEPTION 'période % close : modification refusée', OLD.id
              USING ERRCODE = 'check_violation';
          END IF;
          IF OLD.closed_at IS NOT NULL AND NEW.closed_at IS NULL
             AND EXISTS (SELECT 1 FROM core_fiscal_year WHERE id = NEW.fiscal_year_id AND closed_at IS NOT NULL) THEN
            RAISE EXCEPTION 'exercice % clos : réouverture de la période % refusée', NEW.fiscal_year_id, OLD.id
              USING ERRCODE = 'check_violation';
          END IF;
          RETURN NEW;
        END;
        $$
        SQL
      "DROP FUNCTION IF EXISTS core_period_guard() CASCADE"
    )
    execute(
      <<-SQL,
        CREATE TRIGGER core_period_guard BEFORE INSERT OR UPDATE OR DELETE ON core_period
          FOR EACH ROW EXECUTE FUNCTION core_period_guard()
        SQL
      "DROP TRIGGER IF EXISTS core_period_guard ON core_period"
    )
    execute(
      <<-SQL,
        -- Période qui contient une date, ou NULL : successeur de
        -- comptaproc.find_periode, pour les contrôles en base des modules.
        CREATE FUNCTION core_period_for(day date) RETURNS bigint LANGUAGE sql STABLE AS $$
          SELECT id FROM core_period WHERE day BETWEEN starts_on AND ends_on
        $$
        SQL
      "DROP FUNCTION IF EXISTS core_period_for(date)"
    )
  end
end
