# SPDX-License-Identifier: AGPL-3.0-or-later

# Module liberal (ADR-007 D6) : paramètres, natures, livre-journal des
# recettes et des dépenses, compteurs, registre des immobilisations et
# cessions, réintégrations et déductions de l'année, table de correspondance
# des lignes de la 2035 par millésime, factures émises relevées.
#
# Intégrité en base :
#
# * livre-journal, immobilisations et cessions *intangibles* : une ligne ne se
#   modifie ni ne s'efface (déclencheur `liberal_register_guard`), la
#   correction est une contre-passation ; aucune ligne n'entre dans une
#   période close du socle (`core_period`) ;
# * réintégrations et déductions figées dès qu'une période de leur année est
#   close (`liberal_adjustment_guard`) ;
# * montants : non nuls, positifs sauf pour une contre-passation (négative),
#   une seule contre-passation par ligne ; part non déductible d'une dépense
#   seulement, de même signe et au plus égale au montant ;
# * valeurs fermées (sens, origine, modes de règlement, catégories
#   d'immobilisation, sortes de réintégration, formulaires) ;
# * une référence d'origine (`source`) n'est inscrite qu'une fois.
class Migration::Liberal::V0001 < Marten::Migration
  depends_on :core, "0003_period_guard_fiscal_year_move"
  depends_on :cards, "0001_cards"

  METHODS     = "('transfer', 'card', 'cheque', 'cash', 'direct_debit', 'other')"
  CATEGORIES  = "('intangible', 'goodwill', 'land', 'building', 'fittings', 'equipment', 'vehicle', 'office', 'furniture', 'other')"
  ADJUSTMENTS = "('reintegration', 'deduction', 'scm_profit', 'scm_loss', 'establishment_costs', 'provision')"

  CONSTRAINTS = [
    {<<-SQL, "SELECT 1"},
      ALTER TABLE liberal_nature ADD CONSTRAINT liberal_nature_kind_check CHECK (kind IN ('receipt', 'expense'))
      SQL
    {<<-SQL, "SELECT 1"},
      ALTER TABLE liberal_line
        ADD CONSTRAINT liberal_line_amount_check CHECK (
          amount <> 0 AND (reversal_of_id IS NULL) = (amount > 0)
          AND (nondeductible_amount = 0 OR (kind = 'expense' AND sign(nondeductible_amount) = sign(amount)
               AND abs(nondeductible_amount) <= abs(amount)))),
        ADD CONSTRAINT liberal_line_values_check CHECK (
          kind IN ('receipt', 'expense') AND origin IN ('manual', 'invoicing') AND method IN #{METHODS}),
        ADD CONSTRAINT liberal_line_nature_fk FOREIGN KEY (nature_id) REFERENCES liberal_nature (id),
        ADD CONSTRAINT liberal_line_reversal_fk FOREIGN KEY (reversal_of_id) REFERENCES liberal_line (id),
        ADD CONSTRAINT liberal_line_card_fk FOREIGN KEY (card_id) REFERENCES cards_card (id)
          DEFERRABLE INITIALLY DEFERRED
      SQL
    {"CREATE UNIQUE INDEX liberal_line_reversal ON liberal_line (reversal_of_id) WHERE reversal_of_id IS NOT NULL",
     "DROP INDEX IF EXISTS liberal_line_reversal"},
    {"CREATE UNIQUE INDEX liberal_line_source ON liberal_line (source) WHERE source <> '' AND reversal_of_id IS NULL",
     "DROP INDEX IF EXISTS liberal_line_source"},
    {"CREATE INDEX liberal_line_date ON liberal_line (date, number)", "DROP INDEX IF EXISTS liberal_line_date"},
    {<<-SQL, "SELECT 1"},
      ALTER TABLE liberal_asset
        ADD CONSTRAINT liberal_asset_amount_check CHECK (
          amount <> 0 AND (reversal_of_id IS NULL) = (amount > 0)
          AND duration_years BETWEEN 0 AND 50 AND service_on >= acquired_on),
        ADD CONSTRAINT liberal_asset_values_check CHECK (category IN #{CATEGORIES} AND method IN #{METHODS}),
        ADD CONSTRAINT liberal_asset_reversal_fk FOREIGN KEY (reversal_of_id) REFERENCES liberal_asset (id),
        ADD CONSTRAINT liberal_asset_card_fk FOREIGN KEY (card_id) REFERENCES cards_card (id)
          DEFERRABLE INITIALLY DEFERRED
      SQL
    {"CREATE UNIQUE INDEX liberal_asset_reversal ON liberal_asset (reversal_of_id) WHERE reversal_of_id IS NOT NULL",
     "DROP INDEX IF EXISTS liberal_asset_reversal"},
    {<<-SQL, "SELECT 1"},
      ALTER TABLE liberal_disposal
        ADD CONSTRAINT liberal_disposal_values_check CHECK (price >= 0 AND method IN #{METHODS}),
        ADD CONSTRAINT liberal_disposal_asset_fk FOREIGN KEY (asset_id) REFERENCES liberal_asset (id)
      SQL
    {<<-SQL, "SELECT 1"},
      ALTER TABLE liberal_adjustment ADD CONSTRAINT liberal_adjustment_values_check CHECK (
        kind IN #{ADJUSTMENTS} AND amount > 0 AND year BETWEEN 1900 AND 2999)
      SQL
    {<<-SQL, "SELECT 1"},
      ALTER TABLE liberal_form_line ADD CONSTRAINT liberal_form_line_values_check CHECK (
        form IN ('2035', '2035-A', '2035-B') AND millesime BETWEEN 2000 AND 2999)
      SQL
    {"ALTER TABLE liberal_counter ADD CONSTRAINT liberal_counter_checks CHECK (register IN ('journal', 'asset') " \
     "AND next_number >= 1)", "SELECT 1"},
    {"ALTER TABLE liberal_settings ADD CONSTRAINT liberal_settings_nature_fk FOREIGN KEY (default_nature_id) " \
     "REFERENCES liberal_nature (id) ON DELETE SET NULL", "SELECT 1"},
    {<<-SQL, "DROP FUNCTION IF EXISTS liberal_register_guard() CASCADE"},
      CREATE FUNCTION liberal_register_guard() RETURNS trigger LANGUAGE plpgsql AS $$
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
    {"CREATE TRIGGER liberal_line_guard BEFORE INSERT OR UPDATE OR DELETE ON liberal_line " \
     "FOR EACH ROW EXECUTE FUNCTION liberal_register_guard()", "DROP TRIGGER IF EXISTS liberal_line_guard ON liberal_line"},
    {"CREATE TRIGGER liberal_asset_guard BEFORE INSERT OR UPDATE OR DELETE ON liberal_asset " \
     "FOR EACH ROW EXECUTE FUNCTION liberal_register_guard()", "DROP TRIGGER IF EXISTS liberal_asset_guard ON liberal_asset"},
    {"CREATE TRIGGER liberal_disposal_guard BEFORE INSERT OR UPDATE OR DELETE ON liberal_disposal " \
     "FOR EACH ROW EXECUTE FUNCTION liberal_register_guard()",
     "DROP TRIGGER IF EXISTS liberal_disposal_guard ON liberal_disposal"},
    {<<-SQL, "DROP FUNCTION IF EXISTS liberal_adjustment_guard() CASCADE"},
      CREATE FUNCTION liberal_adjustment_guard() RETURNS trigger LANGUAGE plpgsql AS $$
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
    {"CREATE TRIGGER liberal_adjustment_guard BEFORE INSERT OR UPDATE OR DELETE ON liberal_adjustment " \
     "FOR EACH ROW EXECUTE FUNCTION liberal_adjustment_guard()",
     "DROP TRIGGER IF EXISTS liberal_adjustment_guard ON liberal_adjustment"},
  ]

  def plan
    create_table :liberal_settings do
      column :id, :big_int, primary_key: true, auto: true
      column :profession, :string, max_size: 100, default: ""
      column :activity_started_on, :date, null: true
      column :default_nature_id, :big_int, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :liberal_nature do
      column :id, :big_int, primary_key: true, auto: true
      column :code, :string, max_size: 32, unique: true
      column :label, :string, max_size: 100
      column :kind, :string, max_size: 10
      column :heading, :string, max_size: 32
      column :enabled, :bool, default: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :liberal_line do
      column :id, :big_int, primary_key: true, auto: true
      column :number, :string, max_size: 20, unique: true
      column :kind, :string, max_size: 10
      column :date, :date
      column :nature_id, :big_int
      column :heading, :string, max_size: 32
      column :amount, :decimal, max_digits: 20, decimal_places: 4
      column :nondeductible_amount, :decimal, max_digits: 20, decimal_places: 4, default: "0.0"
      column :method, :string, max_size: 16
      column :card_id, :big_int, null: true
      column :party_name, :string, max_size: 255, default: ""
      column :label, :string, max_size: 255, default: ""
      column :reference, :string, max_size: 100, default: ""
      column :attachment_id, :big_int, null: true
      column :origin, :string, max_size: 16, default: "manual"
      column :source, :string, max_size: 100, default: ""
      column :reversal_of_id, :big_int, null: true
      column :recorded_by_id, :big_int, null: true
      column :recorded_at, :date_time
    end

    create_table :liberal_counter do
      column :id, :big_int, primary_key: true, auto: true
      column :register, :string, max_size: 10
      column :year, :int
      column :next_number, :int, default: 1
    end

    create_table :liberal_asset do
      column :id, :big_int, primary_key: true, auto: true
      column :number, :string, max_size: 20, unique: true
      column :label, :string, max_size: 255
      column :category, :string, max_size: 16
      column :acquired_on, :date
      column :service_on, :date
      column :amount, :decimal, max_digits: 20, decimal_places: 4
      column :duration_years, :int, default: 0
      column :method, :string, max_size: 16
      column :card_id, :big_int, null: true
      column :party_name, :string, max_size: 255, default: ""
      column :reference, :string, max_size: 100, default: ""
      column :attachment_id, :big_int, null: true
      column :reversal_of_id, :big_int, null: true
      column :recorded_by_id, :big_int, null: true
      column :recorded_at, :date_time
    end

    create_table :liberal_disposal do
      column :id, :big_int, primary_key: true, auto: true
      column :asset_id, :big_int, unique: true
      column :date, :date
      column :price, :decimal, max_digits: 20, decimal_places: 4
      column :method, :string, max_size: 16
      column :reference, :string, max_size: 100, default: ""
      column :recorded_by_id, :big_int, null: true
      column :recorded_at, :date_time
    end

    create_table :liberal_adjustment do
      column :id, :big_int, primary_key: true, auto: true
      column :year, :int
      column :kind, :string, max_size: 24
      column :label, :string, max_size: 255
      column :amount, :decimal, max_digits: 20, decimal_places: 4
      column :recorded_by_id, :big_int, null: true
      column :recorded_at, :date_time
    end

    create_table :liberal_form_line do
      column :id, :big_int, primary_key: true, auto: true
      column :millesime, :int
      column :item, :string, max_size: 40
      column :form, :string, max_size: 10
      column :line, :string, max_size: 10, default: ""
      column :box, :string, max_size: 10, default: ""
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :liberal_invoice do
      column :id, :big_int, primary_key: true, auto: true
      column :invoice_id, :big_int, unique: true
      column :number, :string, max_size: 40, default: ""
      column :card_id, :big_int, null: true
    end

    add_unique_constraint :liberal_counter, :liberal_counter_unique, [:register, :year]
    add_unique_constraint :liberal_form_line, :liberal_form_line_unique, [:millesime, :item]

    CONSTRAINTS.each { |(forward, backward)| execute(forward, backward) }
  end
end
