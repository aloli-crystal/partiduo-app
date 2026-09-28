# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Accounting
    # Prévisions budgétaires (`Anticipation`, `forecast*`, lot 6) :
    # validation, enregistrement, copie (`object_clone`) et comparaison de
    # l'estimé et du réel période par période (`Anticipation::display`,
    # `anticipation-display.php`). Service interne.
    module Forecasts
      alias FieldError = Partiduo::Api::FieldError
      alias Api = Partiduo::Api::Accounting

      MAX_SCALE = 4

      def self.error(field : String, key : String, params = {} of String => String) : FieldError
        FieldError.new(field, "accounting.errors.forecast.#{key}", params)
      end

      # --- Validation ---------------------------------------------------------------

      def self.forecast_errors(input : Api::ForecastInput) : Array(FieldError)
        errors = [] of FieldError
        name = input.name.strip
        if name.empty?
          errors << error("name", "name.blank")
        elsif name.size > 255
          errors << error("name", "name.too_long", {"max" => "255"})
        end
        start = period(input.start_period_id)
        finish = period(input.end_period_id)
        errors << error("start_period_id", "period.unknown", {"id" => input.start_period_id.to_s}) if start.nil?
        errors << error("end_period_id", "period.unknown", {"id" => input.end_period_id.to_s}) if finish.nil?
        if start && finish && finish.starts_on! < start.starts_on!
          errors << error("end_period_id", "period.order")
        end
        errors
      end

      def self.category_errors(input : Api::ForecastCategoryInput) : Array(FieldError)
        label_errors("label", input.label)
      end

      def self.item_errors(forecast : Forecast, input : Api::ForecastItemInput) : Array(FieldError)
        errors = label_errors("label", input.label)
        formula = input.formula.strip
        # Formule vide admise, comme à l'origine (`fi_account` vide) : le
        # réel vaut zéro (D-FCT-003).
        if formula.empty?
          # rien à contrôler
        elsif formula.size > Formula::MAX_LENGTH
          errors << error("formula", "formula.too_long", {"max" => Formula::MAX_LENGTH.to_s})
        elsif problem = Formula.check(formula)
          errors << problem.field_error("formula")
        end
        errors.concat(amount_errors("amount", input.amount))
        errors.concat(amount_errors("initial_amount", input.initial_amount))
        range = period_ids(forecast).to_set
        seen = Set(Int64).new
        input.period_amounts.each_with_index do |row, index|
          path = "period_amounts[#{index}]"
          if !range.includes?(row.period_id)
            errors << error("#{path}.period_id", "period.outside", {"id" => row.period_id.to_s})
          elsif !seen.add?(row.period_id)
            errors << error("#{path}.period_id", "period.twice")
          end
          errors.concat(amount_errors("#{path}.amount", row.amount))
        end
        errors
      end

      private def self.label_errors(field : String, label : String) : Array(FieldError)
        label = label.strip
        return [error(field, "label.blank")] if label.empty?
        return [error(field, "label.too_long", {"max" => "255"})] if label.size > 255
        [] of FieldError
      end

      private def self.amount_errors(field : String, amount : BigDecimal) : Array(FieldError)
        return [error(field, "amount.scale", {"max" => MAX_SCALE.to_s})] if amount.scale > MAX_SCALE
        [] of FieldError
      end

      # --- Périodes ---------------------------------------------------------------------

      def self.period(id : Int64) : Partiduo::Core::Period?
        Partiduo::Core::Period.filter(id: id).first
      end

      # Périodes couvertes par la prévision, de la première à la dernière
      # (`parm_periode` entre `f_start_date` et `f_end_date`).
      def self.periods(forecast : Forecast) : Array(Partiduo::Core::Period)
        start = period(forecast.start_period_id!.as(Int64)) || return [] of Partiduo::Core::Period
        finish = period(forecast.end_period_id!.as(Int64)) || return [] of Partiduo::Core::Period
        Partiduo::Core::Period.filter(starts_on__gte: start.starts_on!, ends_on__lte: finish.ends_on!)
          .order(:starts_on, :ends_on).to_a
      end

      def self.period_ids(forecast : Forecast) : Array(Int64)
        periods(forecast).map(&.pk!.as(Int64))
      end

      # --- Enregistrement ---------------------------------------------------------------

      def self.save_item!(item : ForecastItem, input : Api::ForecastItemInput) : ForecastItem
        item.label = input.label.strip
        item.formula = input.formula.strip
        item.amount = input.amount
        item.initial_amount = input.initial_amount
        item.position = input.position
        item.save!
        ForecastAmount.filter(item_id: item.pk).delete
        input.period_amounts.each do |row|
          ForecastAmount.create!(item: item, period_id: row.period_id, amount: row.amount)
        end
        item
      end

      # Copie la prévision, ses catégories, ses éléments et leurs montants par
      # période (`Anticipation::object_clone`, qui omettait le montant
      # initial).
      def self.clone!(source : Forecast, name : String, created_by_id : Int64?) : Forecast
        copy = Forecast.create!(name: name.strip, start_period_id: source.start_period_id,
          end_period_id: source.end_period_id, created_by_id: created_by_id)
        ForecastCategory.filter(forecast_id: source.pk).order(:position, :id).each do |category|
          new_category = ForecastCategory.create!(forecast: copy, label: category.label, position: category.position)
          ForecastItem.filter(category_id: category.pk).order(:position, :id).each do |item|
            new_item = ForecastItem.create!(category: new_category, label: item.label, formula: item.formula,
              amount: item.amount, initial_amount: item.initial_amount, position: item.position)
            ForecastAmount.filter(item_id: item.pk).each do |row|
              ForecastAmount.create!(item: new_item, period_id: row.period_id, amount: row.amount)
            end
          end
        end
        copy
      end

      # --- Vues ---------------------------------------------------------------------------

      def self.summary(forecast : Forecast) : Api::ForecastSummaryView
        start = period(forecast.start_period_id!.as(Int64))
        finish = period(forecast.end_period_id!.as(Int64))
        Api::ForecastSummaryView.new(forecast.pk!.as(Int64), forecast.name!, forecast.start_period_id!.as(Int64),
          forecast.end_period_id!.as(Int64), start.try(&.starts_on!) || Time.utc(1970, 1, 1),
          finish.try(&.ends_on!) || Time.utc(1970, 1, 1))
      end

      def self.view(forecast : Forecast) : Api::ForecastView
        categories = ForecastCategory.filter(forecast_id: forecast.pk).order(:position, :id).to_a
        items = categories.empty? ? [] of ForecastItem : ForecastItem.filter(category_id__in: categories.map(&.pk!)).order(:position, :id).to_a
        amounts = if items.empty?
                    {} of Int64 => Array(ForecastAmount)
                  else
                    ForecastAmount.filter(item_id__in: items.map(&.pk!)).to_a.group_by(&.item_id!.as(Int64))
                  end
        starts = periods(forecast).to_h { |row| {row.pk!.as(Int64), row.starts_on!} }
        by_category = items.group_by(&.category_id!.as(Int64))
        category_views = categories.map do |category|
          category_id = category.pk!.as(Int64)
          item_views = by_category.fetch(category_id, [] of ForecastItem).map do |item|
            rows = amounts.fetch(item.pk!.as(Int64), [] of ForecastAmount)
              .sort_by { |row| starts[row.period_id!.as(Int64)]? || Time.utc(1970, 1, 1) }
              .map { |row| Api::ForecastPeriodAmountView.new(row.period_id!.as(Int64), row.amount!) }
            Api::ForecastItemView.new(item.pk!.as(Int64), category_id, item.label!, item.formula!, item.amount!,
              item.initial_amount!, item.position!.to_i32, rows)
          end
          Api::ForecastCategoryView.new(category_id, category.label!, category.position!.to_i32, item_views)
        end
        Api::ForecastView.new(summary(forecast), category_views)
      end

      # --- Estimé et réel ---------------------------------------------------------------

      # Pour chaque élément et chaque période : estimé (montant de la
      # période s'il est saisi, sinon montant de l'élément ; montant initial
      # ajouté à la première période) et réel (formule calculée sur la seule
      # période, journaux visibles de l'acteur). Une formule devenue
      # invalide vaut zéro et est signalée (`invalid_items`).
      def self.report(forecast : Forecast, ledger_ids : Array(Int64)) : Api::ForecastReportView
        view = view(forecast)
        periods = periods(forecast)
        refs = periods.map { |row| Api::ForecastPeriodRef.new(row.pk!.as(Int64), row.starts_on!, row.ends_on!) }
        contexts = periods.map do |row|
          Statements::BalanceContext.new(ReportData.sums(ledger_ids, row.starts_on!, row.ends_on!, by_card: true, opening: false))
        end
        # Contextes des formules à date de début, partagés par couple
        # (début, fin de période) : une requête par couple, pas par élément.
        from_contexts = {} of {Time, Time} => Statements::BalanceContext
        invalid = [] of String
        categories = view.categories.map do |category|
          rows = category.items.map do |item|
            overrides = item.period_amounts.to_h { |row| {row.period_id, row.amount} }
            estimated = refs.map_with_index do |ref, index|
              amount = overrides[ref.id]? || item.amount
              index.zero? ? amount + item.initial_amount : amount
            end
            parsed = begin
              item.formula.blank? ? nil : Formula.parse(item.formula)
            rescue Formula::Error
              invalid << item.label
              nil
            end
            real = periods.map_with_index do |row, index|
              next BigDecimal.new(0) if parsed.nil?
              context = contexts[index]
              if from = parsed.from
                context = from_contexts[{from, row.ends_on!}] ||=
                  Statements::BalanceContext.new(ReportData.sums(ledger_ids, from, row.ends_on!, by_card: true, opening: false))
              end
              begin
                Statements.round(parsed.evaluate(context))
              rescue Formula::Error
                BigDecimal.new(0)
              end
            end
            Api::ForecastReportItemView.new(item.id, item.label, item.formula, estimated, real)
          end
          Api::ForecastReportCategoryView.new(category.id, category.label, rows)
        end
        Api::ForecastReportView.new(view.forecast, refs, categories, invalid)
      end
    end
  end
end
