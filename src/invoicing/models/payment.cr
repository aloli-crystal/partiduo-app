# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Invoicing
    # Règlement d'une facture (ADR-006 D3, D5) : saisi à la main quand la
    # Comptabilité est inactive (`source` = `manual`, publie
    # `payment.recorded`), ou reçu du lettrage de la Comptabilité
    # (`source` = `matching`, événement `payment.matched`).
    class Payment < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :document, :many_to_one, to: Partiduo::Invoicing::Document, related: :payments
      field :paid_on, :date
      field :amount, :decimal, max_digits: 20, decimal_places: 4
      field :method, :string, max_size: 16, default: "transfer"
      field :reference, :string, max_size: 100, blank: true, default: ""
      field :source, :string, max_size: 16, default: "manual"
      field :matching_id, :string, max_size: 64, blank: true, default: ""
      field :recorded_by_id, :big_int, null: true, blank: true

      with_timestamp_fields
    end

    # Rejet d'un règlement (D-INV3-007) : chèque impayé, prélèvement rejeté,
    # virement retourné. Le règlement n'est jamais effacé : il reste, désigné
    # par ce rejet, et ne compte plus dans `paid_amount`. En ajout seul
    # (déclencheur). `fees` : frais bancaires (0 sans frais) ;
    # `fees_invoice_id` : brouillon de la facture des frais refacturés ;
    # `reminder_id` : relance proposée aussitôt.
    class PaymentRejection < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :payment, :one_to_one, to: Partiduo::Invoicing::Payment, related: :rejection
      field :document, :many_to_one, to: Partiduo::Invoicing::Document, related: :payment_rejections
      field :rejected_on, :date
      field :reason, :string, max_size: 24
      field :reason_text, :text, blank: true, default: ""
      field :amount, :decimal, max_digits: 20, decimal_places: 4
      field :fees, :decimal, max_digits: 20, decimal_places: 4, default: BigDecimal.new(0)
      field :fees_rebilled, :bool, default: false
      field :fees_invoice_id, :big_int, null: true, blank: true
      field :reminder_id, :big_int, null: true, blank: true
      field :recorded_by_id, :big_int, null: true, blank: true
      field :created_at, :date_time
    end
  end
end
