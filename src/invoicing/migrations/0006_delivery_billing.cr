# SPDX-License-Identifier: AGPL-3.0-or-later

# Facture récapitulative et facturation mensuelle des bons de livraison
# (art. 289-I-3 du CGI), encours maximum par client. DECISIONS D-INV2-001 et
# suivantes.
#
# * `invoicing_line.delivery_note_id` : bon de livraison dont la ligne d'une
#   facture est issue (groupe de lignes d'une facture récapitulative) ;
# * `invoicing_document.billing_period_start` / `billing_period_end` :
#   période de facturation (BG-14) d'une facture qui regroupe plusieurs
#   livraisons ; figées à l'émission par le déclencheur d'intangibilité (qui
#   compare le document entier) ;
# * `invoicing_billed_delivery` : bon de livraison facturé par une facture
#   (brouillon ou émise) — un bon ne l'est qu'une fois (index unique), les
#   lignes sont figées avec la facture émise (`invoicing_child_guard`) ;
#   reprise des factures déjà tirées d'un bon (`source_id`) ;
# * état `invoiced` d'un bon de livraison dont la facture est émise ;
# * `invoicing_customer` : réglage client de la Facturation (rythme de
#   facturation, encours maximum), accessoire de la fiche du socle ;
# * `invoicing_settings.monthly_billing_mode` : préparer et proposer, ou
#   émettre et envoyer ;
# * `invoicing_monthly_invoice` et `invoicing_month_close` : fin de mois
#   idempotente (une facture par client, mois et devise ; un passage par
#   mois) ;
# * permission `invoicing.credit_limit.override` accordée aux profils
#   ACCOUNTANT existants.
class Migration::Invoicing::V0006 < Marten::Migration
  depends_on :invoicing, "0005_payment_terms"
  depends_on :auth, "0002_auth_security"

  def plan
    add_column :invoicing_line, :delivery_note_id, :big_int, null: true
    add_column :invoicing_document, :billing_period_start, :date, null: true
    add_column :invoicing_document, :billing_period_end, :date, null: true
    add_column :invoicing_settings, :monthly_billing_mode, :string, max_size: 16, default: "propose"

    create_table :invoicing_billed_delivery do
      column :id, :big_int, primary_key: true, auto: true
      column :invoice_id, :reference, to_table: :invoicing_document, to_column: :id
      column :delivery_note_id, :reference, to_table: :invoicing_document, to_column: :id, unique: true
    end

    create_table :invoicing_customer do
      column :id, :big_int, primary_key: true, auto: true
      column :card_id, :big_int, unique: true
      column :billing_rhythm, :string, max_size: 16, default: "per_delivery"
      column :credit_limit, :decimal, max_digits: 20, decimal_places: 4, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :invoicing_monthly_invoice do
      column :id, :big_int, primary_key: true, auto: true
      column :month, :date
      column :customer_id, :big_int
      column :currency_code, :string, max_size: 3
      # Facture préparée ; nue (sans clé étrangère) : un brouillon supprimé
      # laisse la trace, et le mois n'est pas repris pour ce client.
      column :invoice_id, :big_int, null: true
      column :mode, :string, max_size: 16
      column :status, :string, max_size: 16, default: "proposed"
      column :error, :text, default: ""
      column :created_by_id, :big_int, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :invoicing_month_close do
      column :id, :big_int, primary_key: true, auto: true
      column :month, :date, unique: true
      column :trigger, :string, max_size: 16
      column :prepared, :int, default: 0
      column :created_at, :date_time
    end

    add_unique_constraint :invoicing_monthly_invoice, :invoicing_monthly_invoice_once,
      [:month, :customer_id, :currency_code]

    execute(
      "ALTER TABLE invoicing_line ADD CONSTRAINT invoicing_line_delivery_note_fk " \
      "FOREIGN KEY (delivery_note_id) REFERENCES invoicing_document (id)",
      "ALTER TABLE invoicing_line DROP CONSTRAINT IF EXISTS invoicing_line_delivery_note_fk"
    )
    execute(
      "ALTER TABLE invoicing_document ADD CONSTRAINT invoicing_document_billing_period_check " \
      "CHECK ((billing_period_start IS NULL) = (billing_period_end IS NULL) " \
      "AND (billing_period_start IS NULL OR billing_period_start <= billing_period_end))",
      "ALTER TABLE invoicing_document DROP CONSTRAINT IF EXISTS invoicing_document_billing_period_check"
    )
    execute(
      "ALTER TABLE invoicing_document DROP CONSTRAINT invoicing_document_status_check, " \
      "ADD CONSTRAINT invoicing_document_status_check " \
      "CHECK (status IN ('draft', 'sent', 'accepted', 'refused', 'confirmed', 'cancelled', 'issued', " \
      "'partially_paid', 'paid', 'invoiced'))",
      "ALTER TABLE invoicing_document DROP CONSTRAINT invoicing_document_status_check, " \
      "ADD CONSTRAINT invoicing_document_status_check " \
      "CHECK (status IN ('draft', 'sent', 'accepted', 'refused', 'confirmed', 'cancelled', 'issued', " \
      "'partially_paid', 'paid'))"
    )
    execute(
      "ALTER TABLE invoicing_settings ADD CONSTRAINT invoicing_settings_monthly_mode_check " \
      "CHECK (monthly_billing_mode IN ('propose', 'auto_send'))",
      "ALTER TABLE invoicing_settings DROP CONSTRAINT IF EXISTS invoicing_settings_monthly_mode_check"
    )
    execute(
      "ALTER TABLE invoicing_customer " \
      "ADD CONSTRAINT invoicing_customer_card_fk FOREIGN KEY (card_id) REFERENCES cards_card (id) " \
      "ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED, " \
      "ADD CONSTRAINT invoicing_customer_rhythm_check CHECK (billing_rhythm IN ('per_delivery', 'monthly')), " \
      "ADD CONSTRAINT invoicing_customer_credit_limit_check CHECK (credit_limit IS NULL OR credit_limit >= 0)",
      "SELECT 1"
    )
    execute(
      "ALTER TABLE invoicing_monthly_invoice " \
      "ADD CONSTRAINT invoicing_monthly_invoice_card_fk FOREIGN KEY (customer_id) REFERENCES cards_card (id) " \
      "ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED, " \
      "ADD CONSTRAINT invoicing_monthly_invoice_mode_check CHECK (mode IN ('propose', 'auto_send')), " \
      "ADD CONSTRAINT invoicing_monthly_invoice_status_check " \
      "CHECK (status IN ('proposed', 'issued', 'sent', 'failed')), " \
      "ADD CONSTRAINT invoicing_monthly_invoice_month_check CHECK (extract(day FROM month) = 1)",
      "SELECT 1"
    )
    execute(
      "ALTER TABLE invoicing_month_close " \
      "ADD CONSTRAINT invoicing_month_close_trigger_check CHECK (trigger IN ('schedule', 'manual')), " \
      "ADD CONSTRAINT invoicing_month_close_month_check CHECK (extract(day FROM month) = 1)",
      "SELECT 1"
    )
    execute(
      "CREATE INDEX invoicing_billed_delivery_invoice ON invoicing_billed_delivery (invoice_id)",
      "DROP INDEX IF EXISTS invoicing_billed_delivery_invoice"
    )
    execute(
      "CREATE INDEX invoicing_document_to_invoice ON invoicing_document (customer_id, delivery_date) " \
      "WHERE kind = 'delivery_note' AND status = 'issued'",
      "DROP INDEX IF EXISTS invoicing_document_to_invoice"
    )
    # Lignes d'une facture émise figées (même garde que les lignes).
    execute(
      <<-SQL,
        CREATE TRIGGER invoicing_billed_delivery_guard BEFORE INSERT OR UPDATE OR DELETE
          ON invoicing_billed_delivery
          FOR EACH ROW EXECUTE FUNCTION invoicing_child_guard('invoice_id')
        SQL
      "DROP TRIGGER IF EXISTS invoicing_billed_delivery_guard ON invoicing_billed_delivery"
    )
    # Reprise : factures déjà tirées d'un bon de livraison (une par bon, la
    # facture émise d'abord), déclencheur suspendu le temps de l'insertion
    # dans la transaction de la migration ; l'état `invoiced` ne touche
    # qu'une colonne modifiable d'un document émis.
    execute(
      "ALTER TABLE invoicing_billed_delivery DISABLE TRIGGER invoicing_billed_delivery_guard",
      "SELECT 1"
    )
    execute(
      <<-SQL,
        INSERT INTO invoicing_billed_delivery (invoice_id, delivery_note_id)
        SELECT DISTINCT ON (i.source_id) i.id, i.source_id
          FROM invoicing_document i
          JOIN invoicing_document n ON n.id = i.source_id AND n.kind = 'delivery_note'
         WHERE i.kind = 'invoice'
         ORDER BY i.source_id, (i.number IS NULL), i.id
        SQL
      "SELECT 1"
    )
    execute(
      "ALTER TABLE invoicing_billed_delivery ENABLE TRIGGER invoicing_billed_delivery_guard",
      "SELECT 1"
    )
    execute(
      <<-SQL,
        UPDATE invoicing_document n SET status = 'invoiced'
          FROM invoicing_billed_delivery b
          JOIN invoicing_document i ON i.id = b.invoice_id AND i.number IS NOT NULL
         WHERE n.id = b.delivery_note_id AND n.status = 'issued'
        SQL
      "UPDATE invoicing_document SET status = 'issued' WHERE kind = 'delivery_note' AND status = 'invoiced'"
    )
    execute(
      "INSERT INTO auth_profile_permission (profile_id, permission) " \
      "SELECT p.id, 'invoicing.credit_limit.override' FROM auth_profile p WHERE p.code = 'ACCOUNTANT' " \
      "ON CONFLICT (profile_id, permission) DO NOTHING",
      "DELETE FROM auth_profile_permission WHERE permission = 'invoicing.credit_limit.override'"
    )
  end
end
