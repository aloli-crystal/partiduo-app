# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Invoicing
    # Document commercial (ADR-006 D5) : devis, commande, bon de livraison,
    # facture, facture d'acompte, avoir. NOALYSS n'en a pas : ses devis et
    # bons de commande sont des « actions » du suivi (`action_gestion`) et sa
    # facture une écriture du journal de ventes (`jrn` + `quant_sold`).
    #
    # Un brouillon n'a pas de numéro ; le numéro (`number`, `sequence` dans la
    # série `series` et l'année `year`) est attribué à l'émission par la table
    # de compteurs (`Counter`). Émis, le document est *intangible* : un
    # déclencheur refuse toute suppression et toute modification autre que
    # l'état, les montants réglés ou crédités et la date d'envoi (migration
    # `0001`).
    #
    # `seller`, `customer` : identités figées à l'émission (JSON) ;
    # `delivery_address` : adresse de livraison du document ; `fingerprint` :
    # SHA-256 du contenu canonique à l'émission (traçabilité).
    class Document < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :kind, :string, max_size: 16
      field :status, :string, max_size: 16, default: "draft"
      field :series, :string, max_size: 16
      field :year, :int, null: true, blank: true
      field :sequence, :int, null: true, blank: true
      field :number, :string, max_size: 32, null: true, blank: true
      field :customer, :many_to_one, to: Partiduo::Cards::Card
      field :source, :many_to_one, to: Partiduo::Invoicing::Document, null: true, blank: true, related: :derived
      field :credited, :many_to_one, to: Partiduo::Invoicing::Document, null: true, blank: true,
        related: :credit_notes
      field :layout, :many_to_one, to: Partiduo::Invoicing::Layout, null: true, blank: true
      field :locale, :string, max_size: 5, default: "fr"
      field :currency_code, :string, max_size: 3, default: "EUR"
      field :issue_date, :date, null: true, blank: true
      field :delivery_date, :date, null: true, blank: true
      field :due_date, :date, null: true, blank: true
      field :validity_date, :date, null: true, blank: true
      field :operation_category, :string, max_size: 16, blank: true, default: ""
      field :vat_on_debits, :bool, default: false
      field :buyer_reference, :string, max_size: 100, blank: true, default: ""
      field :order_reference, :string, max_size: 100, blank: true, default: ""
      field :notes, :text, blank: true, default: ""
      field :global_discount_kind, :string, max_size: 8, default: "none"
      field :global_discount_value, :decimal, max_digits: 20, decimal_places: 4, default: BigDecimal.new(0)
      field :delivery_address, :json, null: true, blank: true
      field :seller, :json, null: true, blank: true
      field :customer_snapshot, :json, null: true, blank: true
      field :structured_reference, :string, max_size: 24, blank: true, default: ""
      # Mentions obligatoires figées à l'émission (code, clé, paramètres).
      field :mentions, :json, null: true, blank: true

      # Montants calculés (arrondis à deux décimales), recalculés à chaque
      # enregistrement du brouillon et figés à l'émission.
      field :lines_total, :decimal, max_digits: 20, decimal_places: 4, default: BigDecimal.new(0)
      field :discount_total, :decimal, max_digits: 20, decimal_places: 4, default: BigDecimal.new(0)
      field :total_net, :decimal, max_digits: 20, decimal_places: 4, default: BigDecimal.new(0)
      field :total_vat, :decimal, max_digits: 20, decimal_places: 4, default: BigDecimal.new(0)
      field :total_gross, :decimal, max_digits: 20, decimal_places: 4, default: BigDecimal.new(0)
      field :prepaid_amount, :decimal, max_digits: 20, decimal_places: 4, default: BigDecimal.new(0)
      # Seuls montants qui évoluent après l'émission.
      field :paid_amount, :decimal, max_digits: 20, decimal_places: 4, default: BigDecimal.new(0)
      field :credited_amount, :decimal, max_digits: 20, decimal_places: 4, default: BigDecimal.new(0)

      field :issued_at, :date_time, null: true, blank: true
      field :issued_by_id, :big_int, null: true, blank: true
      field :fingerprint, :string, max_size: 64, blank: true, default: ""
      field :facturx_xml, :text, blank: true, default: ""
      field :pdf, :many_to_one, to: Partiduo::Core::Attachment, null: true, blank: true
      field :sent_at, :date_time, null: true, blank: true
      field :created_by_id, :big_int, null: true, blank: true

      with_timestamp_fields

      def draft? : Bool
        number.nil?
      end
    end

    # Ligne d'un document : article (fiche de nature `item`), désignation
    # libre, note, titre ou sous-total. Montants de ligne arrondis à deux
    # décimales (`Calculator`).
    class Line < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :document, :many_to_one, to: Partiduo::Invoicing::Document, related: :lines, on_delete: :cascade
      field :position, :int
      field :kind, :string, max_size: 8
      field :item, :many_to_one, to: Partiduo::Cards::Card, null: true, blank: true
      field :description, :text, blank: true, default: ""
      field :quantity, :decimal, max_digits: 20, decimal_places: 4, default: BigDecimal.new(0)
      field :unit_code, :string, max_size: 3, blank: true, default: ""
      field :unit_price, :decimal, max_digits: 20, decimal_places: 4, default: BigDecimal.new(0)
      field :discount_kind, :string, max_size: 8, default: "none"
      field :discount_value, :decimal, max_digits: 20, decimal_places: 4, default: BigDecimal.new(0)
      field :discount_amount, :decimal, max_digits: 20, decimal_places: 4, default: BigDecimal.new(0)
      field :vat_rate, :many_to_one, to: Partiduo::Vat::Rate, null: true, blank: true
      # Taux, catégorie et motif d'exonération figés (le taux cité ne change
      # plus, D-REF-009, mais la ligne se suffit à elle-même).
      field :vat_percent, :decimal, max_digits: 7, decimal_places: 4, default: BigDecimal.new(0)
      field :vat_category, :string, max_size: 2, blank: true, default: ""
      field :net_amount, :decimal, max_digits: 20, decimal_places: 4, default: BigDecimal.new(0)
    end

    # Acompte déduit d'une facture (facture d'acompte émise, déduite une
    # seule fois : index unique sur `deposit_id`).
    class DepositDeduction < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :invoice, :many_to_one, to: Partiduo::Invoicing::Document, related: :deductions, on_delete: :cascade
      field :deposit, :one_to_one, to: Partiduo::Invoicing::Document, related: :deducted_in
      field :amount, :decimal, max_digits: 20, decimal_places: 4
    end
  end
end
