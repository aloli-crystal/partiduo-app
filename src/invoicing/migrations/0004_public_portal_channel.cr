# SPDX-License-Identifier: AGPL-3.0-or-later

# Canal des clients publics : `chorus_pro` devient `public_portal` (portail
# public de facturation, Chorus Pro en France), proposé quand l'extension
# `CHORUSPRO` est active (ADR-004 D9 révisé). Le canal ne fait pas partie de
# l'empreinte ; la valeur des documents émis est renommée sous le
# déclencheur d'intangibilité suspendu le temps de la mise à jour, dans la
# transaction de la migration. DECISIONS D-CPY-003.
class Migration::Invoicing::V0004 < Marten::Migration
  depends_on :invoicing, "0003_customer_nature_pdf_copy"

  def plan
    execute(
      "ALTER TABLE invoicing_document DROP CONSTRAINT invoicing_document_issue_channel_check",
      "ALTER TABLE invoicing_document ADD CONSTRAINT invoicing_document_issue_channel_check " \
      "CHECK (issue_channel IN ('', 'platform', 'email', 'paper', 'chorus_pro'))"
    )
    execute(
      "ALTER TABLE invoicing_document DISABLE TRIGGER invoicing_document_guard",
      "ALTER TABLE invoicing_document ENABLE TRIGGER invoicing_document_guard"
    )
    execute(
      "UPDATE invoicing_document SET issue_channel = 'public_portal' WHERE issue_channel = 'chorus_pro'",
      "UPDATE invoicing_document SET issue_channel = 'chorus_pro' WHERE issue_channel = 'public_portal'"
    )
    execute(
      "ALTER TABLE invoicing_document ENABLE TRIGGER invoicing_document_guard",
      "ALTER TABLE invoicing_document DISABLE TRIGGER invoicing_document_guard"
    )
    execute(
      "ALTER TABLE invoicing_document ADD CONSTRAINT invoicing_document_issue_channel_check " \
      "CHECK (issue_channel IN ('', 'platform', 'email', 'paper', 'public_portal'))",
      "ALTER TABLE invoicing_document DROP CONSTRAINT invoicing_document_issue_channel_check"
    )
  end
end
