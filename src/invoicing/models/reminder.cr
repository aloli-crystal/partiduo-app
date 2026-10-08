# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Invoicing
    # Relance proposée pour une facture échue (ADR-006 D5) : jamais envoyée
    # sans validation. Une seule relance par facture et par niveau.
    class Reminder < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :document, :many_to_one, to: Partiduo::Invoicing::Document, related: :reminders
      field :level, :int
      field :status, :string, max_size: 16, default: "proposed"
      field :proposed_on, :date
      field :days_late, :int
      field :balance, :decimal, max_digits: 20, decimal_places: 4
      field :interest, :decimal, max_digits: 20, decimal_places: 4, default: BigDecimal.new(0)
      field :indemnity, :decimal, max_digits: 20, decimal_places: 4, default: BigDecimal.new(0)
      field :sent_at, :date_time, null: true, blank: true
      field :handled_by_id, :big_int, null: true, blank: true
      # Rejet de paiement qui a fait proposer la relance (migration `0007`,
      # D-INV3-009) ; le courriel le rappelle.
      field :payment_rejection_id, :big_int, null: true, blank: true

      with_timestamp_fields

      db_unique_constraint :invoicing_reminder_document_level, field_names: [:document, :level]
    end
  end
end
