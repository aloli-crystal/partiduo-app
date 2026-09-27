# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Invoicing
    # Modèles de mise en page : aspect seulement (logo, couleurs, textes
    # d'en-tête et de pied). Aucun champ ne porte une mention obligatoire.
    module Layouts
      alias Api = Partiduo::Api::Invoicing
      alias FieldError = Partiduo::Api::FieldError

      COLOR = /\A#[0-9a-fA-F]{6}\z/

      def self.view(layout : Layout) : Api::LayoutView
        Api::LayoutView.new(
          id: Documents.id_of(layout.id), name: layout.name!,
          logo_attachment_id: layout.logo_id.try { |logo_id| Documents.id_of(logo_id) },
          primary_color: layout.primary_color!, text_color: layout.text_color!,
          header_text: layout.header_text.to_s, footer_text: layout.footer_text.to_s, is_default: layout.is_default!,
        )
      end

      def self.errors(input : Api::LayoutInput, id : Int64? = nil) : Array(FieldError)
        errors = [] of FieldError
        name = input.name.strip
        if name.empty?
          errors << Documents.error("name", "layout.name.blank")
        elsif name.size > 100
          errors << Documents.error("name", "layout.name.too_long", {"max" => "100"})
        else
          query = Layout.filter(name: name)
          query = query.exclude(id: id) if id
          errors << Documents.error("name", "layout.name.taken") if query.exists?
        end
        {"primary_color" => input.primary_color, "text_color" => input.text_color}.each do |field, color|
          errors << Documents.error(field, "layout.color") unless color.matches?(COLOR)
        end
        {"header_text" => input.header_text, "footer_text" => input.footer_text}.each do |field, value|
          errors << Documents.error(field, "layout.text.too_long", {"max" => "500"}) if value.size > 500
        end
        if logo_id = input.logo_attachment_id
          begin
            attachment = Partiduo::Api::Core.attachment(Partiduo::Api::Actor.system, logo_id)
            unless attachment.content_type.in?("image/png", "image/jpeg")
              errors << Documents.error("logo_attachment_id", "layout.logo.type")
            end
          rescue Partiduo::Api::NotFound
            errors << Documents.error("logo_attachment_id", "layout.logo.not_found")
          end
        end
        errors
      end

      def self.save!(input : Api::LayoutInput, layout : Layout = Layout.new) : Api::LayoutView
        if input.is_default
          query = Layout.filter(is_default: true)
          query = query.exclude(id: layout.id) if layout.persisted?
          query.update(is_default: false)
        end
        layout.name = input.name.strip
        layout.logo_id = input.logo_attachment_id
        layout.primary_color = input.primary_color.downcase
        layout.text_color = input.text_color.downcase
        layout.header_text = input.header_text
        layout.footer_text = input.footer_text
        layout.is_default = input.is_default
        layout.save!
        view(layout)
      end
    end
  end
end
