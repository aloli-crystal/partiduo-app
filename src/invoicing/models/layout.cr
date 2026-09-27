# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Invoicing
    # Modèle de mise en page des documents (ADR-006 D5) : logo, couleurs,
    # textes d'en-tête et de pied. Il ne touche jamais aux mentions
    # obligatoires, générées par `Mentions`.
    class Layout < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :name, :string, max_size: 100, unique: true
      field :logo, :many_to_one, to: Partiduo::Core::Attachment, null: true, blank: true
      field :primary_color, :string, max_size: 7, default: "#1f5f73"
      field :text_color, :string, max_size: 7, default: "#1a1a1a"
      field :header_text, :text, blank: true, default: ""
      field :footer_text, :text, blank: true, default: ""
      field :is_default, :bool, default: false

      with_timestamp_fields
    end
  end
end
