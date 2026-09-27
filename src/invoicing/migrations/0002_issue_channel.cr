# SPDX-License-Identifier: AGPL-3.0-or-later

# Canal d'émission des documents fiscaux (ADR-004 D9) : plateforme agréée,
# courriel ou papier, proposé selon le client et modifiable jusqu'à l'envoi ;
# marquage B2C pour l'e-reporting. Le canal et le marquage restent modifiables
# sur un document émis tant que `sent_at` est nul : le déclencheur
# d'intangibilité les ajoute aux colonnes modifiables, sauf après l'envoi.
# DECISIONS D-INV-016.
class Migration::Invoicing::V0002 < Marten::Migration
  depends_on :invoicing, "0001_invoicing"

  GUARD_BEFORE = <<-SQL
    CREATE OR REPLACE FUNCTION invoicing_document_guard() RETURNS trigger LANGUAGE plpgsql AS $$
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

  GUARD_AFTER = <<-SQL
    CREATE OR REPLACE FUNCTION invoicing_document_guard() RETURNS trigger LANGUAGE plpgsql AS $$
    DECLARE
      mutable text[] := ARRAY['status', 'paid_amount', 'credited_amount', 'sent_at', 'updated_at', 'pdf_id',
                              'issue_channel', 'b2c'];
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
        -- Un envoi ne s'efface pas : sinon, remettre `sent_at` à nul
        -- rouvrirait le canal d'émission.
        IF OLD.sent_at IS NOT NULL AND NEW.sent_at IS NULL THEN
          RAISE EXCEPTION 'invoicing: document % envoyé, date d''envoi figée', OLD.number
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;
        -- Canal d'émission et marquage B2C : figés une fois le document envoyé.
        IF OLD.sent_at IS NOT NULL AND (NEW.issue_channel IS DISTINCT FROM OLD.issue_channel
                                        OR NEW.b2c IS DISTINCT FROM OLD.b2c) THEN
          RAISE EXCEPTION 'invoicing: document % envoyé, canal d''émission figé', OLD.number
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;
      END IF;
      RETURN NEW;
    END
    $$
    SQL

  def plan
    add_column :invoicing_document, :issue_channel, :string, max_size: 16, default: ""
    add_column :invoicing_document, :b2c, :bool, default: false

    execute(
      "ALTER TABLE invoicing_document ADD CONSTRAINT invoicing_document_issue_channel_check " \
      "CHECK (issue_channel IN ('', 'platform', 'email', 'paper'))",
      "ALTER TABLE invoicing_document DROP CONSTRAINT IF EXISTS invoicing_document_issue_channel_check"
    )
    execute(GUARD_AFTER, GUARD_BEFORE)
  end
end
