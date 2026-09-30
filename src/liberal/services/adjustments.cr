# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Liberal
    # Réintégrations et déductions diverses d'une année (2035-A), hors
    # livre-journal : quote-part privée d'une dépense, exonérations,
    # abattements, quote-part de SCM, frais d'établissement, provisions.
    # Libres tant qu'aucune période de l'année n'est close et que sa 2035
    # n'est pas transmise (déclencheur `liberal_adjustment_guard`, DECISIONS
    # D-LIB2-005). Service interne.
    module Adjustments
      alias Api = Partiduo::Api::Liberal

      def self.errors(input : Api::AdjustmentInput) : Array(Partiduo::Api::FieldError)
        errors = [] of Partiduo::Api::FieldError
        errors << Registers.error("year", "adjustment.year.invalid") unless 1900 <= input.year <= 2999
        errors << Registers.error("year", "adjustment.year.closed") if closed?(input.year)
        errors << Registers.error("kind", "adjustment.kind.invalid") unless Api::ADJUSTMENT_KINDS.includes?(input.kind)
        errors << Registers.error("label", "adjustment.label.blank") if input.label.strip.empty?
        errors << Registers.error("label", "line.too_long", {"max" => "255"}) if input.label.size > 255
        errors.concat(Registers.amount_errors("amount", input.amount))
        errors
      end

      # Une période close du socle chevauche l'année, ou sa 2035 est
      # transmise.
      def self.closed?(year : Int32) : Bool
        Partiduo::Api::Core.periods(Partiduo::Api::Actor.system).any? do |period|
          period.closed? && period.starts_on <= Time.utc(year, 12, 31) && period.ends_on >= Time.utc(year, 1, 1)
        end || Years.transmitted?(year)
      end

      def self.views(rows : Array(Adjustment)) : Array(Api::AdjustmentView)
        closed = {} of Int32 => Bool
        rows.map do |row|
          year = (row.year || 0).to_i32
          locked = closed[year]? || (closed[year] = closed?(year))
          Api::AdjustmentView.new(row.pk!.as(Int64), year, row.kind.to_s, row.label.to_s, row.amount!, locked)
        end
      end
    end
  end
end
