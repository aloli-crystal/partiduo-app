# SPDX-License-Identifier: AGPL-3.0-or-later

# Retours de marchandises et paiements rejetés (DECISIONS D-INV3-001 et
# suivantes).
#
# * nature `return_note` (bon de retour), motif du retour
#   (`invoicing_document.return_reason`) ;
# * `invoicing_line.return_note_id` : bon de retour dont la ligne d'une
#   facture (déduction, quantités négatives) ou d'un avoir est issue ;
# * `invoicing_billed_return` : bon de retour repris par une facture ou un
#   avoir, brouillon ou émis — un bon ne l'est qu'une fois (index unique),
#   lignes figées avec le document émis (`invoicing_child_guard`) ;
# * `invoicing_payment_rejection` : rejet d'un règlement (chèque impayé,
#   prélèvement rejeté, virement retourné), en ajout seul ; le règlement
#   rejeté reste, la trace le désigne ;
# * `invoicing_reminder.payment_rejection_id` : relance proposée à la suite
#   d'un rejet.
class Migration::Invoicing::V0007 < Marten::Migration
  depends_on :invoicing, "0006_delivery_billing"

  def plan
    add_column :invoicing_document, :return_reason, :string, max_size: 16, default: ""
    add_column :invoicing_line, :return_note_id, :big_int, null: true
    add_column :invoicing_reminder, :payment_rejection_id, :big_int, null: true

    create_table :invoicing_billed_return do
      column :id, :big_int, primary_key: true, auto: true
      column :document_id, :reference, to_table: :invoicing_document, to_column: :id
      column :return_note_id, :reference, to_table: :invoicing_document, to_column: :id, unique: true
    end

    create_table :invoicing_payment_rejection do
      column :id, :big_int, primary_key: true, auto: true
      column :payment_id, :reference, to_table: :invoicing_payment, to_column: :id, unique: true
      column :document_id, :reference, to_table: :invoicing_document, to_column: :id
      column :rejected_on, :date
      column :reason, :string, max_size: 24
      column :reason_text, :text, default: ""
      column :amount, :decimal, max_digits: 20, decimal_places: 4
      column :fees, :decimal, max_digits: 20, decimal_places: 4, default: 0
      column :fees_rebilled, :bool, default: false
      # Brouillon de facture des frais et relance proposée : identifiants nus
      # (un brouillon supprimé, une relance écartée laissent la trace).
      column :fees_invoice_id, :big_int, null: true
      column :reminder_id, :big_int, null: true
      column :recorded_by_id, :big_int, null: true
      column :created_at, :date_time
    end

    execute(
      "ALTER TABLE invoicing_document DROP CONSTRAINT invoicing_document_kind_check, " \
      "ADD CONSTRAINT invoicing_document_kind_check " \
      "CHECK (kind IN ('quote', 'order', 'delivery_note', 'invoice', 'deposit_invoice', 'credit_note', 'return_note'))",
      "ALTER TABLE invoicing_document DROP CONSTRAINT invoicing_document_kind_check, " \
      "ADD CONSTRAINT invoicing_document_kind_check " \
      "CHECK (kind IN ('quote', 'order', 'delivery_note', 'invoice', 'deposit_invoice', 'credit_note'))"
    )
    execute(
      "ALTER TABLE invoicing_document ADD CONSTRAINT invoicing_document_return_reason_check " \
      "CHECK (return_reason IN ('', 'damaged', 'defective', 'wrong_item', 'excess', 'other') " \
      "AND (return_reason = '' OR kind = 'return_note'))",
      "ALTER TABLE invoicing_document DROP CONSTRAINT IF EXISTS invoicing_document_return_reason_check"
    )
    execute(
      "ALTER TABLE invoicing_line ADD CONSTRAINT invoicing_line_return_note_fk " \
      "FOREIGN KEY (return_note_id) REFERENCES invoicing_document (id)",
      "ALTER TABLE invoicing_line DROP CONSTRAINT IF EXISTS invoicing_line_return_note_fk"
    )
    execute(
      "ALTER TABLE invoicing_payment_rejection " \
      "ADD CONSTRAINT invoicing_payment_rejection_reason_check CHECK (reason IN " \
      "('insufficient_funds', 'account_closed', 'stopped', 'disputed', 'invalid_details', 'other')), " \
      "ADD CONSTRAINT invoicing_payment_rejection_amounts_check CHECK (amount > 0 AND fees >= 0)",
      "SELECT 1"
    )
    execute(
      "CREATE INDEX invoicing_billed_return_document ON invoicing_billed_return (document_id)",
      "DROP INDEX IF EXISTS invoicing_billed_return_document"
    )
    execute(
      "CREATE INDEX invoicing_payment_rejection_document ON invoicing_payment_rejection (document_id)",
      "DROP INDEX IF EXISTS invoicing_payment_rejection_document"
    )
    execute(
      "CREATE INDEX invoicing_document_returns ON invoicing_document (customer_id, delivery_date) " \
      "WHERE kind = 'return_note' AND status = 'issued'",
      "DROP INDEX IF EXISTS invoicing_document_returns"
    )
    # Lignes d'un document émis figées (même garde que les lignes).
    execute(
      <<-SQL,
        CREATE TRIGGER invoicing_billed_return_guard BEFORE INSERT OR UPDATE OR DELETE
          ON invoicing_billed_return
          FOR EACH ROW EXECUTE FUNCTION invoicing_child_guard('document_id')
        SQL
      "DROP TRIGGER IF EXISTS invoicing_billed_return_guard ON invoicing_billed_return"
    )
    # Rejet en ajout seul : la facture rejetée est émise, la trace demeure.
    execute(
      <<-SQL,
        CREATE TRIGGER invoicing_payment_rejection_append_only BEFORE UPDATE OR DELETE
          ON invoicing_payment_rejection
          FOR EACH ROW EXECUTE FUNCTION invoicing_append_only()
        SQL
      "DROP TRIGGER IF EXISTS invoicing_payment_rejection_append_only ON invoicing_payment_rejection"
    )
  end
end
