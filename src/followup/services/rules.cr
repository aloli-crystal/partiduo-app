# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Followup
    # Règles de saisie du Suivi (`Follow_Up::verify`, `cfg_action`,
    # `Tag`) : erreurs par champ, clés `followup.errors.<objet>.<code>`.
    # Service interne.
    module Rules
      alias FieldError = Partiduo::Api::FieldError
      alias Api = Partiduo::Api::Followup

      REFERENCE = /\A[a-z][a-z_]*:[0-9]+\z/

      def self.error(field : String, object : String, code : String, params = {} of String => String) : FieldError
        FieldError.new(field, "followup.errors.#{object}.#{code}", params)
      end

      def self.normalize_code(code : String) : String
        code.strip.upcase
      end

      # --- Types d'action -----------------------------------------------------------------

      def self.action_type_errors(input : Api::ActionTypeInput, id : Int64? = nil) : Array(FieldError)
        errors = [] of FieldError
        code = normalize_code(input.code)
        if code.empty?
          errors << error("code", "action_type", "code_required")
        elsif code.size > 10
          errors << error("code", "action_type", "code_too_long", {"max" => "10"})
        elsif !code.matches?(/\A[A-Z0-9]+\z/)
          errors << error("code", "action_type", "code_invalid")
        else
          taken = ActionType.filter(code: code)
          taken = taken.exclude(id: id) if id
          errors << error("code", "action_type", "code_taken", {"code" => code}) if taken.exists?
        end
        label = input.label.strip
        if label.empty?
          errors << error("label", "action_type", "label_required")
        elsif label.size > 80
          errors << error("label", "action_type", "label_too_long", {"max" => "80"})
        end
        if (number = input.next_number) && number < 1
          errors << error("next_number", "action_type", "next_number_invalid")
        end
        errors
      end

      # --- Étiquettes -------------------------------------------------------------------

      def self.tag_errors(input : Api::TagInput, id : Int64? = nil) : Array(FieldError)
        errors = [] of FieldError
        label = input.label.strip
        if label.empty?
          errors << error("label", "tag", "label_required")
        elsif label.size > 60
          errors << error("label", "tag", "label_too_long", {"max" => "60"})
        else
          taken = Tag.filter(label__iexact: label)
          taken = taken.exclude(id: id) if id
          errors << error("label", "tag", "label_taken", {"label" => label}) if taken.exists?
        end
        errors << error("color", "tag", "color_invalid") unless 1 <= input.color <= 10
        errors
      end

      # --- Actions ------------------------------------------------------------------------

      def self.action_errors(input : Api::ActionInput) : Array(FieldError)
        errors = [] of FieldError
        unless ActionType.filter(id: input.action_type_id).exists?
          errors << error("action_type_id", "action", "type_unknown", {"id" => input.action_type_id.to_s})
        end
        errors << error("title", "action", "title_too_long", {"max" => "255"}) if input.title.strip.size > 255
        hour = input.hour.strip
        unless hour.empty? || valid_hour?(hour)
          errors << error("hour", "action", "hour_invalid")
        end
        errors << error("priority", "action", "priority_invalid") unless Api::PRIORITIES.includes?(input.priority)
        errors << error("state", "action", "state_invalid") unless Api::STATES.includes?(input.state)
        errors.concat(profile_errors(input.visible_profile_id))
        cards = Cards.by_id(([input.card_id, input.contact_card_id].compact + input.concerned_card_ids))
        {"card_id" => input.card_id, "contact_card_id" => input.contact_card_id}.each do |field, card_id|
          next if card_id.nil? || cards.has_key?(card_id)
          errors << error(field, "action", "card_unknown", {"id" => card_id.to_s})
        end
        input.concerned_card_ids.each_with_index do |card_id, index|
          next if cards.has_key?(card_id)
          errors << error("concerned_card_ids[#{index}]", "action", "card_unknown", {"id" => card_id.to_s})
        end
        known = Tag.filter(id__in: input.tag_ids.uniq).to_a.map(&.pk!.as(Int64)).to_set
        input.tag_ids.each_with_index do |tag_id, index|
          next if known.includes?(tag_id)
          errors << error("tag_ids[#{index}]", "action", "tag_unknown", {"id" => tag_id.to_s})
        end
        errors
      end

      # Profil auquel l'action est réservée : existant (D-R5-016).
      def self.profile_errors(profile_id : Int64?) : Array(FieldError)
        return [] of FieldError if profile_id.nil? || Partiduo::Auth::Profile.filter(id: profile_id).exists?
        [error("visible_profile_id", "action", "profile_unknown")]
      end

      def self.valid_hour?(hour : String) : Bool
        return false unless match = hour.match(/\A(\d{1,2}):(\d{2})\z/)
        match[1].to_i < 24 && match[2].to_i < 60
      end

      def self.normalized_hour(hour : String) : String
        hour = hour.strip
        return "" if hour.empty?
        hours, minutes = hour.split(':')
        "#{hours.rjust(2, '0')}:#{minutes}"
      end

      def self.comment_errors(text : String) : Array(FieldError)
        text = text.strip
        return [error("text", "comment", "text_required")] if text.empty?
        return [error("text", "comment", "text_too_long", {"max" => "10000"})] if text.size > 10_000
        [] of FieldError
      end

      def self.link_errors(reference : String) : Array(FieldError)
        reference = reference.strip
        return [error("reference", "link", "invalid")] unless reference.matches?(REFERENCE) && reference.size <= 40
        [] of FieldError
      end
    end

    # Lecture des fiches du socle (quick code, nom) en bloc.
    module Cards
      def self.by_id(ids : Array(Int64)) : Hash(Int64, Partiduo::Api::Followup::CardRef)
        found = {} of Int64 => Partiduo::Api::Followup::CardRef
        return found if ids.empty?
        Marten::DB::Connection.default.open do |db|
          db.query("SELECT id, code, name FROM cards_card WHERE id = ANY($1)", args: [ids.uniq]) do |result_set|
            result_set.each do
              ref = Partiduo::Api::Followup::CardRef.new(result_set.read(Int64), result_set.read(String), result_set.read(String))
              found[ref.id] = ref
            end
          end
        end
        found
      end
    end
  end
end
