# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Core
    # Règles des exercices et périodes, reprises de `Periode`
    # (`include/class/periode.class.php` : `insert`, `insert_exercice`,
    # `find_periode`, `close`, `reopen`, `verify_delete`) et du déclencheur
    # `comptaproc.check_periode`. Appelées par `Partiduo::Api::Core`.
    module Periods
      MIN_YEAR   = 1900 # COMPTA_MIN_YEAR
      MAX_YEAR   = 2100 # COMPTA_MAX_YEAR
      MAX_MONTHS =   60
      MAX_LABEL  =   64

      alias FieldError = Partiduo::Api::FieldError

      # Bornes d'une période à créer.
      record Bounds, starts_on : Time, ends_on : Time

      # Découpe un exercice en périodes mensuelles, comme
      # `Periode::insert_exercice` : `months` mois à partir de
      # `start_month`/`start_year` ; `opening_period` isole le premier jour
      # (période d'ouverture d'un jour), `closing_period` le dernier (période
      # de clôture d'un jour).
      def self.monthly_bounds(start_year : Int32, start_month : Int32, months : Int32,
                              opening_period : Bool, closing_period : Bool) : Array(Bounds)
        bounds = [] of Bounds
        year, month = start_year, start_month
        months.times do |index|
          first = Time.utc(year, month, 1)
          last = first + 1.month - 1.day
          if index == 0 && opening_period && first != last
            bounds << Bounds.new(first, first)
            bounds << Bounds.new(first + 1.day, last)
          elsif index == months - 1 && closing_period && first != last
            bounds << Bounds.new(first, last - 1.day)
            bounds << Bounds.new(last, last)
          else
            bounds << Bounds.new(first, last)
          end
          month += 1
          if month == 13
            month = 1
            year += 1
          end
        end
        bounds
      end

      # Erreurs de la saisie d'un exercice.
      def self.fiscal_year_errors(input : Partiduo::Api::Core::FiscalYearInput) : Array(FieldError)
        errors = [] of FieldError
        label = label_of(input)
        unless MIN_YEAR <= input.year <= MAX_YEAR
          errors << error("year", "fiscal_year", "out_of_range", {"min" => MIN_YEAR.to_s, "max" => MAX_YEAR.to_s})
        end
        unless MIN_YEAR <= input.start_year <= MAX_YEAR
          errors << error("start_year", "fiscal_year", "out_of_range", {"min" => MIN_YEAR.to_s, "max" => MAX_YEAR.to_s})
        end
        unless 1 <= input.start_month <= 12
          errors << error("start_month", "fiscal_year", "invalid")
        end
        unless 1 <= input.months <= MAX_MONTHS
          errors << error("months", "fiscal_year", "out_of_range", {"min" => "1", "max" => MAX_MONTHS.to_s})
        end
        if label.size > MAX_LABEL
          errors << error("label", "fiscal_year", "too_long", {"max" => MAX_LABEL.to_s})
        end

        if FiscalYear.filter(year: input.year).exists?
          errors << error("year", "fiscal_year", "taken", {"year" => input.year.to_s})
        end
        if FiscalYear.filter(label__iexact: label).exists?
          errors << error("label", "fiscal_year", "taken", {"label" => label})
        end
        return errors unless errors.empty?

        monthly_bounds(input.start_year, input.start_month, input.months, input.opening_period, input.closing_period)
          .each do |bounds|
            if overlapping = overlapping(bounds.starts_on, bounds.ends_on)
              errors << error(FieldError::BASE, "period", "overlap", overlap_params(overlapping))
              break
            end
          end
        errors
      end

      # Erreurs de l'ajout d'une période à un exercice (`Periode::insert`).
      def self.period_errors(fiscal_year : FiscalYear, starts_on : Time, ends_on : Time,
                             except_id : Int64? = nil) : Array(FieldError)
        errors = [] of FieldError
        errors << error(FieldError::BASE, "period", "fiscal_year_closed") if fiscal_year.closed_at
        if ends_on < starts_on
          errors << error("ends_on", "period", "before_start")
        end
        unless MIN_YEAR <= starts_on.year <= MAX_YEAR && MIN_YEAR <= ends_on.year <= MAX_YEAR
          errors << error("starts_on", "period", "out_of_range", {"min" => MIN_YEAR.to_s, "max" => MAX_YEAR.to_s})
        end
        if errors.empty? && (other = overlapping(starts_on, ends_on, except_id))
          errors << error(FieldError::BASE, "period", "overlap", overlap_params(other))
        end
        errors
      end

      # Première période qui chevauche `[starts_on, ends_on]`, ou `nil`.
      def self.overlapping(starts_on : Time, ends_on : Time, except_id : Int64? = nil) : Period?
        query = Period.filter(starts_on__lte: ends_on, ends_on__gte: starts_on)
        query = query.exclude(id: except_id) if except_id
        query.order(:starts_on).first
      end

      # Période qui contient `day` (`find_periode`), ou `nil`.
      def self.containing(day : Time) : Period?
        Period.filter(starts_on__lte: day, ends_on__gte: day).first
      end

      # Libellé d'exercice : celui saisi, sinon le numéro d'exercice (comme
      # `check_periode`).
      def self.label_of(input : Partiduo::Api::Core::FiscalYearInput) : String
        input.label.try(&.strip).presence || input.year.to_s
      end

      def self.date(day : Time) : Time
        Time.utc(day.year, day.month, day.day)
      end

      private def self.overlap_params(period : Period) : Hash(String, String)
        {"starts_on" => period.starts_on!.to_s("%Y-%m-%d"), "ends_on" => period.ends_on!.to_s("%Y-%m-%d")}
      end

      def self.error(field : String, object : String, code : String,
                     params = {} of String => String) : FieldError
        key = field == FieldError::BASE ? "core.errors.#{object}.#{code}" : "core.errors.#{object}.#{field}.#{code}"
        FieldError.new(field, key, params)
      end
    end
  end
end
