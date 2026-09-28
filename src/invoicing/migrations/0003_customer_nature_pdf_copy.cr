# SPDX-License-Identifier: AGPL-3.0-or-later

# ADR-004 D9 révisé (28 septembre 2026) : canal `chorus_pro` pour les clients
# publics ; copie PDF doublant l'envoi par la plateforme agréée, option du
# dossier datée (`pdf_copy_from` … `pdf_copy_until`, posée au premier envoi
# par la plateforme pour un an si elle est vide). DECISIONS D-FIN-001 et
# D-FIN-002.
class Migration::Invoicing::V0003 < Marten::Migration
  depends_on :invoicing, "0002_issue_channel"

  def plan
    add_column :invoicing_settings, :pdf_copy_enabled, :bool, default: true
    add_column :invoicing_settings, :pdf_copy_from, :date, null: true
    add_column :invoicing_settings, :pdf_copy_until, :date, null: true

    execute(
      "ALTER TABLE invoicing_document DROP CONSTRAINT invoicing_document_issue_channel_check, " \
      "ADD CONSTRAINT invoicing_document_issue_channel_check " \
      "CHECK (issue_channel IN ('', 'platform', 'email', 'paper', 'chorus_pro'))",
      "ALTER TABLE invoicing_document DROP CONSTRAINT invoicing_document_issue_channel_check, " \
      "ADD CONSTRAINT invoicing_document_issue_channel_check " \
      "CHECK (issue_channel IN ('', 'platform', 'email', 'paper'))"
    )
    execute(
      "ALTER TABLE invoicing_settings ADD CONSTRAINT invoicing_settings_pdf_copy_period_check " \
      "CHECK (pdf_copy_from IS NULL OR pdf_copy_until IS NULL OR pdf_copy_from <= pdf_copy_until)",
      "ALTER TABLE invoicing_settings DROP CONSTRAINT IF EXISTS invoicing_settings_pdf_copy_period_check"
    )
  end
end
