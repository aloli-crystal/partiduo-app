# SPDX-License-Identifier: AGPL-3.0-or-later

# Conditions de paiement par document (maquette « Nouvelle facture »,
# BLOCAGES B-FIN-001) : `payment_terms` (`net`, `end_of_month`,
# `on_receipt` ; vide : délai des paramètres) et `payment_terms_days`
# (délai du document ; vide : celui des paramètres). Les documents émis
# gardent leurs valeurs par défaut : l'ajout de colonne ne déclenche pas la
# garde d'intangibilité. DECISIONS D-R5-003.
class Migration::Invoicing::V0005 < Marten::Migration
  depends_on :invoicing, "0004_public_portal_channel"

  def plan
    add_column :invoicing_document, :payment_terms, :string, max_size: 16, default: ""
    add_column :invoicing_document, :payment_terms_days, :int, null: true

    execute(
      "ALTER TABLE invoicing_document ADD CONSTRAINT invoicing_document_payment_terms_check " \
      "CHECK (payment_terms IN ('', 'net', 'end_of_month', 'on_receipt') " \
      "AND (payment_terms_days IS NULL OR payment_terms_days BETWEEN 0 AND 365))",
      "ALTER TABLE invoicing_document DROP CONSTRAINT IF EXISTS invoicing_document_payment_terms_check"
    )
  end
end
