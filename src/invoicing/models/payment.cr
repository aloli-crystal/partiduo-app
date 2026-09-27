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
  end
end
