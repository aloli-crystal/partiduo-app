# SPDX-License-Identifier: AGPL-3.0-or-later

require "digest/sha256"

module Partiduo
  module Liberal
    # Préparation de la 2035, de la 2035-A et de la 2035-B d'une année civile
    # (ADR-007 D6) depuis la ventilation du livre-journal par rubrique, le
    # registre des immobilisations et les réintégrations et déductions de
    # l'année ; lignes et cases lues dans la table de correspondance du
    # millésime ; contrôles de cohérence avant dépôt. Service interne.
    #
    # Montants en euros entiers (arrondi commercial) : chaque rubrique est
    # arrondie, les totaux se calculent sur les montants arrondis, comme sur
    # le formulaire (DECISIONS D-LIB-004).
    module TaxReturn
      alias Api = Partiduo::Api::Liberal

      # Postes dans l'ordre des formulaires.
      ORDER = %w[receipts disbursements fees_retroceded net_receipts financial_income other_gains total_receipts] +
              Api::EXPENSE_LINE_HEADINGS +
              %w[
                total_expenses excess short_term_gains reintegrations scm_profit total_additions shortfall
                establishment_costs depreciation provision short_term_losses deductions scm_loss total_subtractions
                profit loss assets_cost assets_prior_depreciation assets_year_depreciation disposals_price
                long_term_gains long_term_losses
              ]

      # Plus bas des plafonds d'amortissement des véhicules de tourisme
      # (émissions supérieures à 160 g de CO2 par km) ; les autres sont 18 300,
      # 20 300 et 30 000 euros.
      VEHICLE_CEILING = BigDecimal.new(9900)

      def self.zero : BigDecimal
        BigDecimal.new(0)
      end

      def self.euros(value : BigDecimal) : BigDecimal
        value.round(0, mode: :ties_away)
      end

      def self.prepare(year : Int32) : Api::TaxReturnView
        totals = Registers.heading_totals(year).index_by(&.heading)
        adjustments = Adjustment.filter(year: year).order(:id).to_a
        adjustment_views = Adjustments.views(adjustments)
        rows = Assets.depreciation(year)
        disposals = Assets.disposals(year)
        values = amounts(totals, adjustment_views, rows, disposals)

        mapping = FormLines.for_year(year)
        lines = ORDER.map do |item|
          found = mapping[item]?
          Api::TaxLineView.new(item, found.try(&.form.to_s) || default_form(item), found.try(&.line.to_s) || "",
            found.try(&.box.to_s) || "", values[item]? || zero, !found.nil?)
        end

        identity = identity()
        controls = controls(year, totals, lines, rows, identity)
        Api::TaxReturnView.new(year, identity, lines, rows, disposals, adjustment_views, controls,
          fingerprint(year, identity, lines))
      end

      private def self.default_form(item : String) : String
        item.in?(%w[assets_cost assets_prior_depreciation assets_year_depreciation disposals_price long_term_gains
          long_term_losses]) ? "2035-B" : "2035-A"
      end

      # Montants de chaque poste, en euros entiers.
      def self.amounts(totals : Hash(String, Api::HeadingTotalView), adjustments : Array(Api::AdjustmentView),
                       rows : Array(Api::DepreciationRowView),
                       disposals : Array(Api::DisposalResultView)) : Hash(String, BigDecimal)
        values = {} of String => BigDecimal
        (Api::HEADINGS - Api::EXCLUDED_HEADINGS).each do |heading|
          values[heading] = euros(totals[heading]?.try(&.amount) || zero)
        end
        by_kind = Api::ADJUSTMENT_KINDS.to_h do |kind|
          {kind, adjustments.select(&.kind.==(kind)).sum(zero, &.amount)}
        end
        nondeductible = totals.values.select(&.kind.==("expense")).sum(zero, &.nondeductible_amount)

        values["net_receipts"] = values["receipts"] - values["disbursements"] - values["fees_retroceded"]
        values["total_receipts"] = values["net_receipts"] + values["financial_income"] + values["other_gains"]
        values["total_expenses"] = Api::EXPENSE_LINE_HEADINGS.sum(zero) { |heading| values[heading] }
        difference = values["total_receipts"] - values["total_expenses"]
        values["excess"] = difference > 0 ? difference : zero
        values["shortfall"] = difference < 0 ? -difference : zero

        values["short_term_gains"] = euros(disposals.map(&.short_term).select(&.>(0)).sum(zero))
        values["short_term_losses"] = euros(-disposals.map(&.short_term).select(&.<(0)).sum(zero))
        values["long_term_gains"] = euros(disposals.map(&.long_term).select(&.>(0)).sum(zero))
        values["long_term_losses"] = euros(-disposals.map(&.long_term).select(&.<(0)).sum(zero))
        values["reintegrations"] = euros(by_kind["reintegration"] + nondeductible)
        values["deductions"] = euros(by_kind["deduction"])
        %w[scm_profit scm_loss establishment_costs provision].each { |kind| values[kind] = euros(by_kind[kind]) }
        values["depreciation"] = euros(rows.sum(zero, &.year_amount))

        values["total_additions"] = %w[excess short_term_gains reintegrations scm_profit].sum(zero) { |item| values[item] }
        values["total_subtractions"] = %w[shortfall establishment_costs depreciation provision short_term_losses
          deductions scm_loss].sum(zero) { |item| values[item] }
        result = values["total_additions"] - values["total_subtractions"]
        values["profit"] = result > 0 ? result : zero
        values["loss"] = result < 0 ? -result : zero

        values["assets_cost"] = euros(rows.sum(zero, &.amount))
        values["assets_prior_depreciation"] = euros(rows.sum(zero, &.prior))
        values["assets_year_depreciation"] = values["depreciation"]
        values["disposals_price"] = euros(disposals.sum(zero, &.price))
        values
      end

      def self.identity : Api::IdentityView
        settings = Registers.settings_view
        company = begin
          Partiduo::Api::Core.settings(Partiduo::Api::Actor.system)
        rescue Partiduo::Api::NotFound
          nil
        end
        Api::IdentityView.new(company.try(&.company_name) || "", company.try(&.siren.delete(' ')) || "",
          company.try(&.street) || "", company.try(&.street_number) || "", company.try(&.postcode) || "",
          company.try(&.city) || "", settings.profession, settings.activity_started_on)
      end

      # --- Contrôles ----------------------------------------------------------------------

      private def self.control(key : String, severity : String, params = {} of String => String) : Api::ControlView
        Api::ControlView.new("liberal.controls.#{key}", params, severity)
      end

      def self.controls(year : Int32, totals : Hash(String, Api::HeadingTotalView), lines : Array(Api::TaxLineView),
                        rows : Array(Api::DepreciationRowView), identity : Api::IdentityView) : Array(Api::ControlView)
        controls = [] of Api::ControlView
        controls << control("siren_missing", "error") unless identity.siren.matches?(/\A\d{9}\z/)
        controls << control("profession_missing", "warning") if identity.profession.strip.empty?
        controls.concat(amount_controls(year, totals, lines, rows))
        controls.concat(period_controls(year))
        controls
      end

      # Postes sans ligne ou sans case, cases en double, rubriques négatives,
      # amortissements, plafond des véhicules (DECISIONS D-LIB-011).
      def self.amount_controls(year : Int32, totals : Hash(String, Api::HeadingTotalView),
                               lines : Array(Api::TaxLineView), rows : Array(Api::DepreciationRowView)) : Array(Api::ControlView)
        controls = [] of Api::ControlView
        # Une ligne non nulle sans ligne de formulaire au millésime.
        # Une ligne située sans case ne serait pas transmise (`boxes`,
        # DECISIONS D-TST-L-002).
        lines.each do |line|
          next if line.amount.zero?
          if !line.mapped
            controls << control("mapping_missing", "error", {"item" => I18n.t(line.item_key), "year" => year.to_s})
          elsif line.box.strip.empty?
            controls << control("box_missing", "error", {"item" => I18n.t(line.item_key), "year" => year.to_s})
          end
        end

        # Rubrique négative : contre-passations supérieures aux lignes.
        totals.each_value do |total|
          next unless total.amount < 0
          controls << control("heading_negative", "error", {"heading" => I18n.t("liberal.headings.#{total.heading}")})
        end

        # Deux postes reportés dans la même case d'un formulaire : `boxes`
        # n'en transmettrait qu'un (la table a pu être modifiée sans passer
        # par `set_form_line`, ou avant ce contrôle).
        lines.select { |line| line.mapped && !line.box.strip.empty? }.group_by { |line| {line.form, line.box} }.each do |(form, box), same|
          next if same.size < 2
          controls << control("box_duplicate", "error", {"form" => form, "box" => box,
                                                         "items" => same.map { |line| I18n.t(line.item_key) }.join(", ")})
        end

        # Amortissements : jamais au-delà de la base.
        rows.each do |row|
          next unless row.cumulated > row.amount
          controls << control("asset_over_depreciated", "error", {"number" => row.number})
        end

        # Véhicule de tourisme : l'amortissement au-delà du plafond fiscal
        # n'est pas déductible ; le module ne connaît pas les émissions de
        # CO2, il signale une base au-dessus du plus bas des plafonds
        # (réintégration par un ajustement, DECISIONS D-LIB-012).
        rows.each do |row|
          next unless row.category == "vehicle" && row.year_amount > 0 && row.amount > VEHICLE_CEILING
          controls << control("vehicle_depreciation_ceiling", "warning",
            {"number" => row.number, "ceiling" => VEHICLE_CEILING.to_i.to_s})
        end

        controls << control("no_receipts", "warning") if totals.values.sum(0, &.count).zero?
        controls
      end

      # Année sans exercice ou pas encore close.
      def self.period_controls(year : Int32) : Array(Api::ControlView)
        controls = [] of Api::ControlView
        periods = Partiduo::Api::Core.periods(Partiduo::Api::Actor.system).select do |period|
          period.starts_on <= Time.utc(year, 12, 31) && period.ends_on >= Time.utc(year, 1, 1)
        end
        if periods.empty?
          controls << control("no_fiscal_year", "warning", {"year" => year.to_s})
        elsif !periods.all?(&.closed?)
          controls << control("year_open", "warning", {"year" => year.to_s})
        end
        controls
      end

      # Empreinte des montants reportés et de l'identification.
      def self.fingerprint(year : Int32, identity : Api::IdentityView, lines : Array(Api::TaxLineView)) : String
        text = String.build do |io|
          io << year << '|' << identity.siren << '|' << identity.profession << '|' << identity.company_name
          lines.each { |line| io << '|' << line.item << '=' << line.form << ':' << line.box << ':' << line.amount }
        end
        Digest::SHA256.hexdigest(text)
      end
    end
  end
end
