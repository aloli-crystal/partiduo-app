# SPDX-License-Identifier: AGPL-3.0-or-later

# Factures d'achat reçues (ADR-004 D9) : numéro, date et montant de la
# facture du fournisseur derrière une écriture d'achat, et leur origine —
# `off_platform` (papier ou PDF simple saisi à la main, pièce jointe à
# l'écriture) ou `platform` (reçue par la plateforme agréée). Une écriture
# porte une facture au plus ; la ligne ne se modifie ni ne se supprime. Index
# du contrôle de doublon (fournisseur, numéro normalisé). DECISIONS D-ACC-018.
class Migration::Accounting::V0009 < Marten::Migration
  depends_on :accounting, "0008_bank_reconciliation"
  depends_on :cards, "0001_cards"

  def plan
    create_table :accounting_received_invoice do
      column :id, :big_int, primary_key: true, auto: true
      column :entry_id, :reference, to_table: :accounting_entry, to_column: :id, unique: true
      column :supplier_card_id, :big_int
      column :number, :string, max_size: 100
      column :number_key, :string, max_size: 100
      column :invoice_date, :date
      column :total_amount, :decimal, max_digits: 20, decimal_places: 4
      column :currency_code, :string, max_size: 3
      column :origin, :string, max_size: 16
      column :platform_reference, :string, max_size: 100, default: ""
      column :created_by_id, :big_int, null: true
      column :created_at, :date_time
    end

    execute(
      "ALTER TABLE accounting_received_invoice ADD CONSTRAINT accounting_received_invoice_supplier_fk " \
      "FOREIGN KEY (supplier_card_id) REFERENCES cards_card (id)",
      "ALTER TABLE accounting_received_invoice DROP CONSTRAINT IF EXISTS accounting_received_invoice_supplier_fk"
    )
    execute(
      "ALTER TABLE accounting_received_invoice ADD CONSTRAINT accounting_received_invoice_checks " \
      "CHECK (origin IN ('off_platform', 'platform') AND btrim(number) <> '' AND number_key <> '')",
      "ALTER TABLE accounting_received_invoice DROP CONSTRAINT IF EXISTS accounting_received_invoice_checks"
    )
    execute(
      "CREATE INDEX accounting_received_invoice_duplicate ON accounting_received_invoice (supplier_card_id, number_key)",
      "DROP INDEX IF EXISTS accounting_received_invoice_duplicate"
    )
    execute(
      <<-SQL,
        CREATE FUNCTION accounting_received_invoice_guard() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          RAISE EXCEPTION 'accounting: facture reçue %, ni modification ni suppression', OLD.number
            USING ERRCODE = 'integrity_constraint_violation';
        END
        $$
        SQL
      "DROP FUNCTION IF EXISTS accounting_received_invoice_guard() CASCADE"
    )
    execute(
      <<-SQL,
        CREATE TRIGGER accounting_received_invoice_guard BEFORE UPDATE OR DELETE ON accounting_received_invoice
          FOR EACH ROW EXECUTE FUNCTION accounting_received_invoice_guard()
        SQL
      "DROP TRIGGER IF EXISTS accounting_received_invoice_guard ON accounting_received_invoice"
    )
  end
end
