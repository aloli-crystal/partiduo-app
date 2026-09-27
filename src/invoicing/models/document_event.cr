# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Invoicing
    # Journal des opérations sur un document (traçabilité, ADR-006 D5) :
    # création, émission (avec l'empreinte), transformation, envoi,
    # règlement, relance, avoir. Jamais modifié ni supprimé (déclencheur).
    class DocumentEvent < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :document, :many_to_one, to: Partiduo::Invoicing::Document, related: :events
      field :action, :string, max_size: 32
      field :user_id, :big_int, null: true, blank: true
      field :fingerprint, :string, max_size: 64, blank: true, default: ""
      field :details, :json, null: true, blank: true
      field :created_at, :date_time
    end
  end
end
