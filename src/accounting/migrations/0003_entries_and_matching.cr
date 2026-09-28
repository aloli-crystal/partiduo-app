# SPDX-License-Identifier: AGPL-3.0-or-later

# Lot 2 — écritures (`jrn`, `jrnx`) et lettrage (`jnt_letter`, `letter_deb`,
# `letter_cred`), avec leur intégrité *en base* (ADR-001 § PL/pgSQL,
# DECISIONS D-ACC-011) :
#
# * `accounting_entry_balance` (successeur de `check_balance` et de
#   `proc_check_balance`) : déclencheur de contrainte *différé* — une
#   écriture dont le débit, le crédit et le montant d'en-tête ne concordent
#   pas au moment du `COMMIT` est refusée par PostgreSQL ;
# * `accounting_entry_period_guard` (successeur de `jrn_check_periode`,
#   `is_closed`, `find_periode`) : la période d'une écriture est calculée par
#   la base à partir de sa date ; date hors exercice, période ou exercice clos
#   → refus ;
# * `accounting_entry_line_guard` (successeur de `jrnx_ins` pour la période) :
#   aucune ligne ajoutée, modifiée ou retirée dans une période close ; le
#   lettrage (`matching_id`) reste permis.
class Migration::Accounting::V0003 < Marten::Migration
  depends_on :accounting, "0002_ledger_bank_card_and_vat_accounts"
  depends_on :core, "0003_period_guard_fiscal_year_move"
  depends_on :cards, "0001_cards"
  depends_on :vat, "0001_vat_rates"

  def plan
    create_table :accounting_matching do
      column :id, :big_int, primary_key: true, auto: true
      column :account_id, :reference, to_table: :accounting_account, to_column: :id
      column :created_by_id, :big_int, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :accounting_entry do
      column :id, :big_int, primary_key: true, auto: true
      column :ledger_id, :reference, to_table: :accounting_ledger, to_column: :id
      column :period_id, :big_int
      column :date, :date
      column :due_date, :date, null: true
      column :label, :text, default: ""
      column :receipt, :string, max_size: 40, null: true
      column :internal_code, :string, max_size: 20, null: true, unique: true
      column :amount, :decimal, max_digits: 20, decimal_places: 4
      column :currency_code, :string, max_size: 3
      column :currency_rate, :decimal, max_digits: 20, decimal_places: 8
      column :reversal_of_id, :reference, to_table: :accounting_entry, to_column: :id, null: true
      column :attachment_id, :big_int, null: true
      column :source, :string, max_size: 100, default: ""
      column :created_by_id, :big_int, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :accounting_entry_line do
      column :id, :big_int, primary_key: true, auto: true
      column :entry_id, :reference, to_table: :accounting_entry, to_column: :id
      column :position, :int, default: 0
      column :account_id, :reference, to_table: :accounting_account, to_column: :id
      column :card_id, :big_int, null: true
      column :side, :string, max_size: 6
      column :amount, :decimal, max_digits: 20, decimal_places: 4
      column :currency_amount, :decimal, max_digits: 20, decimal_places: 4, null: true
      column :label, :text, default: ""
      column :vat_rate_id, :big_int, null: true
      column :vat_role, :string, max_size: 8, null: true
      column :quantity, :decimal, max_digits: 20, decimal_places: 4, null: true
      column :matching_id, :reference, to_table: :accounting_matching, to_column: :id, null: true
    end

    # --- Contraintes de colonnes ---------------------------------------------

    execute(
      <<-SQL,
        ALTER TABLE accounting_entry
          ADD CONSTRAINT accounting_entry_amount_check CHECK (amount > 0),
          ADD CONSTRAINT accounting_entry_currency_code_check CHECK (currency_code ~ '^[A-Z]{3}$'),
          ADD CONSTRAINT accounting_entry_currency_rate_check CHECK (currency_rate > 0),
          ADD CONSTRAINT accounting_entry_receipt_check CHECK (receipt IS NULL OR btrim(receipt) <> ''),
          ADD CONSTRAINT accounting_entry_reversal_check CHECK (reversal_of_id IS NULL OR reversal_of_id <> id),
          ADD CONSTRAINT accounting_entry_period_fk FOREIGN KEY (period_id) REFERENCES core_period (id),
          ADD CONSTRAINT accounting_entry_attachment_fk FOREIGN KEY (attachment_id) REFERENCES core_attachment (id)
        SQL
      <<-SQL
        ALTER TABLE accounting_entry
          DROP CONSTRAINT IF EXISTS accounting_entry_amount_check,
          DROP CONSTRAINT IF EXISTS accounting_entry_currency_code_check,
          DROP CONSTRAINT IF EXISTS accounting_entry_currency_rate_check,
          DROP CONSTRAINT IF EXISTS accounting_entry_receipt_check,
          DROP CONSTRAINT IF EXISTS accounting_entry_reversal_check,
          DROP CONSTRAINT IF EXISTS accounting_entry_period_fk,
          DROP CONSTRAINT IF EXISTS accounting_entry_attachment_fk
        SQL
    )
    # Une pièce ne sert qu'une fois par journal (`Acc_Operation::update_receipt`).
    execute(
      "CREATE UNIQUE INDEX accounting_entry_ledger_receipt ON accounting_entry (ledger_id, receipt) WHERE receipt IS NOT NULL",
      "DROP INDEX IF EXISTS accounting_entry_ledger_receipt"
    )
    # Une écriture n'est extournée qu'une fois.
    execute(
      "CREATE UNIQUE INDEX accounting_entry_reversal_of ON accounting_entry (reversal_of_id) WHERE reversal_of_id IS NOT NULL",
      "DROP INDEX IF EXISTS accounting_entry_reversal_of"
    )
    execute(
      "CREATE INDEX accounting_entry_date ON accounting_entry (date, id)",
      "DROP INDEX IF EXISTS accounting_entry_date"
    )
    execute(
      <<-SQL,
        ALTER TABLE accounting_entry_line
          ADD CONSTRAINT accounting_entry_line_side_check CHECK (side IN ('debit', 'credit')),
          ADD CONSTRAINT accounting_entry_line_amount_check CHECK (amount >= 0),
          ADD CONSTRAINT accounting_entry_line_vat_role_check CHECK (vat_role IS NULL OR vat_role IN ('base', 'tax')),
          ADD CONSTRAINT accounting_entry_line_card_fk FOREIGN KEY (card_id) REFERENCES cards_card (id),
          ADD CONSTRAINT accounting_entry_line_vat_rate_fk FOREIGN KEY (vat_rate_id) REFERENCES vat_rate (id)
        SQL
      <<-SQL
        ALTER TABLE accounting_entry_line
          DROP CONSTRAINT IF EXISTS accounting_entry_line_side_check,
          DROP CONSTRAINT IF EXISTS accounting_entry_line_amount_check,
          DROP CONSTRAINT IF EXISTS accounting_entry_line_vat_role_check,
          DROP CONSTRAINT IF EXISTS accounting_entry_line_card_fk,
          DROP CONSTRAINT IF EXISTS accounting_entry_line_vat_rate_fk
        SQL
    )
    execute(
      "CREATE INDEX accounting_entry_line_account ON accounting_entry_line (account_id, entry_id)",
      "DROP INDEX IF EXISTS accounting_entry_line_account"
    )
    execute(
      "CREATE INDEX accounting_entry_line_card ON accounting_entry_line (card_id) WHERE card_id IS NOT NULL",
      "DROP INDEX IF EXISTS accounting_entry_line_card"
    )

    # --- Période d'une écriture (jrn_check_periode, is_closed) ---------------

    execute(
      <<-SQL,
        CREATE FUNCTION accounting_period_closed(p_period_id bigint) RETURNS boolean
        LANGUAGE sql STABLE AS $$
          SELECT p.closed_at IS NOT NULL OR y.closed_at IS NOT NULL
          FROM core_period p JOIN core_fiscal_year y ON y.id = p.fiscal_year_id
          WHERE p.id = p_period_id
        $$
        SQL
      "DROP FUNCTION IF EXISTS accounting_period_closed(bigint)"
    )
    execute(
      <<-SQL,
        CREATE FUNCTION accounting_entry_period_guard() RETURNS trigger
        LANGUAGE plpgsql AS $$
        BEGIN
          IF TG_OP = 'DELETE' THEN
            IF accounting_period_closed(OLD.period_id) THEN
              RAISE EXCEPTION 'accounting_entry % : période close', OLD.id USING ERRCODE = 'check_violation';
            END IF;
            RETURN OLD;
          END IF;

          IF TG_OP = 'UPDATE' AND NEW.date = OLD.date AND NEW.ledger_id = OLD.ledger_id
             AND NEW.amount = OLD.amount AND NEW.currency_code = OLD.currency_code
             AND NEW.currency_rate = OLD.currency_rate THEN
            -- Libellé, pièce, échéance, pièce jointe : permis même en période
            -- close (règle d'origine : la date inchangée n'est pas contrôlée).
            NEW.period_id := OLD.period_id;
            RETURN NEW;
          END IF;

          IF TG_OP = 'UPDATE' AND accounting_period_closed(OLD.period_id) THEN
            RAISE EXCEPTION 'accounting_entry % : période close', OLD.id USING ERRCODE = 'check_violation';
          END IF;

          NEW.period_id := core_period_for(NEW.date);
          IF NEW.period_id IS NULL THEN
            RAISE EXCEPTION 'accounting_entry : date % hors exercice', NEW.date USING ERRCODE = 'check_violation';
          END IF;
          IF accounting_period_closed(NEW.period_id) THEN
            RAISE EXCEPTION 'accounting_entry : période close au %', NEW.date USING ERRCODE = 'check_violation';
          END IF;
          RETURN NEW;
        END;
        $$
        SQL
      "DROP FUNCTION IF EXISTS accounting_entry_period_guard() CASCADE"
    )
    execute(
      <<-SQL,
        CREATE TRIGGER accounting_entry_period_guard
          BEFORE INSERT OR UPDATE OR DELETE ON accounting_entry
          FOR EACH ROW EXECUTE FUNCTION accounting_entry_period_guard()
        SQL
      "DROP TRIGGER IF EXISTS accounting_entry_period_guard ON accounting_entry"
    )
    execute(
      <<-SQL,
        CREATE FUNCTION accounting_entry_line_guard() RETURNS trigger
        LANGUAGE plpgsql AS $$
        DECLARE
          v_period bigint;
        BEGIN
          IF TG_OP IN ('UPDATE', 'DELETE') THEN
            SELECT period_id INTO v_period FROM accounting_entry WHERE id = OLD.entry_id;
            IF FOUND AND accounting_period_closed(v_period) THEN
              RAISE EXCEPTION 'accounting_entry_line % : période close', OLD.id USING ERRCODE = 'check_violation';
            END IF;
          END IF;
          IF TG_OP IN ('INSERT', 'UPDATE') THEN
            SELECT period_id INTO v_period FROM accounting_entry WHERE id = NEW.entry_id;
            IF FOUND AND accounting_period_closed(v_period) THEN
              RAISE EXCEPTION 'accounting_entry_line : période close (écriture %)', NEW.entry_id
                USING ERRCODE = 'check_violation';
            END IF;
            RETURN NEW;
          END IF;
          RETURN OLD;
        END;
        $$
        SQL
      "DROP FUNCTION IF EXISTS accounting_entry_line_guard() CASCADE"
    )
    execute(
      <<-SQL,
        CREATE TRIGGER accounting_entry_line_guard
          BEFORE INSERT OR DELETE OR UPDATE OF entry_id, account_id, card_id, side, amount, currency_amount
          ON accounting_entry_line
          FOR EACH ROW EXECUTE FUNCTION accounting_entry_line_guard()
        SQL
      "DROP TRIGGER IF EXISTS accounting_entry_line_guard ON accounting_entry_line"
    )

    # --- Équilibre (check_balance, proc_check_balance) -----------------------

    # 0 si l'écriture est équilibrée et que son montant d'en-tête vaut son
    # débit ; sinon l'écart débit − crédit (positif), ou l'écart d'en-tête
    # (négatif), comme `comptaproc.check_balance`. Une écriture sans ligne
    # n'est pas équilibrée : son montant d'en-tête est strictement positif.
    execute(
      <<-SQL,
        CREATE FUNCTION accounting_entry_check_balance(p_entry_id bigint) RETURNS numeric
        LANGUAGE plpgsql STABLE AS $$
        DECLARE
          v_debit numeric;
          v_credit numeric;
          v_amount numeric;
        BEGIN
          SELECT coalesce(sum(amount) FILTER (WHERE side = 'debit'), 0),
                 coalesce(sum(amount) FILTER (WHERE side = 'credit'), 0)
            INTO v_debit, v_credit
            FROM accounting_entry_line WHERE entry_id = p_entry_id;
          SELECT amount INTO v_amount FROM accounting_entry WHERE id = p_entry_id;
          IF NOT FOUND THEN
            RETURN 0;
          END IF;
          IF v_debit <> v_credit THEN
            RETURN abs(v_debit - v_credit);
          END IF;
          IF v_amount <> v_debit THEN
            RETURN -1 * abs(v_amount - v_debit);
          END IF;
          RETURN 0;
        END;
        $$
        SQL
      "DROP FUNCTION IF EXISTS accounting_entry_check_balance(bigint)"
    )
    execute(
      <<-SQL,
        CREATE FUNCTION accounting_entry_balance() RETURNS trigger
        LANGUAGE plpgsql AS $$
        DECLARE
          v_ids bigint[];
          v_id bigint;
          v_diff numeric;
        BEGIN
          IF TG_TABLE_NAME = 'accounting_entry' THEN
            v_ids := ARRAY[NEW.id];
          ELSIF TG_OP = 'INSERT' THEN
            v_ids := ARRAY[NEW.entry_id];
          ELSIF TG_OP = 'DELETE' THEN
            v_ids := ARRAY[OLD.entry_id];
          ELSE
            v_ids := ARRAY[OLD.entry_id, NEW.entry_id];
          END IF;
          FOREACH v_id IN ARRAY v_ids LOOP
            v_diff := accounting_entry_check_balance(v_id);
            IF v_diff <> 0 THEN
              RAISE EXCEPTION 'accounting_entry % : écriture déséquilibrée (écart %)', v_id, v_diff
                USING ERRCODE = 'check_violation';
            END IF;
          END LOOP;
          RETURN NULL;
        END;
        $$
        SQL
      "DROP FUNCTION IF EXISTS accounting_entry_balance() CASCADE"
    )
    execute(
      <<-SQL,
        CREATE CONSTRAINT TRIGGER accounting_entry_balance
          AFTER INSERT OR UPDATE OF amount ON accounting_entry
          DEFERRABLE INITIALLY DEFERRED
          FOR EACH ROW EXECUTE FUNCTION accounting_entry_balance()
        SQL
      "DROP TRIGGER IF EXISTS accounting_entry_balance ON accounting_entry"
    )
    execute(
      <<-SQL,
        CREATE CONSTRAINT TRIGGER accounting_entry_line_balance
          AFTER INSERT OR DELETE OR UPDATE OF entry_id, side, amount ON accounting_entry_line
          DEFERRABLE INITIALLY DEFERRED
          FOR EACH ROW EXECUTE FUNCTION accounting_entry_balance()
        SQL
      "DROP TRIGGER IF EXISTS accounting_entry_line_balance ON accounting_entry_line"
    )
  end
end
