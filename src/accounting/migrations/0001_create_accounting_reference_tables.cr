# SPDX-License-Identifier: AGPL-3.0-or-later

# Lot 1 — référentiel comptable : plan comptable hiérarchique (héritier de
# `tmp_pcmn`), comptes par défaut (`parm_code`), journaux (`jrn_def`),
# rattachement des fiches et catégories de fiches à un compte (attribut 5 de
# `fiche_detail`, `fiche_def.fd_class_base` et `fd_create_account`).
#
# Les fiches et catégories appartiennent au socle (`cards`), qui ne dépend pas
# du module (ADR-006 D3) : c'est la table de rattachement, côté Comptabilité,
# qui les cite, avec effacement en cascade (DECISIONS D-ACC-001).
class Migration::Accounting::V0001 < Marten::Migration
  depends_on :cards, "0001_cards"

  def plan
    create_table :accounting_account do
      column :id, :big_int, primary_key: true, auto: true
      column :number, :string, max_size: 40, unique: true
      column :label, :string, max_size: 255
      column :parent_id, :reference, to_table: :accounting_account, to_column: :id, null: true
      column :kind, :string, max_size: 20
      column :direct_use, :bool, default: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :accounting_default_account do
      column :id, :big_int, primary_key: true, auto: true
      column :code, :string, max_size: 32, unique: true
      column :account_id, :reference, to_table: :accounting_account, to_column: :id
    end

    create_table :accounting_ledger do
      column :id, :big_int, primary_key: true, auto: true
      column :code, :string, max_size: 10, unique: true
      column :name, :string, max_size: 100, unique: true
      column :kind, :string, max_size: 16
      column :description, :text, default: ""
      column :enabled, :bool, default: true
      column :default_account_id, :reference, to_table: :accounting_account, to_column: :id, null: true
      column :receipt_prefix, :string, max_size: 20, default: ""
      column :receipt_padding, :int, default: 0
      column :last_receipt_number, :big_int, default: 0
      column :currency_code, :string, max_size: 3, default: "EUR"
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :accounting_card_category_account do
      column :id, :big_int, primary_key: true, auto: true
      column :category_id, :big_int, unique: true
      column :base_account_id, :reference, to_table: :accounting_account, to_column: :id, null: true
      column :create_account, :bool, default: false
    end

    create_table :accounting_card_account do
      column :id, :big_int, primary_key: true, auto: true
      column :card_id, :big_int, unique: true
      column :account_id, :reference, to_table: :accounting_account, to_column: :id
    end

    # Intégrité du plan comptable en base (ADR-001 § PL/pgSQL) : numéro
    # normalisé (`comptaproc.format_account` : majuscules, sans espace ni
    # ponctuation), 40 caractères au plus (`account_type`), type fermé
    # (`Acc_Account::$type`), libellé non vide, pas de parent circulaire.
    execute(
      <<-SQL,
        ALTER TABLE accounting_account
          ADD CONSTRAINT accounting_account_number_check CHECK (number ~ '^[A-Z0-9]{1,40}$'),
          ADD CONSTRAINT accounting_account_label_check CHECK (btrim(label) <> ''),
          ADD CONSTRAINT accounting_account_kind_check CHECK (kind IN (
            'asset', 'liability', 'asset_contra', 'liability_contra',
            'income', 'income_contra', 'expense', 'expense_contra', 'context')),
          ADD CONSTRAINT accounting_account_parent_check CHECK (parent_id IS NULL OR parent_id <> id)
        SQL
      <<-SQL
        ALTER TABLE accounting_account
          DROP CONSTRAINT IF EXISTS accounting_account_number_check,
          DROP CONSTRAINT IF EXISTS accounting_account_label_check,
          DROP CONSTRAINT IF EXISTS accounting_account_kind_check,
          DROP CONSTRAINT IF EXISTS accounting_account_parent_check
        SQL
    )
    execute(
      <<-SQL,
        CREATE FUNCTION accounting_account_no_cycle() RETURNS trigger
        LANGUAGE plpgsql AS $$
        BEGIN
          IF NEW.parent_id IS NOT NULL AND EXISTS (
            WITH RECURSIVE ancestors(id, parent_id) AS (
              SELECT id, parent_id FROM accounting_account WHERE id = NEW.parent_id
              UNION
              SELECT a.id, a.parent_id FROM accounting_account a JOIN ancestors s ON a.id = s.parent_id
            )
            SELECT 1 FROM ancestors WHERE id = NEW.id
          ) THEN
            RAISE EXCEPTION 'accounting_account % : parent circulaire', NEW.number
              USING ERRCODE = 'check_violation';
          END IF;
          RETURN NEW;
        END;
        $$
        SQL
      "DROP FUNCTION IF EXISTS accounting_account_no_cycle()"
    )
    execute(
      <<-SQL,
        CREATE TRIGGER accounting_account_no_cycle
          BEFORE INSERT OR UPDATE OF parent_id ON accounting_account
          FOR EACH ROW EXECUTE FUNCTION accounting_account_no_cycle()
        SQL
      "DROP TRIGGER IF EXISTS accounting_account_no_cycle ON accounting_account"
    )

    # Journaux : type fermé (`jrn_type`), code court, compteur de pièces
    # positif, devise ISO 4217, compte par défaut obligatoire d'un journal
    # financier (héritier de `jrn_def_bank`).
    execute(
      <<-SQL,
        ALTER TABLE accounting_ledger
          ADD CONSTRAINT accounting_ledger_kind_check CHECK (kind IN ('purchase', 'sale', 'financial', 'misc')),
          ADD CONSTRAINT accounting_ledger_code_check CHECK (code ~ '^[A-Z0-9]{1,10}$'),
          ADD CONSTRAINT accounting_ledger_name_check CHECK (btrim(name) <> ''),
          ADD CONSTRAINT accounting_ledger_receipt_padding_check CHECK (receipt_padding BETWEEN 0 AND 20),
          ADD CONSTRAINT accounting_ledger_last_receipt_number_check CHECK (last_receipt_number >= 0),
          ADD CONSTRAINT accounting_ledger_currency_code_check CHECK (currency_code ~ '^[A-Z]{3}$'),
          ADD CONSTRAINT accounting_ledger_financial_account_check
            CHECK (kind <> 'financial' OR default_account_id IS NOT NULL)
        SQL
      <<-SQL
        ALTER TABLE accounting_ledger
          DROP CONSTRAINT IF EXISTS accounting_ledger_kind_check,
          DROP CONSTRAINT IF EXISTS accounting_ledger_code_check,
          DROP CONSTRAINT IF EXISTS accounting_ledger_name_check,
          DROP CONSTRAINT IF EXISTS accounting_ledger_receipt_padding_check,
          DROP CONSTRAINT IF EXISTS accounting_ledger_last_receipt_number_check,
          DROP CONSTRAINT IF EXISTS accounting_ledger_currency_code_check,
          DROP CONSTRAINT IF EXISTS accounting_ledger_financial_account_check
        SQL
    )
    # Fiche ou catégorie effacée au socle : son rattachement disparaît avec
    # elle (NOALYSS efface l'attribut « poste comptable » avec la fiche).
    execute(
      <<-SQL,
        ALTER TABLE accounting_card_account
          ADD CONSTRAINT accounting_card_account_card_fk
            FOREIGN KEY (card_id) REFERENCES cards_card (id) ON DELETE CASCADE
        SQL
      "ALTER TABLE accounting_card_account DROP CONSTRAINT IF EXISTS accounting_card_account_card_fk"
    )
    execute(
      <<-SQL,
        ALTER TABLE accounting_card_category_account
          ADD CONSTRAINT accounting_card_category_account_category_fk
            FOREIGN KEY (category_id) REFERENCES cards_category (id) ON DELETE CASCADE
        SQL
      "ALTER TABLE accounting_card_category_account DROP CONSTRAINT IF EXISTS accounting_card_category_account_category_fk"
    )
    execute(
      "ALTER TABLE accounting_default_account ADD CONSTRAINT accounting_default_account_code_check CHECK (code ~ '^[a-z_]{1,32}$')",
      "ALTER TABLE accounting_default_account DROP CONSTRAINT IF EXISTS accounting_default_account_code_check"
    )
  end
end
