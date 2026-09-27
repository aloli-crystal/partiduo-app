# SPDX-License-Identifier: AGPL-3.0-or-later

# Module micro-entreprise (ADR-007 D1) : paramètres, natures, livre des
# recettes, registre des achats, compteurs, paramètres datés (taux URSSAF,
# seuils, cases de la 2042-C-PRO), déclarations URSSAF faites, nature des
# articles, factures émises relevées.
#
# Intégrité en base :
#
# * registres *intangibles* : une ligne ne se modifie ni ne s'efface
#   (déclencheur `micro_register_guard`), la correction est une
#   contre-passation ; aucune ligne n'entre dans une période close du socle
#   (`core_period`) ;
# * montant non nul, positif sauf pour une contre-passation (négative), une
#   seule contre-passation par ligne ; TVA comprise (recette : collectée,
#   achat : déductible) de même signe et inférieure au montant ;
# * valeurs fermées (sens et catégorie des natures, modes de règlement,
#   origine, périodicité) ;
# * une référence d'origine (`source`) n'est inscrite qu'une fois par nature.
class Migration::Micro::V0001 < Marten::Migration
  depends_on :core, "0003_period_guard_fiscal_year_move"
  depends_on :cards, "0001_cards"

  METHODS = "('transfer', 'card', 'cheque', 'cash', 'direct_debit', 'other')"

  CONSTRAINTS = [
    {"ALTER TABLE micro_settings ADD CONSTRAINT micro_settings_periodicity_check " \
     "CHECK (periodicity IN ('monthly', 'quarterly'))", "SELECT 1"},
    {"ALTER TABLE micro_nature ADD CONSTRAINT micro_nature_kind_check CHECK (" \
     "(kind = 'receipt' AND category IN ('sale_bic', 'service_bic', 'bnc')) OR " \
     "(kind = 'purchase' AND category IN ('goods', 'other')))", "SELECT 1"},
    {<<-SQL, "SELECT 1"},
      ALTER TABLE micro_receipt
        ADD CONSTRAINT micro_receipt_amount_check CHECK (
          amount <> 0 AND (reversal_of_id IS NULL) = (amount > 0)
          AND (vat_amount = 0 OR sign(vat_amount) = sign(amount)) AND abs(vat_amount) < abs(amount)),
        ADD CONSTRAINT micro_receipt_values_check CHECK (
          category IN ('sale_bic', 'service_bic', 'bnc') AND origin IN ('manual', 'invoicing')
          AND method IN #{METHODS}),
        ADD CONSTRAINT micro_receipt_nature_fk FOREIGN KEY (nature_id) REFERENCES micro_nature (id),
        ADD CONSTRAINT micro_receipt_reversal_fk FOREIGN KEY (reversal_of_id) REFERENCES micro_receipt (id),
        ADD CONSTRAINT micro_receipt_card_fk FOREIGN KEY (card_id) REFERENCES cards_card (id)
          DEFERRABLE INITIALLY DEFERRED
      SQL
    {<<-SQL, "SELECT 1"},
      ALTER TABLE micro_purchase
        ADD CONSTRAINT micro_purchase_amount_check CHECK (
          amount <> 0 AND (reversal_of_id IS NULL) = (amount > 0)
          AND (vat_amount = 0 OR sign(vat_amount) = sign(amount)) AND abs(vat_amount) < abs(amount)),
        ADD CONSTRAINT micro_purchase_values_check CHECK (
          category IN ('goods', 'other') AND method IN #{METHODS}),
        ADD CONSTRAINT micro_purchase_nature_fk FOREIGN KEY (nature_id) REFERENCES micro_nature (id),
        ADD CONSTRAINT micro_purchase_reversal_fk FOREIGN KEY (reversal_of_id) REFERENCES micro_purchase (id),
        ADD CONSTRAINT micro_purchase_card_fk FOREIGN KEY (card_id) REFERENCES cards_card (id)
          DEFERRABLE INITIALLY DEFERRED
      SQL
    {"CREATE UNIQUE INDEX micro_receipt_reversal ON micro_receipt (reversal_of_id) WHERE reversal_of_id IS NOT NULL",
     "DROP INDEX IF EXISTS micro_receipt_reversal"},
    {"CREATE UNIQUE INDEX micro_purchase_reversal ON micro_purchase (reversal_of_id) WHERE reversal_of_id IS NOT NULL",
     "DROP INDEX IF EXISTS micro_purchase_reversal"},
    {"CREATE UNIQUE INDEX micro_receipt_source ON micro_receipt (source, nature_id) " \
     "WHERE source <> '' AND reversal_of_id IS NULL", "DROP INDEX IF EXISTS micro_receipt_source"},
    {"CREATE INDEX micro_receipt_date ON micro_receipt (date, number)", "DROP INDEX IF EXISTS micro_receipt_date"},
    {"CREATE INDEX micro_purchase_date ON micro_purchase (date, number)", "DROP INDEX IF EXISTS micro_purchase_date"},
    {"ALTER TABLE micro_counter ADD CONSTRAINT micro_counter_checks CHECK (register IN ('receipt', 'purchase') " \
     "AND next_number >= 1)", "SELECT 1"},
    {"ALTER TABLE micro_item_nature ADD CONSTRAINT micro_item_nature_nature_fk FOREIGN KEY (nature_id) " \
     "REFERENCES micro_nature (id)", "SELECT 1"},
    {<<-SQL, "DROP FUNCTION IF EXISTS micro_register_guard() CASCADE"},
      CREATE FUNCTION micro_register_guard() RETURNS trigger LANGUAGE plpgsql AS $$
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
    {"CREATE TRIGGER micro_receipt_guard BEFORE INSERT OR UPDATE OR DELETE ON micro_receipt " \
     "FOR EACH ROW EXECUTE FUNCTION micro_register_guard()", "DROP TRIGGER IF EXISTS micro_receipt_guard ON micro_receipt"},
    {"CREATE TRIGGER micro_purchase_guard BEFORE INSERT OR UPDATE OR DELETE ON micro_purchase " \
     "FOR EACH ROW EXECUTE FUNCTION micro_register_guard()", "DROP TRIGGER IF EXISTS micro_purchase_guard ON micro_purchase"},
  ]

  def plan
    create_table :micro_settings do
      column :id, :big_int, primary_key: true, auto: true
      column :periodicity, :string, max_size: 10, default: "quarterly"
      column :flat_tax, :bool, default: false
      column :activity_started_on, :date, null: true
      column :default_nature_id, :big_int, null: true
      column :vat_liable_since, :date, null: true
      column :real_regime_since, :date, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :micro_nature do
      column :id, :big_int, primary_key: true, auto: true
      column :code, :string, max_size: 24, unique: true
      column :label, :string, max_size: 100
      column :kind, :string, max_size: 10
      column :category, :string, max_size: 12
      column :enabled, :bool, default: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :micro_receipt do
      column :id, :big_int, primary_key: true, auto: true
      column :number, :string, max_size: 20, unique: true
      column :date, :date
      column :nature_id, :big_int
      column :category, :string, max_size: 12
      column :amount, :decimal, max_digits: 20, decimal_places: 4
      column :vat_amount, :decimal, max_digits: 20, decimal_places: 4, default: "0.0"
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

    create_table :micro_purchase do
      column :id, :big_int, primary_key: true, auto: true
      column :number, :string, max_size: 20, unique: true
      column :date, :date
      column :nature_id, :big_int
      column :category, :string, max_size: 12
      column :amount, :decimal, max_digits: 20, decimal_places: 4
      column :vat_amount, :decimal, max_digits: 20, decimal_places: 4, default: "0.0"
      column :method, :string, max_size: 16
      column :card_id, :big_int, null: true
      column :party_name, :string, max_size: 255, default: ""
      column :label, :string, max_size: 255, default: ""
      column :reference, :string, max_size: 100, default: ""
      column :attachment_id, :big_int, null: true
      column :reversal_of_id, :big_int, null: true
      column :recorded_by_id, :big_int, null: true
      column :recorded_at, :date_time
    end

    create_table :micro_counter do
      column :id, :big_int, primary_key: true, auto: true
      column :register, :string, max_size: 10
      column :year, :int
      column :next_number, :int, default: 1
    end

    create_table :micro_parameter do
      column :id, :big_int, primary_key: true, auto: true
      column :code, :string, max_size: 60
      column :valid_from, :date
      column :value, :decimal, max_digits: 20, decimal_places: 6, null: true
      column :text, :string, max_size: 60, default: ""
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :micro_declaration do
      column :id, :big_int, primary_key: true, auto: true
      column :starts_on, :date, unique: true
      column :ends_on, :date
      column :declared_on, :date
      column :reference, :string, max_size: 100, default: ""
      column :declared_by_id, :big_int, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :micro_item_nature do
      column :id, :big_int, primary_key: true, auto: true
      column :item_card_id, :big_int, unique: true
      column :nature_id, :big_int
    end

    create_table :micro_invoice do
      column :id, :big_int, primary_key: true, auto: true
      column :invoice_id, :big_int, unique: true
      column :number, :string, max_size: 40, default: ""
      column :card_id, :big_int, null: true
      column :issue_date, :date, null: true
      column :total_vat, :decimal, max_digits: 20, decimal_places: 4
      column :total_gross, :decimal, max_digits: 20, decimal_places: 4
      column :shares, :text, default: "[]"
      column :vats, :text, default: "[]"
    end

    add_unique_constraint :micro_counter, :micro_counter_unique, [:register, :year]
    add_unique_constraint :micro_parameter, :micro_parameter_unique, [:code, :valid_from]

    CONSTRAINTS.each { |(forward, backward)| execute(forward, backward) }
  end
end
