# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Invoicing
    # Trace d'un envoi par courriel d'un document ou d'une relance.
    class EmailLog < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :document, :many_to_one, to: Partiduo::Invoicing::Document, related: :email_logs
      field :reminder, :many_to_one, to: Partiduo::Invoicing::Reminder, null: true, blank: true
      field :recipients, :string, max_size: 1000
      field :subject, :string, max_size: 255
      field :body, :text, blank: true, default: ""
      field :attachment_name, :string, max_size: 255, blank: true, default: ""
      field :attachment_sha256, :string, max_size: 64, blank: true, default: ""
      field :message_id, :string, max_size: 255, blank: true, default: ""
      field :status, :string, max_size: 8
      field :error, :text, blank: true, default: ""
      field :sent_by_id, :big_int, null: true, blank: true

      with_timestamp_fields
    end
  end
end
