# SPDX-License-Identifier: AGPL-3.0-or-later

# Lot 5 — Analytique, successeur de `plan_analytique`, `groupe_analytique`,
# `poste_analytique`, `operation_analytique`, `key_distribution` et de ses
# tables de détail, ainsi que des paramètres `MY_ANALYTIC` / `MY_ANC_FILTER`.
#
# Intégrité en base :
#
# * une opération cite un poste *de son plan* (clé étrangère composée
#   `(post_id, plan_id)`), une seule fois par ligne et par plan ; montant
#   strictement positif, sens `debit` ou `credit` ;
# * une ventilation cite sa ligne d'écriture (une seule ventilation par
#   ligne), son écriture et son journal ; une opération diverse n'en cite
#   aucun ; une ligne d'écriture ventilée ne peut plus disparaître ;
# * `analytic_distribution_guard` : aucune imputation créée, modifiée ou
#   retirée à une date d'une période close (ni d'un exercice clos), comme
#   le refus de `Anc_Account_Table::delete` ;
# * les profils ACCOUNTANT existants reçoivent `analytic.operation.write`.
class Migration::Analytic::V0001 < Marten::Migration
  depends_on :accounting, "0005_reports"
  depends_on :core, "0003_period_guard_fiscal_year_move"
  depends_on :cards, "0001_cards"
  depends_on :auth, "0002_auth_security"

  CONSTRAINTS = [
    {"ALTER TABLE analytic_plan ADD CONSTRAINT analytic_plan_name_check CHECK (name ~ '^[^[:space:]]+$')", "SELECT 1"},
    {"ALTER TABLE analytic_group ADD CONSTRAINT analytic_group_code_check CHECK (code ~ '^[^[:space:]]+$')", "SELECT 1"},
    {"ALTER TABLE analytic_post ADD CONSTRAINT analytic_post_code_check CHECK (code ~ '^[^[:space:]]+$'), " \
     "ADD CONSTRAINT analytic_post_id_plan UNIQUE (id, plan_id)", "SELECT 1"},
    {"ALTER TABLE analytic_key_row ADD CONSTRAINT analytic_key_row_percent_check CHECK (percent > 0 AND percent <= 100)",
     "SELECT 1"},
    {"ALTER TABLE analytic_key_row_post ADD CONSTRAINT analytic_key_row_post_plan_fk FOREIGN KEY (post_id, plan_id) " \
     "REFERENCES analytic_post (id, plan_id) DEFERRABLE INITIALLY DEFERRED", "SELECT 1"},
    {"ALTER TABLE analytic_key_ledger ADD CONSTRAINT analytic_key_ledger_ledger_fk FOREIGN KEY (ledger_id) " \
     "REFERENCES accounting_ledger (id) ON DELETE CASCADE", "SELECT 1"},
    {<<-SQL, "SELECT 1"},
      ALTER TABLE analytic_distribution
        ADD CONSTRAINT analytic_distribution_kind_check CHECK (
          (kind = 'entry' AND entry_line_id IS NOT NULL AND entry_id IS NOT NULL)
          OR (kind = 'misc' AND entry_line_id IS NULL AND entry_id IS NULL AND ledger_id IS NULL)),
        ADD CONSTRAINT analytic_distribution_entry_fk FOREIGN KEY (entry_id)
          REFERENCES accounting_entry (id) DEFERRABLE INITIALLY DEFERRED,
        ADD CONSTRAINT analytic_distribution_line_fk FOREIGN KEY (entry_line_id)
          REFERENCES accounting_entry_line (id) DEFERRABLE INITIALLY DEFERRED,
        ADD CONSTRAINT analytic_distribution_ledger_fk FOREIGN KEY (ledger_id)
          REFERENCES accounting_ledger (id) DEFERRABLE INITIALLY DEFERRED
      SQL
    {<<-SQL, "SELECT 1"},
      ALTER TABLE analytic_operation
        ADD CONSTRAINT analytic_operation_amount_check CHECK (amount > 0),
        ADD CONSTRAINT analytic_operation_side_check CHECK (side IN ('debit', 'credit')),
        ADD CONSTRAINT analytic_operation_post_plan_fk FOREIGN KEY (post_id, plan_id)
          REFERENCES analytic_post (id, plan_id) DEFERRABLE INITIALLY DEFERRED,
        ADD CONSTRAINT analytic_operation_card_fk FOREIGN KEY (card_id)
          REFERENCES cards_card (id) DEFERRABLE INITIALLY DEFERRED
      SQL
    {"CREATE INDEX analytic_operation_post ON analytic_operation (post_id)",
     "DROP INDEX IF EXISTS analytic_operation_post"},
    {"CREATE INDEX analytic_operation_distribution ON analytic_operation (distribution_id, row)",
     "DROP INDEX IF EXISTS analytic_operation_distribution"},
    {"CREATE INDEX analytic_distribution_date ON analytic_distribution (date)",
     "DROP INDEX IF EXISTS analytic_distribution_date"},
    {"CREATE INDEX analytic_distribution_entry ON analytic_distribution (entry_id)",
     "DROP INDEX IF EXISTS analytic_distribution_entry"},
  ]

  CLOSED_PERIOD_GUARD = [
    {<<-SQL, "DROP FUNCTION IF EXISTS analytic_date_closed(date)"},
      CREATE FUNCTION analytic_date_closed(p_date date) RETURNS boolean
      LANGUAGE sql STABLE AS $$
        SELECT EXISTS (
          SELECT 1 FROM core_period p JOIN core_fiscal_year y ON y.id = p.fiscal_year_id
          WHERE p_date BETWEEN p.starts_on AND p.ends_on
            AND (p.closed_at IS NOT NULL OR y.closed_at IS NOT NULL))
      $$
      SQL
    {<<-SQL, "DROP FUNCTION IF EXISTS analytic_distribution_guard()"},
      CREATE FUNCTION analytic_distribution_guard() RETURNS trigger
      LANGUAGE plpgsql AS $$
      DECLARE
        v_date date;
      BEGIN
        IF TG_TABLE_NAME = 'analytic_distribution' THEN
          IF TG_OP IN ('UPDATE', 'DELETE') AND analytic_date_closed(OLD.date) THEN
            RAISE EXCEPTION 'analytic_distribution % : période close', OLD.id USING ERRCODE = 'check_violation';
          END IF;
          IF TG_OP IN ('INSERT', 'UPDATE') AND analytic_date_closed(NEW.date) THEN
            RAISE EXCEPTION 'analytic_distribution : période close (%)', NEW.date USING ERRCODE = 'check_violation';
          END IF;
        ELSE
          IF TG_OP IN ('UPDATE', 'DELETE') THEN
            SELECT date INTO v_date FROM analytic_distribution WHERE id = OLD.distribution_id;
            IF FOUND AND analytic_date_closed(v_date) THEN
              RAISE EXCEPTION 'analytic_operation % : période close', OLD.id USING ERRCODE = 'check_violation';
            END IF;
          END IF;
          IF TG_OP IN ('INSERT', 'UPDATE') THEN
            SELECT date INTO v_date FROM analytic_distribution WHERE id = NEW.distribution_id;
            IF FOUND AND analytic_date_closed(v_date) THEN
              RAISE EXCEPTION 'analytic_operation : période close (%)', v_date USING ERRCODE = 'check_violation';
            END IF;
          END IF;
        END IF;
        IF TG_OP = 'DELETE' THEN
          RETURN OLD;
        END IF;
        RETURN NEW;
      END
      $$
      SQL
    {"CREATE TRIGGER analytic_distribution_guard BEFORE INSERT OR UPDATE OR DELETE ON analytic_distribution " \
     "FOR EACH ROW EXECUTE FUNCTION analytic_distribution_guard()",
     "DROP TRIGGER IF EXISTS analytic_distribution_guard ON analytic_distribution"},
    {"CREATE TRIGGER analytic_operation_guard BEFORE INSERT OR UPDATE OR DELETE ON analytic_operation " \
     "FOR EACH ROW EXECUTE FUNCTION analytic_distribution_guard()",
     "DROP TRIGGER IF EXISTS analytic_operation_guard ON analytic_operation"},
  ]

  def plan
    create_table :analytic_plan do
      column :id, :big_int, primary_key: true, auto: true
      column :name, :string, max_size: 100, unique: true
      column :description, :text, default: ""
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :analytic_group do
      column :id, :big_int, primary_key: true, auto: true
      column :code, :string, max_size: 10
      column :description, :text, default: ""
      column :plan_id, :reference, to_table: :analytic_plan, to_column: :id
    end

    create_table :analytic_post do
      column :id, :big_int, primary_key: true, auto: true
      column :code, :string, max_size: 100
      column :description, :text, default: ""
      column :active, :bool, default: true
      column :plan_id, :reference, to_table: :analytic_plan, to_column: :id
      column :group_id, :reference, to_table: :analytic_group, to_column: :id, null: true
    end

    create_table :analytic_key do
      column :id, :big_int, primary_key: true, auto: true
      column :name, :string, max_size: 100
      column :description, :text, default: ""
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :analytic_key_row do
      column :id, :big_int, primary_key: true, auto: true
      column :position, :int, default: 0
      column :percent, :decimal, max_digits: 20, decimal_places: 4
      column :key_id, :reference, to_table: :analytic_key, to_column: :id
    end

    create_table :analytic_key_row_post do
      column :id, :big_int, primary_key: true, auto: true
      column :row_id, :reference, to_table: :analytic_key_row, to_column: :id
      column :plan_id, :reference, to_table: :analytic_plan, to_column: :id
      column :post_id, :reference, to_table: :analytic_post, to_column: :id
    end

    create_table :analytic_key_ledger do
      column :id, :big_int, primary_key: true, auto: true
      column :ledger_id, :big_int
      column :key_id, :reference, to_table: :analytic_key, to_column: :id
    end

    create_table :analytic_distribution do
      column :id, :big_int, primary_key: true, auto: true
      column :kind, :string, max_size: 5, default: "entry"
      column :entry_id, :big_int, null: true
      column :entry_line_id, :big_int, null: true, unique: true
      column :ledger_id, :big_int, null: true
      column :ledger_code, :string, max_size: 20, default: ""
      column :internal_code, :string, max_size: 20, default: ""
      column :receipt, :string, max_size: 40, default: ""
      column :account_number, :string, max_size: 40, default: ""
      column :account_label, :string, max_size: 255, default: ""
      column :line_amount, :decimal, max_digits: 20, decimal_places: 4, null: true
      column :date, :date
      column :description, :text, default: ""
      column :created_by_id, :big_int, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :analytic_operation do
      column :id, :big_int, primary_key: true, auto: true
      column :row, :int, default: 0
      column :amount, :decimal, max_digits: 20, decimal_places: 4
      column :side, :string, max_size: 6
      column :card_id, :big_int, null: true
      column :card_code, :string, max_size: 40, default: ""
      column :distribution_id, :reference, to_table: :analytic_distribution, to_column: :id
      column :plan_id, :reference, to_table: :analytic_plan, to_column: :id
      column :post_id, :reference, to_table: :analytic_post, to_column: :id
    end

    create_table :analytic_setting do
      column :id, :big_int, primary_key: true, auto: true
      column :mandatory, :bool, default: false
      column :account_filter, :string, max_size: 255, default: "6,7"
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    add_unique_constraint :analytic_group, :analytic_group_plan_code, [:plan_id, :code]
    add_unique_constraint :analytic_post, :analytic_post_plan_code, [:plan_id, :code]
    add_unique_constraint :analytic_operation, :analytic_operation_row_plan, [:distribution_id, :row, :plan_id]
    add_unique_constraint :analytic_key_row_post, :analytic_key_row_post_plan, [:row_id, :plan_id]
    add_unique_constraint :analytic_key_ledger, :analytic_key_ledger_unique, [:key_id, :ledger_id]

    # --- Contraintes de colonnes et références ---------------------------------

    CONSTRAINTS.each { |(forward, backward)| execute(forward, backward) }

    # --- Périodes closes ---------------------------------------------------------

    CLOSED_PERIOD_GUARD.each { |(forward, backward)| execute(forward, backward) }

    # --- Permission de ventilation des profils existants -------------------------

    execute(
      "INSERT INTO auth_profile_permission (profile_id, permission) " \
      "SELECT id, 'analytic.operation.write' FROM auth_profile WHERE code = 'ACCOUNTANT' " \
      "ON CONFLICT (profile_id, permission) DO NOTHING",
      "SELECT 1"
    )
  end
end
