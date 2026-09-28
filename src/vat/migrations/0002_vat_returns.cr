# SPDX-License-Identifier: AGPL-3.0-or-later

# Lot 4 : déclarations de TVA et relevés (successeur du schéma `tva_belge` de
# l'extension TVA d'origine : `declaration_amount`, `assujetti`,
# `intracomm` et leurs lignes, `parameter_chld`, `representative`),
# étendus aux déclarations françaises CA3 et CA12.
#
# Intégrité en base : une déclaration close ne change plus (ni ses cases, ni
# ses lignes) et ne s'efface pas ; seule l'écriture de liquidation peut s'y
# rattacher, une fois. Deux déclarations closes d'un même formulaire ne
# commencent pas le même jour.
class Migration::Vat::V0002 < Marten::Migration
  depends_on :vat, "0001_vat_rates"
  depends_on :cards, "0001_cards"

  def plan
    create_table :vat_return do
      column :id, :big_int, primary_key: true, auto: true
      column :regime, :string, max_size: 2
      column :form, :string, max_size: 20
      column :year, :int
      column :periodicity, :string, max_size: 8
      column :period_number, :int, default: 1
      column :date_from, :date
      column :date_to, :date
      column :exigibility, :string, max_size: 10, default: "rates"
      column :status, :string, max_size: 8, default: "draft"
      column :threshold, :decimal, max_digits: 20, decimal_places: 4, null: true
      column :client_listing_nihil, :bool, default: false
      column :ask_restitution, :bool, default: false
      column :settlement_entry_id, :big_int, null: true
      column :closed_at, :date_time, null: true
      column :closed_by_id, :big_int, null: true
      column :created_by_id, :big_int, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :vat_return_box do
      column :id, :big_int, primary_key: true, auto: true
      column :vat_return_id, :reference, to_table: :vat_return, to_column: :id
      column :code, :string, max_size: 12
      column :computed, :decimal, max_digits: 20, decimal_places: 4
      column :amount, :decimal, max_digits: 20, decimal_places: 4
      column :adjusted, :bool, default: false
    end

    create_table :vat_return_line do
      column :id, :big_int, primary_key: true, auto: true
      column :vat_return_id, :reference, to_table: :vat_return, to_column: :id
      column :position, :int, default: 0
      column :card_id, :big_int, null: true
      column :name, :string, max_size: 255, default: ""
      column :vat_number, :string, max_size: 20, default: ""
      column :code, :string, max_size: 1, default: ""
      column :amount, :decimal, max_digits: 20, decimal_places: 4
      column :vat, :decimal, max_digits: 20, decimal_places: 4
    end

    create_table :vat_box_rule do
      column :id, :big_int, primary_key: true, auto: true
      column :regime, :string, max_size: 2
      column :box, :string, max_size: 12
      column :position, :int, default: 0
      column :vat_rate_id, :big_int, null: true
      column :ledger_kind, :string, max_size: 10, null: true
      column :ledger_id, :big_int, null: true
      column :accounts, :string, max_size: 255, default: ""
      column :excluded_accounts, :string, max_size: 255, default: ""
      column :source, :string, max_size: 12
      column :sign, :string, max_size: 8, default: "all"
      column :operation, :string, max_size: 8, default: "add"
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :vat_setting do
      column :id, :big_int, primary_key: true, auto: true
      column :representative_id, :string, max_size: 30, default: ""
      column :representative_id_type, :string, max_size: 10, default: ""
      column :representative_issued_by, :string, max_size: 2, default: ""
      column :representative_name, :string, max_size: 255, default: ""
      column :representative_street, :string, max_size: 255, default: ""
      column :representative_postcode, :string, max_size: 20, default: ""
      column :representative_city, :string, max_size: 100, default: ""
      column :representative_country_code, :string, max_size: 2, default: ""
      column :representative_email, :string, max_size: 255, default: ""
      column :representative_phone, :string, max_size: 50, default: ""
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    execute(<<-SQL, "SELECT 1")
        ALTER TABLE vat_return
          ADD CONSTRAINT vat_return_regime_check CHECK (regime IN ('be', 'fr')),
          ADD CONSTRAINT vat_return_form_check CHECK (form IN ('be_periodic', 'be_client_listing', 'be_intra_listing', 'fr_ca3', 'fr_ca12')),
          ADD CONSTRAINT vat_return_periodicity_check CHECK (periodicity IN ('month', 'quarter', 'year')),
          ADD CONSTRAINT vat_return_exigibility_check CHECK (exigibility IN ('rates', 'operation', 'payment')),
          ADD CONSTRAINT vat_return_status_check CHECK (status IN ('draft', 'closed')),
          ADD CONSTRAINT vat_return_dates_check CHECK (date_from <= date_to),
          ADD CONSTRAINT vat_return_closed_check CHECK ((status = 'closed') = (closed_at IS NOT NULL))
      SQL
    execute(
      "ALTER TABLE vat_return_line ADD CONSTRAINT vat_return_line_card_fk " \
      "FOREIGN KEY (card_id) REFERENCES cards_card (id) ON DELETE SET NULL",
      "SELECT 1"
    )
    execute(<<-SQL, "SELECT 1")
        ALTER TABLE vat_box_rule
          ADD CONSTRAINT vat_box_rule_rate_fk FOREIGN KEY (vat_rate_id) REFERENCES vat_rate (id) ON DELETE CASCADE,
          ADD CONSTRAINT vat_box_rule_regime_check CHECK (regime IN ('be', 'fr')),
          ADD CONSTRAINT vat_box_rule_ledger_kind_check CHECK (ledger_kind IS NULL OR ledger_kind IN ('purchase', 'sale', 'financial', 'misc')),
          ADD CONSTRAINT vat_box_rule_source_check CHECK (source IN ('base', 'deductible', 'collected', 'balance')),
          ADD CONSTRAINT vat_box_rule_sign_check CHECK (sign IN ('all', 'positive', 'negative')),
          ADD CONSTRAINT vat_box_rule_operation_check CHECK (operation IN ('add', 'subtract'))
      SQL
    execute(
      "CREATE UNIQUE INDEX vat_return_box_code ON vat_return_box (vat_return_id, code)",
      "DROP INDEX IF EXISTS vat_return_box_code"
    )
    execute(
      "CREATE INDEX vat_return_line_return ON vat_return_line (vat_return_id, position)",
      "DROP INDEX IF EXISTS vat_return_line_return"
    )
    execute(
      "CREATE INDEX vat_box_rule_box ON vat_box_rule (regime, box, position)",
      "DROP INDEX IF EXISTS vat_box_rule_box"
    )
    execute(
      "CREATE UNIQUE INDEX vat_return_closed_unique ON vat_return (form, date_from) WHERE status = 'closed'",
      "DROP INDEX IF EXISTS vat_return_closed_unique"
    )

    execute(<<-SQL, "DROP FUNCTION IF EXISTS vat_return_guard() CASCADE")
        CREATE FUNCTION vat_return_guard() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          IF TG_OP = 'DELETE' THEN
            IF OLD.status = 'closed' THEN
              RAISE EXCEPTION 'vat: déclaration % close, suppression interdite', OLD.id
                USING ERRCODE = 'integrity_constraint_violation';
            END IF;
            RETURN OLD;
          END IF;
          IF OLD.status = 'closed' THEN
            IF OLD.settlement_entry_id IS NULL AND NEW.settlement_entry_id IS NOT NULL
               AND (to_jsonb(NEW) - ARRAY['settlement_entry_id', 'updated_at'])
                   = (to_jsonb(OLD) - ARRAY['settlement_entry_id', 'updated_at']) THEN
              RETURN NEW;
            END IF;
            RAISE EXCEPTION 'vat: déclaration % close, modification interdite', OLD.id
              USING ERRCODE = 'integrity_constraint_violation';
          END IF;
          RETURN NEW;
        END
        $$
      SQL
    execute(<<-SQL, "DROP TRIGGER IF EXISTS vat_return_guard ON vat_return")
        CREATE TRIGGER vat_return_guard BEFORE UPDATE OR DELETE ON vat_return
          FOR EACH ROW EXECUTE FUNCTION vat_return_guard()
      SQL

    execute(<<-SQL, "DROP FUNCTION IF EXISTS vat_return_child_guard() CASCADE")
        CREATE FUNCTION vat_return_child_guard() RETURNS trigger LANGUAGE plpgsql AS $$
        DECLARE
          ids bigint[] := ARRAY[]::bigint[];
        BEGIN
          IF TG_OP IN ('UPDATE', 'DELETE') THEN
            ids := ids || OLD.vat_return_id;
          END IF;
          IF TG_OP IN ('INSERT', 'UPDATE') THEN
            ids := ids || NEW.vat_return_id;
          END IF;
          IF EXISTS (SELECT 1 FROM vat_return WHERE id = ANY (ids) AND status = 'closed') THEN
            RAISE EXCEPTION 'vat: % d''une déclaration close, modification interdite', TG_TABLE_NAME
              USING ERRCODE = 'integrity_constraint_violation';
          END IF;
          IF TG_OP = 'DELETE' THEN
            RETURN OLD;
          END IF;
          RETURN NEW;
        END
        $$
      SQL
    execute(<<-SQL, "DROP TRIGGER IF EXISTS vat_return_box_guard ON vat_return_box")
        CREATE TRIGGER vat_return_box_guard BEFORE INSERT OR UPDATE OR DELETE ON vat_return_box
          FOR EACH ROW EXECUTE FUNCTION vat_return_child_guard()
      SQL
    execute(<<-SQL, "DROP TRIGGER IF EXISTS vat_return_line_guard ON vat_return_line")
        CREATE TRIGGER vat_return_line_guard BEFORE INSERT OR UPDATE OR DELETE ON vat_return_line
          FOR EACH ROW EXECUTE FUNCTION vat_return_child_guard()
      SQL
  end
end
