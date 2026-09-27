# SPDX-License-Identifier: AGPL-3.0-or-later

require "./entry"

module Partiduo
  module Accounting
    # Facture d'achat reçue (ADR-004 D9) : pièce du fournisseur derrière une
    # écriture d'achat — numéro, date et montant toutes taxes comprises de la
    # facture, fournisseur, origine (`off_platform` : papier ou PDF simple
    # saisi à la main ; `platform` : reçue par la plateforme agréée, déposée
    # par une extension). NOALYSS n'en garde que la pièce jointe et le libellé
    # de l'écriture. Sert au contrôle de doublon commun (même fournisseur, même
    # numéro, même montant). Modèle interne : écrit par
    # `Partiduo::Api::Accounting.post_received_invoice` seulement, jamais
    # modifié (migration accounting 0009).
    class ReceivedInvoice < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :entry, :one_to_one, to: Partiduo::Accounting::Entry, related: :received_invoice
      # Fiche du fournisseur (`cards_card`) ; clé étrangère posée par la migration.
      field :supplier_card_id, :big_int
      field :number, :string, max_size: 100
      # Numéro normalisé (majuscules, sans espace ni séparateur) : clé du
      # contrôle de doublon.
      field :number_key, :string, max_size: 100
      field :invoice_date, :date
      # Toutes taxes comprises, dans la devise de la facture ; négatif pour
      # un avoir.
      field :total_amount, :decimal, max_digits: 20, decimal_places: 4
      field :currency_code, :string, max_size: 3
      field :origin, :string, max_size: 16
      field :platform_reference, :string, max_size: 100, blank: true, default: ""
      field :created_by_id, :big_int, null: true, blank: true
      field :created_at, :date_time, auto_now_add: true
    end
  end
end
