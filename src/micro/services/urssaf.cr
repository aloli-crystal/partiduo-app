# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Micro
    # Aide à la déclaration URSSAF, montants de la 2042-C-PRO et suivi des
    # seuils (ADR-007 D1), calculés depuis le livre des recettes et les
    # paramètres datés. Chiffre d'affaires = encaissé hors TVA, contre-
    # passations comprises à leur date. Service interne.
    module Urssaf
      alias Api = Partiduo::Api::Micro

      ZERO    = BigDecimal.new(0)
      HUNDRED = BigDecimal.new(100)

      GOODS_CATEGORIES    = %w[sale_bic]
      SERVICES_CATEGORIES = %w[service_bic bnc]

      # Chiffre d'affaires par catégorie entre deux dates incluses.
      def self.turnover(from : Time, to : Time) : Hash(String, BigDecimal)
        totals = Api::RECEIPT_CATEGORIES.to_h { |category| {category, ZERO} }
        Marten::DB::Connection.default.open do |db|
          db.query("SELECT category, coalesce(sum(amount - vat_amount), 0) FROM micro_receipt " \
                   "WHERE date >= $1::date AND date <= $2::date GROUP BY category",
            args: [from.to_s("%Y-%m-%d"), to.to_s("%Y-%m-%d")]) do |result_set|
            result_set.each { totals[result_set.read(String)] = result_set.read(BigDecimal) }
          end
        end
        totals
      end

      # Chiffre d'affaires de l'année par mois et par catégorie, en une
      # requête : {mois, catégorie} → montant.
      def self.monthly_turnover(year : Int32) : Hash({Int32, String}, BigDecimal)
        totals = {} of {Int32, String} => BigDecimal
        Marten::DB::Connection.default.open do |db|
          db.query("SELECT extract(month FROM date)::int, category, coalesce(sum(amount - vat_amount), 0) " \
                   "FROM micro_receipt WHERE date >= $1::date AND date <= $2::date GROUP BY 1, 2",
            args: ["#{year}-01-01", "#{year}-12-31"]) do |result_set|
            result_set.each do
              month = result_set.read(Int32)
              category = result_set.read(String)
              totals[{month, category}] = result_set.read(BigDecimal)
            end
          end
        end
        totals
      end

      # Chiffre d'affaires par catégorie d'une période de l'année, depuis
      # les totaux mensuels.
      def self.period_turnover(monthly : Hash({Int32, String}, BigDecimal), starts_on : Time,
                               ends_on : Time) : Hash(String, BigDecimal)
        Api::RECEIPT_CATEGORIES.to_h do |category|
          {category, (starts_on.month..ends_on.month).sum(ZERO) { |month| monthly[{month, category}]? || ZERO }}
        end
      end

      def self.cents(value : BigDecimal) : BigDecimal
        value.round(2, mode: :ties_away)
      end

      def self.end_of_month(year : Int32, month : Int32) : Time
        Time.utc(year, month, Time.days_in_month(year, month))
      end

      # --- Déclarations -------------------------------------------------------------

      # Périodes de déclaration de l'année selon la périodicité : {début, fin}.
      def self.periods(year : Int32, periodicity : String) : Array({Time, Time})
        step = periodicity == "monthly" ? 1 : 3
        (1..12).step(step).map do |month|
          {Time.utc(year, month, 1), end_of_month(year, month + step - 1)}
        end.to_a
      end

      # Échéance : dernier jour du mois qui suit la période.
      def self.due_on(ends_on : Time) : Time
        following = ends_on + 1.day
        end_of_month(following.year, following.month)
      end

      # Déclarations de l'année : une requête de chiffre d'affaires, une
      # lecture des paramètres et une des déclarations faites.
      def self.declarations(year : Int32, today : Time, settings : Settings = Registers.settings,
                            parameters : Parameters::Snapshot = Parameters::Snapshot.new) : Array(Api::DeclarationView)
        monthly = monthly_turnover(year)
        declared = Declaration.filter(starts_on__gte: Time.utc(year, 1, 1), starts_on__lte: Time.utc(year, 12, 31))
          .to_a.index_by(&.starts_on!)
        periods(year, settings.periodicity.to_s).map do |(starts_on, ends_on)|
          declaration(starts_on, ends_on, today, settings, parameters, period_turnover(monthly, starts_on, ends_on),
            declared[starts_on]?)
        end
      end

      def self.declaration(starts_on : Time, ends_on : Time, today : Time) : Api::DeclarationView
        declaration(starts_on, ends_on, today, Registers.settings, Parameters::Snapshot.new, turnover(starts_on, ends_on),
          Declaration.filter(starts_on: starts_on).first)
      end

      def self.declaration(starts_on : Time, ends_on : Time, today : Time, settings : Settings,
                           parameters : Parameters::Snapshot, turnover : Hash(String, BigDecimal),
                           declared : Declaration?) : Api::DeclarationView
        flat_tax = settings.flat_tax || false
        missing = [] of String
        # Taux en vigueur au début de la période.
        contributions = Api::RECEIPT_CATEGORIES.map do |category|
          base = turnover[category]
          social_rate = rate(parameters, "rate.social.#{category}", starts_on, missing)
          cfp_rate = rate(parameters, "rate.cfp.#{category}", starts_on, missing)
          flat_rate = flat_tax ? rate(parameters, "rate.flat_tax.#{category}", starts_on, missing) : nil
          Api::ContributionView.new(category, base, social_rate, apply(base, social_rate), cfp_rate, apply(base, cfp_rate),
            flat_rate, apply(base, flat_rate))
        end
        due = due_on(ends_on)
        status = if declared
                   "declared"
                 elsif today <= ends_on
                   "open"
                 elsif today <= due
                   "due"
                 else
                   "late"
                 end
        Api::DeclarationView.new(starts_on, ends_on, due, contributions, status, declared.try(&.declared_on),
          declared.try(&.reference.to_s) || "", missing.uniq)
      end

      private def self.rate(parameters : Parameters::Snapshot, code : String, on : Time,
                            missing : Array(String)) : BigDecimal?
        value = parameters.value(code, on)
        missing << code if value.nil?
        value
      end

      private def self.apply(base : BigDecimal, rate : BigDecimal?) : BigDecimal
        rate.nil? ? ZERO : cents(base * rate / HUNDRED)
      end

      # Période de déclaration qui commence le `starts_on`, selon la
      # périodicité ; `nil` si ce n'est pas un début de période.
      def self.period_starting(starts_on : Time) : {Time, Time}?
        periods(starts_on.year, Registers.settings.periodicity.to_s).find { |(from, _)| from == Registers.day(starts_on) }
      end

      # Première date à déclarer : le début d'activité, sinon la première
      # recette ; `nil` sans l'un ni l'autre.
      def self.first_day : Time?
        Registers.settings.activity_started_on || Receipt.all.order(:date).first.try(&.date)
      end

      # « À traiter » : déclarations dues ou en retard depuis le début
      # d'activité (à défaut, la première recette), mais pas avant le
      # 1er janvier de l'année précédente — une activité reprise dans le
      # module (début en 2015) ne produit pas des dizaines d'échéances « en
      # retard » que le registre ne peut pas renseigner (D-MIC-012) ;
      # alertes de seuil de l'année.
      def self.todo(today : Time) : Array(Api::TodoView)
        items = [] of Api::TodoView
        settings = Registers.settings
        parameters = Parameters::Snapshot.new
        if first = first_day
          start = Math.max(first, Time.utc(today.year - 1, 1, 1))
          (start.year..today.year).each do |year|
            declarations(year, today, settings, parameters).each do |declaration|
              next unless declaration.status.in?("due", "late")
              next if declaration.ends_on < start
              key = declaration.status == "late" ? "micro.todo.declaration_late" : "micro.todo.declaration_due"
              items << Api::TodoView.new("declaration", key, {
                "from"     => declaration.starts_on.to_s("%Y-%m-%d"),
                "to"       => declaration.ends_on.to_s("%Y-%m-%d"),
                "due_on"   => declaration.due_on.to_s("%Y-%m-%d"),
                "turnover" => declaration.turnover.to_s,
              }, declaration.due_on, declaration.status == "late" ? "gap" : "primary")
            end
          end
        end
        thresholds(today.year, settings, parameters).alerts.each do |alert|
          items << Api::TodoView.new("threshold", alert.key, alert.params, nil, "gap")
        end
        items
      end

      # --- 2042-C-PRO ---------------------------------------------------------------

      # Chiffre d'affaires annuel par catégorie, en euros entiers, avec la
      # case du millésime (paramètre `box.<catégorie>` ou
      # `box.flat_tax.<catégorie>` en vigueur au 31 décembre).
      def self.tax_return(year : Int32) : Api::TaxReturnView
        flat_tax = Registers.settings.flat_tax || false
        year_end = Time.utc(year, 12, 31)
        totals = turnover(Time.utc(year, 1, 1), year_end)
        boxes = Api::RECEIPT_CATEGORIES.map do |category|
          code = flat_tax ? "box.flat_tax.#{category}" : "box.#{category}"
          Api::TaxBoxView.new(category, Parameters.text(code, year_end) || "", totals[category].round(0, mode: :ties_away))
        end
        Api::TaxReturnView.new(year, flat_tax, boxes)
      end

      # --- Seuils -------------------------------------------------------------------

      # Seuils de l'année (en vigueur au 1er janvier) : franchise en base de
      # TVA (seuil et seuil majoré) et régime micro (proratisé l'année du
      # début d'activité). Activité mixte : le seuil « marchandises » se
      # compare au chiffre d'affaires total, le seuil « services » aux seules
      # prestations.
      def self.thresholds(year : Int32, settings : Settings = Registers.settings,
                          parameters : Parameters::Snapshot = Parameters::Snapshot.new) : Api::ThresholdsView
        start = Time.utc(year, 1, 1)
        totals = turnover(start, Time.utc(year, 12, 31))
        goods = GOODS_CATEGORIES.sum(ZERO) { |category| totals[category] }
        services = SERVICES_CATEGORIES.sum(ZERO) { |category| totals[category] }
        alert_ratio = parameters.value("alert.ratio", start)
        prorata = prorata(settings.activity_started_on, year)
        vat_done = settings.vat_liable_since.try { |since| since.year <= year } || false
        real_done = settings.real_regime_since.try { |since| since.year <= year } || false

        views = [] of Api::ThresholdView
        alerts = [] of Api::AlertView
        {"goods" => goods + services, "services" => services}.each do |scope, amount|
          vat = threshold("vat", scope, amount, parameters.value("threshold.vat.#{scope}", start),
            parameters.value("threshold.vat_tolerance.#{scope}", start), alert_ratio, vat_done)
          micro_limit = parameters.value("threshold.micro.#{scope}", start).try { |limit| (limit * prorata).round(0, mode: :ties_away) }
          micro = threshold("micro", scope, amount, micro_limit, nil, alert_ratio, real_done)
          {vat, micro}.each do |view|
            views << view
            next unless view.status.in?("approaching", "exceeded", "tolerance_exceeded")
            alerts << Api::AlertView.new("micro.alerts.#{view.kind}.#{view.status}", {
              "scope"    => scope,
              "turnover" => view.turnover.to_s,
              "limit"    => view.limit.to_s,
              "ratio"    => view.ratio.to_s,
            })
          end
        end
        Api::ThresholdsView.new(year, goods, services, views, alerts)
      end

      private def self.threshold(kind : String, scope : String, amount : BigDecimal, limit : BigDecimal?,
                                 tolerance : BigDecimal?, alert_ratio : BigDecimal?, done : Bool) : Api::ThresholdView
        ratio = limit.try { |value| value > 0 ? (amount * HUNDRED / value).round(1, mode: :ties_away) : nil }
        status = if done
                   "not_applicable"
                 elsif limit.nil?
                   "unknown"
                 elsif tolerance && amount > tolerance
                   "tolerance_exceeded"
                 elsif amount > limit
                   "exceeded"
                 elsif alert_ratio && ratio && ratio >= alert_ratio
                   "approaching"
                 else
                   "ok"
                 end
        Api::ThresholdView.new(kind, scope, amount, limit, tolerance, ratio, status)
      end

      # Part de l'année d'activité l'année du début (jours d'activité ÷ jours
      # de l'année) ; 1 les autres années.
      def self.prorata(started_on : Time?, year : Int32) : BigDecimal
        return BigDecimal.new(1) if started_on.nil? || started_on.year != year
        days = Time.utc(year, 12, 31) - Time.utc(year, 1, 1)
        total = days.days + 1
        active = (Time.utc(year, 12, 31) - Registers.day(started_on)).days + 1
        BigDecimal.new(active) / BigDecimal.new(total)
      end
    end
  end
end
