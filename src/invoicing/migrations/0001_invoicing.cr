# SPDX-License-Identifier: AGPL-3.0-or-later

# Lot F : module Facturation (ADR-006 D5). Tables générées par Marten, puis
# règles fiscales tenues par PostgreSQL : numéro unique par série, compteurs
# qui n'avancent que d'une unité, document émis intangible (ni modification
# hors état et règlements, ni suppression), lignes et acomptes d'un document
# émis figés, journal des opérations en ajout seul. Chaque instruction SQL a
# son inverse (retour arrière sans fonction orpheline).
class Migration::Invoicing::V0001 < Marten::Migration
  depends_on :core, "0003_period_guard_fiscal_year_move"
  depends_on :cards, "0001_cards"
  depends_on :vat, "0001_vat_rates"

  def plan
    create_table :invoicing_settings do
      column :id, :big_int, primary_key: true, auto: true
      column :payment_terms_days, :int, default: 30
      column :quote_validity_days, :int, default: 30
      column :late_penalty_rate, :decimal, max_digits: 7, decimal_places: 4, null: true
      column :early_discount_rate, :decimal, max_digits: 7, decimal_places: 4, null: true
      column :early_discount_days, :int, null: true
      column :vat_on_debits, :bool, default: false
      column :default_operation_category, :string, max_size: 16, default: "services"
      column :iban, :string, max_size: 34, default: ""
      column :bic, :string, max_size: 11, default: ""
      column :sender_email, :string, max_size: 254, default: ""
      column :sender_name, :string, max_size: 128, default: ""
      column :reminder1_days, :int, default: 7
      column :reminder2_days, :int, default: 30
      column :reminder3_days, :int, default: 60
      column :penalty_from_level, :int, default: 2
      column :reminder_subject, :string, max_size: 255, default: ""
      column :reminder_body, :text, default: ""
      column :sales_journal_code, :string, max_size: 8, default: "VT"
      column :bank_journal_code, :string, max_size: 8, default: "BQ"
      column :customer_account, :string, max_size: 20, default: ""
      column :sales_account, :string, max_size: 20, default: ""
      column :vat_account, :string, max_size: 20, default: ""
      column :bank_account, :string, max_size: 20, default: ""
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :invoicing_counter do
      column :id, :big_int, primary_key: true, auto: true
      column :series, :string, max_size: 16
      column :year, :int
      column :last_number, :int, default: 0
      column :last_date, :date, null: true

      unique_constraint :invoicing_counter_series_year, [:series, :year]
    end

    create_table :invoicing_layout do
      column :id, :big_int, primary_key: true, auto: true
      column :name, :string, max_size: 100, unique: true
      column :primary_color, :string, max_size: 7, default: "#1f5f73"
      column :text_color, :string, max_size: 7, default: "#1a1a1a"
      column :header_text, :text, default: ""
      column :footer_text, :text, default: ""
      column :is_default, :bool, default: false
      column :created_at, :date_time
      column :updated_at, :date_time
      column :logo_id, :reference, to_table: :core_attachment, to_column: :id, null: true
    end

    create_table :invoicing_document do
      column :id, :big_int, primary_key: true, auto: true
      column :kind, :string, max_size: 16
      column :status, :string, max_size: 16, default: "draft"
      column :series, :string, max_size: 16
      column :year, :int, null: true
      column :sequence, :int, null: true
      column :number, :string, max_size: 32, null: true
      column :source_id, :reference, to_table: :invoicing_document, to_column: :id, null: true
      column :credited_id, :reference, to_table: :invoicing_document, to_column: :id, null: true
      column :locale, :string, max_size: 5, default: "fr"
      column :currency_code, :string, max_size: 3, default: "EUR"
      column :issue_date, :date, null: true
      column :delivery_date, :date, null: true
      column :due_date, :date, null: true
      column :validity_date, :date, null: true
      column :operation_category, :string, max_size: 16, default: ""
      column :vat_on_debits, :bool, default: false
      column :buyer_reference, :string, max_size: 100, default: ""
      column :order_reference, :string, max_size: 100, default: ""
      column :notes, :text, default: ""
      column :global_discount_kind, :string, max_size: 8, default: "none"
      column :global_discount_value, :decimal, max_digits: 20, decimal_places: 4, default: "0.0"
      column :delivery_address, :json, null: true
      column :seller, :json, null: true
      column :customer_snapshot, :json, null: true
      column :structured_reference, :string, max_size: 24, default: ""
      column :mentions, :json, null: true
      column :lines_total, :decimal, max_digits: 20, decimal_places: 4, default: "0.0"
      column :discount_total, :decimal, max_digits: 20, decimal_places: 4, default: "0.0"
      column :total_net, :decimal, max_digits: 20, decimal_places: 4, default: "0.0"
      column :total_vat, :decimal, max_digits: 20, decimal_places: 4, default: "0.0"
      column :total_gross, :decimal, max_digits: 20, decimal_places: 4, default: "0.0"
      column :prepaid_amount, :decimal, max_digits: 20, decimal_places: 4, default: "0.0"
      column :paid_amount, :decimal, max_digits: 20, decimal_places: 4, default: "0.0"
      column :credited_amount, :decimal, max_digits: 20, decimal_places: 4, default: "0.0"
      column :issued_at, :date_time, null: true
      column :issued_by_id, :big_int, null: true
      column :fingerprint, :string, max_size: 64, default: ""
      column :facturx_xml, :text, default: ""
      column :sent_at, :date_time, null: true
      column :created_by_id, :big_int, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
      column :customer_id, :reference, to_table: :cards_card, to_column: :id
      column :layout_id, :reference, to_table: :invoicing_layout, to_column: :id, null: true
      column :pdf_id, :reference, to_table: :core_attachment, to_column: :id, null: true
    end

    create_table :invoicing_line do
      column :id, :big_int, primary_key: true, auto: true
      column :position, :int
      column :kind, :string, max_size: 8
      column :description, :text, default: ""
      column :quantity, :decimal, max_digits: 20, decimal_places: 4, default: "0.0"
      column :unit_code, :string, max_size: 3, default: ""
      column :unit_price, :decimal, max_digits: 20, decimal_places: 4, default: "0.0"
      column :discount_kind, :string, max_size: 8, default: "none"
      column :discount_value, :decimal, max_digits: 20, decimal_places: 4, default: "0.0"
      column :discount_amount, :decimal, max_digits: 20, decimal_places: 4, default: "0.0"
      column :vat_percent, :decimal, max_digits: 7, decimal_places: 4, default: "0.0"
      column :vat_category, :string, max_size: 2, default: ""
      column :net_amount, :decimal, max_digits: 20, decimal_places: 4, default: "0.0"
      column :document_id, :reference, to_table: :invoicing_document, to_column: :id
      column :item_id, :reference, to_table: :cards_card, to_column: :id, null: true
      column :vat_rate_id, :reference, to_table: :vat_rate, to_column: :id, null: true
    end

    create_table :invoicing_deposit_deduction do
      column :id, :big_int, primary_key: true, auto: true
      column :amount, :decimal, max_digits: 20, decimal_places: 4
      column :invoice_id, :reference, to_table: :invoicing_document, to_column: :id
      column :deposit_id, :reference, to_table: :invoicing_document, to_column: :id, unique: true
    end

    create_table :invoicing_payment do
      column :id, :big_int, primary_key: true, auto: true
      column :paid_on, :date
      column :amount, :decimal, max_digits: 20, decimal_places: 4
      column :method, :string, max_size: 16, default: "transfer"
      column :reference, :string, max_size: 100, default: ""
      column :source, :string, max_size: 16, default: "manual"
      column :matching_id, :string, max_size: 64, default: ""
      column :recorded_by_id, :big_int, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
      column :document_id, :reference, to_table: :invoicing_document, to_column: :id
    end

    create_table :invoicing_reminder do
      column :id, :big_int, primary_key: true, auto: true
      column :level, :int
      column :status, :string, max_size: 16, default: "proposed"
      column :proposed_on, :date
      column :days_late, :int
      column :balance, :decimal, max_digits: 20, decimal_places: 4
      column :interest, :decimal, max_digits: 20, decimal_places: 4, default: "0.0"
      column :indemnity, :decimal, max_digits: 20, decimal_places: 4, default: "0.0"
      column :sent_at, :date_time, null: true
      column :handled_by_id, :big_int, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
      column :document_id, :reference, to_table: :invoicing_document, to_column: :id
    end

    create_table :invoicing_email_log do
      column :id, :big_int, primary_key: true, auto: true
      column :recipients, :string, max_size: 1000
      column :subject, :string, max_size: 255
      column :body, :text, default: ""
      column :attachment_name, :string, max_size: 255, default: ""
      column :attachment_sha256, :string, max_size: 64, default: ""
      column :message_id, :string, max_size: 255, default: ""
      column :status, :string, max_size: 8
      column :error, :text, default: ""
      column :sent_by_id, :big_int, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
      column :document_id, :reference, to_table: :invoicing_document, to_column: :id
      column :reminder_id, :reference, to_table: :invoicing_reminder, to_column: :id, null: true
    end

    create_table :invoicing_document_event do
      column :id, :big_int, primary_key: true, auto: true
      column :action, :string, max_size: 32
      column :user_id, :big_int, null: true
      column :fingerprint, :string, max_size: 64, default: ""
      column :details, :json, null: true
      column :created_at, :date_time
      column :document_id, :reference, to_table: :invoicing_document, to_column: :id
    end

    add_unique_constraint :invoicing_reminder, :invoicing_reminder_document_level, [:document_id, :level]

    execute(
      <<-SQL,
        ALTER TABLE invoicing_document
          ADD CONSTRAINT invoicing_document_kind_check
            CHECK (kind IN ('quote', 'order', 'delivery_note', 'invoice', 'deposit_invoice', 'credit_note')),
          ADD CONSTRAINT invoicing_document_status_check
            CHECK (status IN ('draft', 'sent', 'accepted', 'refused', 'confirmed', 'cancelled', 'issued',
                              'partially_paid', 'paid')),
          ADD CONSTRAINT invoicing_document_discount_check
            CHECK (global_discount_kind IN ('none', 'percent', 'amount') AND global_discount_value >= 0),
          ADD CONSTRAINT invoicing_document_category_check
            CHECK (operation_category IN ('', 'goods', 'services', 'mixed')),
          ADD CONSTRAINT invoicing_document_number_check
            CHECK ((number IS NULL AND sequence IS NULL AND year IS NULL AND issued_at IS NULL AND status = 'draft')
                OR (number IS NOT NULL AND sequence > 0 AND year IS NOT NULL AND issued_at IS NOT NULL
                    AND issue_date IS NOT NULL AND fingerprint <> '' AND status <> 'draft')),
          ADD CONSTRAINT invoicing_document_credit_check
            CHECK ((kind = 'credit_note') = (credited_id IS NOT NULL)),
          ADD CONSTRAINT invoicing_document_amounts_check
            CHECK (paid_amount >= 0 AND credited_amount >= 0 AND prepaid_amount >= 0)
        SQL
      <<-SQL
        ALTER TABLE invoicing_document
          DROP CONSTRAINT IF EXISTS invoicing_document_kind_check,
          DROP CONSTRAINT IF EXISTS invoicing_document_status_check,
          DROP CONSTRAINT IF EXISTS invoicing_document_discount_check,
          DROP CONSTRAINT IF EXISTS invoicing_document_category_check,
          DROP CONSTRAINT IF EXISTS invoicing_document_number_check,
          DROP CONSTRAINT IF EXISTS invoicing_document_credit_check,
          DROP CONSTRAINT IF EXISTS invoicing_document_amounts_check
        SQL
    )
    execute(
      <<-SQL,
        CREATE UNIQUE INDEX invoicing_document_series_number ON invoicing_document (series, number)
          WHERE number IS NOT NULL
        SQL
      "DROP INDEX IF EXISTS invoicing_document_series_number"
    )
    execute(
      <<-SQL,
        CREATE UNIQUE INDEX invoicing_document_series_sequence ON invoicing_document (series, year, sequence)
          WHERE number IS NOT NULL
        SQL
      "DROP INDEX IF EXISTS invoicing_document_series_sequence"
    )
    execute(
      <<-SQL,
        CREATE INDEX invoicing_document_issue ON invoicing_document (kind, issue_date)
        SQL
      "DROP INDEX IF EXISTS invoicing_document_issue"
    )
    execute(
      <<-SQL,
        ALTER TABLE invoicing_line
          ADD CONSTRAINT invoicing_line_kind_check CHECK (kind IN ('item', 'free', 'note', 'title', 'subtotal')),
          ADD CONSTRAINT invoicing_line_discount_check
            CHECK (discount_kind IN ('none', 'percent', 'amount') AND discount_value >= 0)
        SQL
      <<-SQL
        ALTER TABLE invoicing_line
          DROP CONSTRAINT IF EXISTS invoicing_line_kind_check,
          DROP CONSTRAINT IF EXISTS invoicing_line_discount_check
        SQL
    )
    execute(
      <<-SQL,
        ALTER TABLE invoicing_counter
          ADD CONSTRAINT invoicing_counter_number_check CHECK (last_number >= 0)
        SQL
      "ALTER TABLE invoicing_counter DROP CONSTRAINT IF EXISTS invoicing_counter_number_check"
    )
    execute(
      <<-SQL,
        ALTER TABLE invoicing_payment
          ADD CONSTRAINT invoicing_payment_amount_check CHECK (amount > 0),
          ADD CONSTRAINT invoicing_payment_source_check CHECK (source IN ('manual', 'matching'))
        SQL
      <<-SQL
        ALTER TABLE invoicing_payment
          DROP CONSTRAINT IF EXISTS invoicing_payment_amount_check,
          DROP CONSTRAINT IF EXISTS invoicing_payment_source_check
        SQL
    )
    execute(
      <<-SQL,
        CREATE UNIQUE INDEX invoicing_payment_matching ON invoicing_payment (document_id, matching_id)
          WHERE matching_id <> ''
        SQL
      "DROP INDEX IF EXISTS invoicing_payment_matching"
    )
    execute(
      <<-SQL,
        ALTER TABLE invoicing_reminder
          ADD CONSTRAINT invoicing_reminder_level_check CHECK (level BETWEEN 1 AND 3),
          ADD CONSTRAINT invoicing_reminder_status_check CHECK (status IN ('proposed', 'sending', 'sent', 'dismissed'))
        SQL
      <<-SQL
        ALTER TABLE invoicing_reminder
          DROP CONSTRAINT IF EXISTS invoicing_reminder_level_check,
          DROP CONSTRAINT IF EXISTS invoicing_reminder_status_check
        SQL
    )
    execute(
      <<-SQL,
        CREATE UNIQUE INDEX invoicing_settings_single ON invoicing_settings ((true))
        SQL
      "DROP INDEX IF EXISTS invoicing_settings_single"
    )
    execute(
      <<-SQL,
        CREATE UNIQUE INDEX invoicing_layout_single_default ON invoicing_layout (is_default) WHERE is_default
        SQL
      "DROP INDEX IF EXISTS invoicing_layout_single_default"
    )
    execute(
      <<-SQL,
        CREATE FUNCTION invoicing_document_guard() RETURNS trigger LANGUAGE plpgsql AS $$
        DECLARE
          mutable text[] := ARRAY['status', 'paid_amount', 'credited_amount', 'sent_at', 'updated_at', 'pdf_id'];
        BEGIN
          IF TG_OP = 'DELETE' THEN
            IF OLD.number IS NOT NULL THEN
              RAISE EXCEPTION 'invoicing: document % émis, suppression interdite', OLD.number
                USING ERRCODE = 'integrity_constraint_violation';
            END IF;
            RETURN OLD;
          END IF;
          IF OLD.number IS NOT NULL THEN
            IF (to_jsonb(NEW) - mutable) IS DISTINCT FROM (to_jsonb(OLD) - mutable) THEN
              RAISE EXCEPTION 'invoicing: document % émis, modification interdite', OLD.number
                USING ERRCODE = 'integrity_constraint_violation';
            END IF;
            IF OLD.pdf_id IS NOT NULL AND NEW.pdf_id IS DISTINCT FROM OLD.pdf_id THEN
              RAISE EXCEPTION 'invoicing: document % émis, PDF figé', OLD.number
                USING ERRCODE = 'integrity_constraint_violation';
            END IF;
          END IF;
          RETURN NEW;
        END
        $$
        SQL
      "DROP FUNCTION IF EXISTS invoicing_document_guard() CASCADE"
    )
    execute(
      <<-SQL,
        CREATE TRIGGER invoicing_document_guard BEFORE UPDATE OR DELETE ON invoicing_document
          FOR EACH ROW EXECUTE FUNCTION invoicing_document_guard()
        SQL
      "DROP TRIGGER IF EXISTS invoicing_document_guard ON invoicing_document"
    )
    execute(
      <<-SQL,
        CREATE FUNCTION invoicing_child_guard() RETURNS trigger LANGUAGE plpgsql AS $$
        DECLARE
          parent_column text := TG_ARGV[0];
          ids bigint[];
        BEGIN
          IF TG_OP IN ('UPDATE', 'DELETE') THEN
            ids := ARRAY[(to_jsonb(OLD) ->> parent_column)::bigint];
          ELSE
            ids := ARRAY[]::bigint[];
          END IF;
          IF TG_OP IN ('INSERT', 'UPDATE') THEN
            ids := ids || (to_jsonb(NEW) ->> parent_column)::bigint;
          END IF;
          IF EXISTS (SELECT 1 FROM invoicing_document WHERE id = ANY (ids) AND number IS NOT NULL) THEN
            RAISE EXCEPTION 'invoicing: % d''un document émis, modification interdite', TG_TABLE_NAME
              USING ERRCODE = 'integrity_constraint_violation';
          END IF;
          IF TG_OP = 'DELETE' THEN
            RETURN OLD;
          END IF;
          RETURN NEW;
        END
        $$
        SQL
      "DROP FUNCTION IF EXISTS invoicing_child_guard() CASCADE"
    )
    execute(
      <<-SQL,
        CREATE TRIGGER invoicing_line_guard BEFORE INSERT OR UPDATE OR DELETE ON invoicing_line
          FOR EACH ROW EXECUTE FUNCTION invoicing_child_guard('document_id')
        SQL
      "DROP TRIGGER IF EXISTS invoicing_line_guard ON invoicing_line"
    )
    execute(
      <<-SQL,
        CREATE TRIGGER invoicing_deposit_deduction_guard BEFORE INSERT OR UPDATE OR DELETE
          ON invoicing_deposit_deduction
          FOR EACH ROW EXECUTE FUNCTION invoicing_child_guard('invoice_id')
        SQL
      "DROP TRIGGER IF EXISTS invoicing_deposit_deduction_guard ON invoicing_deposit_deduction"
    )
    execute(
      <<-SQL,
        CREATE FUNCTION invoicing_counter_guard() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          IF TG_OP = 'DELETE' THEN
            RAISE EXCEPTION 'invoicing: compteur %/% non supprimable', OLD.series, OLD.year
              USING ERRCODE = 'integrity_constraint_violation';
          END IF;
          IF NEW.series <> OLD.series OR NEW.year <> OLD.year OR NEW.last_number <> OLD.last_number + 1
             OR (OLD.last_date IS NOT NULL AND (NEW.last_date IS NULL OR NEW.last_date < OLD.last_date)) THEN
            RAISE EXCEPTION 'invoicing: le compteur %/% n''avance que d''une unité', OLD.series, OLD.year
              USING ERRCODE = 'integrity_constraint_violation';
          END IF;
          RETURN NEW;
        END
        $$
        SQL
      "DROP FUNCTION IF EXISTS invoicing_counter_guard() CASCADE"
    )
    execute(
      <<-SQL,
        CREATE TRIGGER invoicing_counter_guard BEFORE UPDATE OR DELETE ON invoicing_counter
          FOR EACH ROW EXECUTE FUNCTION invoicing_counter_guard()
        SQL
      "DROP TRIGGER IF EXISTS invoicing_counter_guard ON invoicing_counter"
    )
    execute(
      <<-SQL,
        CREATE FUNCTION invoicing_append_only() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          -- Seules les traces d'un brouillon supprimé disparaissent avec lui.
          IF TG_OP = 'DELETE' AND EXISTS (SELECT 1 FROM invoicing_document
                                          WHERE id = OLD.document_id AND number IS NULL) THEN
            RETURN OLD;
          END IF;
          RAISE EXCEPTION 'invoicing: % en ajout seul', TG_TABLE_NAME USING ERRCODE = 'integrity_constraint_violation';
        END
        $$
        SQL
      "DROP FUNCTION IF EXISTS invoicing_append_only() CASCADE"
    )
    execute(
      <<-SQL,
        CREATE TRIGGER invoicing_document_event_append_only BEFORE UPDATE OR DELETE ON invoicing_document_event
          FOR EACH ROW EXECUTE FUNCTION invoicing_append_only()
        SQL
      "DROP TRIGGER IF EXISTS invoicing_document_event_append_only ON invoicing_document_event"
    )
  end
end
