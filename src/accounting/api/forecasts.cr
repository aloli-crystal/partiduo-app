# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    # Contrat du module Comptabilité — prévisions budgétaires (lot 6,
    # `forecast`, `Anticipation` d'origine) : prévisions sur une suite de
    # périodes, catégories, éléments (formule du réel, montant estimé par
    # période), copie, et comparaison de l'estimé et du réel. Référence :
    # `doc/api/accounting-forecasts.adoc`.
    #
    # Lecture : `accounting.report.read` ; écriture :
    # `accounting.report.write` (comme les rapports personnalisés,
    # D-FCT-001). Le réel ne lit que les journaux visibles de l'acteur.
    module Accounting
      # --- Entrées -------------------------------------------------------------------

      # Prévision : nom (255 caractères au plus), première et dernière
      # périodes du socle (`f_start_date`, `f_end_date`).
      record ForecastInput, name : String, start_period_id : Int64, end_period_id : Int64

      # Catégorie (`forecast_category`) : libellé, rang d'affichage.
      record ForecastCategoryInput, label : String, position : Int32 = 0

      # Montant estimé propre à une période de la prévision.
      record ForecastPeriodAmountInput, period_id : Int64, amount : BigDecimal

      # Élément (`forecast_item`) : libellé, formule du réel (syntaxe des
      # rapports, `[70%]-[709%]`, `{QCODE}`…), montant estimé de chaque
      # période, montant ajouté à la première période
      # (`fi_amount_initial`), rang, montants propres à certaines périodes
      # (remplacent `amount`, D-FCT-002).
      record ForecastItemInput,
        label : String,
        formula : String,
        amount : BigDecimal = BigDecimal.new(0),
        initial_amount : BigDecimal = BigDecimal.new(0),
        position : Int32 = 0,
        period_amounts : Array(ForecastPeriodAmountInput) = [] of ForecastPeriodAmountInput

      # --- Vues ------------------------------------------------------------------------

      record ForecastSummaryView,
        id : Int64,
        name : String,
        start_period_id : Int64,
        end_period_id : Int64,
        starts_on : Time,
        ends_on : Time

      record ForecastPeriodAmountView, period_id : Int64, amount : BigDecimal

      record ForecastItemView,
        id : Int64,
        category_id : Int64,
        label : String,
        formula : String,
        amount : BigDecimal,
        initial_amount : BigDecimal,
        position : Int32,
        period_amounts : Array(ForecastPeriodAmountView)

      record ForecastCategoryView, id : Int64, label : String, position : Int32, items : Array(ForecastItemView)

      record ForecastView, forecast : ForecastSummaryView, categories : Array(ForecastCategoryView) do
        def id : Int64
          forecast.id
        end

        def name : String
          forecast.name
        end
      end

      record ForecastPeriodRef, id : Int64, starts_on : Time, ends_on : Time

      # Estimé et réel d'un élément, une valeur par période de la prévision.
      record ForecastReportItemView,
        item_id : Int64,
        label : String,
        formula : String,
        estimated : Array(BigDecimal),
        real : Array(BigDecimal) do
        def estimated_total : BigDecimal
          estimated.sum(BigDecimal.new(0))
        end

        def real_total : BigDecimal
          real.sum(BigDecimal.new(0))
        end

        # Cumuls période après période (« Total estimé », « Total réel »).
        def estimated_cumulative : Array(BigDecimal)
          Accounting.cumulate(estimated)
        end

        def real_cumulative : Array(BigDecimal)
          Accounting.cumulate(real)
        end

        # Réel − estimé, par période.
        def differences : Array(BigDecimal)
          real.map_with_index { |amount, index| amount - estimated[index] }
        end
      end

      record ForecastReportCategoryView, category_id : Int64, label : String, items : Array(ForecastReportItemView) do
        def estimated : Array(BigDecimal)
          Accounting.column_sums(items.map(&.estimated))
        end

        def real : Array(BigDecimal)
          Accounting.column_sums(items.map(&.real))
        end
      end

      # `invalid_items` : libellés des éléments dont la formule ne se calcule
      # plus (réel à zéro, `Anticipation::display`).
      record ForecastReportView,
        forecast : ForecastSummaryView,
        periods : Array(ForecastPeriodRef),
        categories : Array(ForecastReportCategoryView),
        invalid_items : Array(String)

      def self.cumulate(values : Array(BigDecimal)) : Array(BigDecimal)
        total = BigDecimal.new(0)
        values.map { |value| total += value }
      end

      def self.column_sums(rows : Array(Array(BigDecimal))) : Array(BigDecimal)
        return [] of BigDecimal if rows.empty?
        Array.new(rows.first.size) { |index| rows.sum(BigDecimal.new(0)) { |row| row[index]? || BigDecimal.new(0) } }
      end

      # --- Prévisions --------------------------------------------------------------------

      def self.forecasts(actor : Actor) : Array(ForecastSummaryView)
        Guard.authorize!(actor, REPORT_READ, module_code: MODULE_CODE)
        Partiduo::Accounting::Forecast.all.order(:name, :id).to_a.map { |row| Partiduo::Accounting::Forecasts.summary(row) }
      end

      def self.forecast(actor : Actor, id : Int64) : ForecastView
        Guard.authorize!(actor, REPORT_READ, module_code: MODULE_CODE)
        Partiduo::Accounting::Forecasts.view(find_forecast(id))
      end

      def self.check_forecast(actor : Actor, input : ForecastInput) : Result(Nil)
        Guard.authorize!(actor, REPORT_WRITE, module_code: MODULE_CODE)
        errors = Partiduo::Accounting::Forecasts.forecast_errors(input)
        errors.empty? ? Result(Nil).success(nil) : Result(Nil).failure(errors)
      end

      def self.create_forecast(actor : Actor, input : ForecastInput) : Result(ForecastView)
        Guard.authorize!(actor, REPORT_WRITE, module_code: MODULE_CODE)
        Transaction.run do
          errors = Partiduo::Accounting::Forecasts.forecast_errors(input)
          next Result(ForecastView).failure(errors) unless errors.empty?
          forecast = Partiduo::Accounting::Forecast.create!(name: input.name.strip, start_period_id: input.start_period_id,
            end_period_id: input.end_period_id, created_by_id: actor.user_id)
          Result(ForecastView).success(Partiduo::Accounting::Forecasts.view(forecast))
        end
      end

      # Changer les périodes retire les montants propres aux périodes sorties
      # de la prévision.
      def self.update_forecast(actor : Actor, id : Int64, input : ForecastInput) : Result(ForecastView)
        Guard.authorize!(actor, REPORT_WRITE, module_code: MODULE_CODE)
        Transaction.run do
          forecast = find_forecast(id)
          errors = Partiduo::Accounting::Forecasts.forecast_errors(input)
          next Result(ForecastView).failure(errors) unless errors.empty?
          forecast.name = input.name.strip
          forecast.start_period_id = input.start_period_id
          forecast.end_period_id = input.end_period_id
          forecast.save!
          kept = Partiduo::Accounting::Forecasts.period_ids(forecast)
          category_ids = Partiduo::Accounting::ForecastCategory.filter(forecast_id: id).to_a.map(&.pk!)
          item_ids = Partiduo::Accounting::ForecastItem.filter(category_id__in: category_ids).to_a.map(&.pk!)
          unless item_ids.empty?
            stale = Partiduo::Accounting::ForecastAmount.filter(item_id__in: item_ids)
            stale = stale.exclude(period_id__in: kept) unless kept.empty?
            stale.delete
          end
          Result(ForecastView).success(Partiduo::Accounting::Forecasts.view(forecast))
        end
      end

      def self.delete_forecast(actor : Actor, id : Int64) : Result(Nil)
        Guard.authorize!(actor, REPORT_WRITE, module_code: MODULE_CODE)
        Transaction.run do
          find_forecast(id).delete
          Result(Nil).success(nil)
        end
      end

      # Copie complète sous le nom `name` (`Anticipation::object_clone`).
      def self.clone_forecast(actor : Actor, id : Int64, name : String) : Result(ForecastView)
        Guard.authorize!(actor, REPORT_WRITE, module_code: MODULE_CODE)
        Transaction.run do
          source = find_forecast(id)
          input = ForecastInput.new(name, source.start_period_id!.as(Int64), source.end_period_id!.as(Int64))
          errors = Partiduo::Accounting::Forecasts.forecast_errors(input)
          next Result(ForecastView).failure(errors) unless errors.empty?
          copy = Partiduo::Accounting::Forecasts.clone!(source, name, actor.user_id)
          Result(ForecastView).success(Partiduo::Accounting::Forecasts.view(copy))
        end
      end

      # --- Catégories ---------------------------------------------------------------------

      def self.create_forecast_category(actor : Actor, forecast_id : Int64,
                                        input : ForecastCategoryInput) : Result(ForecastCategoryView)
        Guard.authorize!(actor, REPORT_WRITE, module_code: MODULE_CODE)
        Transaction.run do
          forecast = find_forecast(forecast_id)
          errors = Partiduo::Accounting::Forecasts.category_errors(input)
          next Result(ForecastCategoryView).failure(errors) unless errors.empty?
          category = Partiduo::Accounting::ForecastCategory.create!(forecast: forecast, label: input.label.strip,
            position: input.position)
          Result(ForecastCategoryView).success(category_view(forecast, category.pk!.as(Int64)))
        end
      end

      def self.update_forecast_category(actor : Actor, id : Int64, input : ForecastCategoryInput) : Result(ForecastCategoryView)
        Guard.authorize!(actor, REPORT_WRITE, module_code: MODULE_CODE)
        Transaction.run do
          category = find_category(id)
          errors = Partiduo::Accounting::Forecasts.category_errors(input)
          next Result(ForecastCategoryView).failure(errors) unless errors.empty?
          category.label = input.label.strip
          category.position = input.position
          category.save!
          Result(ForecastCategoryView).success(category_view(category.forecast!, id))
        end
      end

      # Supprime la catégorie et ses éléments.
      def self.delete_forecast_category(actor : Actor, id : Int64) : Result(Nil)
        Guard.authorize!(actor, REPORT_WRITE, module_code: MODULE_CODE)
        Transaction.run do
          find_category(id).delete
          Result(Nil).success(nil)
        end
      end

      # --- Éléments ---------------------------------------------------------------------

      def self.check_forecast_item(actor : Actor, category_id : Int64, input : ForecastItemInput) : Result(Nil)
        Guard.authorize!(actor, REPORT_WRITE, module_code: MODULE_CODE)
        category = find_category(category_id)
        errors = Partiduo::Accounting::Forecasts.item_errors(category.forecast!, input)
        errors.empty? ? Result(Nil).success(nil) : Result(Nil).failure(errors)
      end

      def self.create_forecast_item(actor : Actor, category_id : Int64, input : ForecastItemInput) : Result(ForecastItemView)
        Guard.authorize!(actor, REPORT_WRITE, module_code: MODULE_CODE)
        Transaction.run do
          category = find_category(category_id)
          errors = Partiduo::Accounting::Forecasts.item_errors(category.forecast!, input)
          next Result(ForecastItemView).failure(errors) unless errors.empty?
          item = Partiduo::Accounting::Forecasts.save_item!(Partiduo::Accounting::ForecastItem.new(category: category), input)
          Result(ForecastItemView).success(item_view(category.forecast!, item.pk!.as(Int64)))
        end
      end

      # Remplace l'élément entier (montants par période compris).
      def self.update_forecast_item(actor : Actor, id : Int64, input : ForecastItemInput) : Result(ForecastItemView)
        Guard.authorize!(actor, REPORT_WRITE, module_code: MODULE_CODE)
        Transaction.run do
          item = Partiduo::Accounting::ForecastItem.filter(id: id).first || raise NotFound.new("forecast_item", id)
          forecast = item.category!.forecast!
          errors = Partiduo::Accounting::Forecasts.item_errors(forecast, input)
          next Result(ForecastItemView).failure(errors) unless errors.empty?
          Partiduo::Accounting::Forecasts.save_item!(item, input)
          Result(ForecastItemView).success(item_view(forecast, id))
        end
      end

      def self.delete_forecast_item(actor : Actor, id : Int64) : Result(Nil)
        Guard.authorize!(actor, REPORT_WRITE, module_code: MODULE_CODE)
        Transaction.run do
          item = Partiduo::Accounting::ForecastItem.filter(id: id).first || raise NotFound.new("forecast_item", id)
          item.delete
          Result(Nil).success(nil)
        end
      end

      # --- Estimé et réel ------------------------------------------------------------------

      def self.forecast_report(actor : Actor, id : Int64) : ForecastReportView
        Guard.authorize!(actor, REPORT_READ, module_code: MODULE_CODE)
        Partiduo::Accounting::Forecasts.report(find_forecast(id), readable_ledger_ids(actor))
      end

      # --- Interne ----------------------------------------------------------------------

      private def self.find_forecast(id : Int64) : Partiduo::Accounting::Forecast
        Partiduo::Accounting::Forecast.filter(id: id).first || raise NotFound.new("forecast", id)
      end

      private def self.find_category(id : Int64) : Partiduo::Accounting::ForecastCategory
        Partiduo::Accounting::ForecastCategory.filter(id: id).first || raise NotFound.new("forecast_category", id)
      end

      private def self.category_view(forecast : Partiduo::Accounting::Forecast, id : Int64) : ForecastCategoryView
        Partiduo::Accounting::Forecasts.view(forecast).categories.find!(&.id.==(id))
      end

      private def self.item_view(forecast : Partiduo::Accounting::Forecast, id : Int64) : ForecastItemView
        Partiduo::Accounting::Forecasts.view(forecast).categories.flat_map(&.items).find!(&.id.==(id))
      end
    end
  end
end
