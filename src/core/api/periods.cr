# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    # Contrat du socle — exercices et périodes (ADR-006 D1), successeurs de
    # `parm_periode`. Toute lecture est ouverte aux utilisateurs authentifiés
    # (choix de la période de saisie, en-têtes des éditions) ; la création,
    # la clôture et la réouverture ont leurs permissions.
    #
    # Les dates sont des `Time` à minuit UTC (convention C1) ; une heure
    # éventuelle est ignorée.
    module Core
      # Création d'un exercice découpé en périodes mensuelles
      # (`Periode::insert_exercice`). `label` vide : le numéro d'exercice.
      record FiscalYearInput,
        year : Int32,
        start_year : Int32,
        start_month : Int32 = 1,
        months : Int32 = 12,
        label : String? = nil,
        opening_period : Bool = false,
        closing_period : Bool = false

      # Ajout d'une période à un exercice ouvert (`Periode::insert`).
      record PeriodInput, fiscal_year_id : Int64, starts_on : Time, ends_on : Time

      record PeriodView,
        id : Int64,
        fiscal_year_id : Int64,
        fiscal_year_label : String,
        starts_on : Time,
        ends_on : Time,
        closed_at : Time? do
        def closed? : Bool
          !closed_at.nil?
        end

        def includes?(day : Time) : Bool
          starts_on <= day <= ends_on
        end

        # Période d'un seul jour (ouverture ou clôture).
        def single_day? : Bool
          starts_on == ends_on
        end
      end

      record FiscalYearView,
        id : Int64,
        year : Int32,
        label : String,
        closed_at : Time?,
        periods : Array(PeriodView) do
        def closed? : Bool
          !closed_at.nil?
        end

        def starts_on : Time?
          periods.first?.try(&.starts_on)
        end

        def ends_on : Time?
          periods.last?.try(&.ends_on)
        end

        def open_periods : Array(PeriodView)
          periods.reject(&.closed?)
        end
      end

      # Exercices, du plus récent au plus ancien, avec leurs périodes.
      def self.fiscal_years(actor : Actor) : Array(FiscalYearView)
        Guard.authorize!(actor, nil)
        years = Partiduo::Core::FiscalYear.all.order("-year").to_a
        periods = Partiduo::Core::Period.all.order(:starts_on).to_a.group_by(&.fiscal_year_id!.as(Int).to_i64)
        years.map { |year| fiscal_year_view(year, periods[year.id!.to_i64]? || [] of Partiduo::Core::Period) }
      end

      def self.fiscal_year(actor : Actor, id : Int64) : FiscalYearView
        Guard.authorize!(actor, nil)
        fiscal_year_view(find_fiscal_year(id))
      end

      # Périodes, dans l'ordre chronologique ; d'un seul exercice si
      # `fiscal_year_id` est donné, ouvertes seulement si `open_only`.
      def self.periods(actor : Actor, fiscal_year_id : Int64? = nil, open_only : Bool = false) : Array(PeriodView)
        Guard.authorize!(actor, nil)
        query = Partiduo::Core::Period.all.join(:fiscal_year)
        query = query.filter(fiscal_year_id: fiscal_year_id) if fiscal_year_id
        query = query.filter(closed_at__isnull: true) if open_only
        query.order(:starts_on).map { |period| period_view(period) }
      end

      def self.period(actor : Actor, id : Int64) : PeriodView
        Guard.authorize!(actor, nil)
        period_view(find_period(id))
      end

      # Période qui contient `day` (`Periode::find_periode`), ou `nil`.
      def self.period_for(actor : Actor, day : Time) : PeriodView?
        Guard.authorize!(actor, nil)
        Partiduo::Core::Periods.containing(Partiduo::Core::Periods.date(day)).try { |period| period_view(period) }
      end

      # Période courante : celle qui contient `today` ; à défaut, la dernière
      # période ouverte commencée avant `today` ; à défaut, la première période
      # ouverte ; `nil` s'il n'y en a aucune.
      def self.current_period(actor : Actor, today : Time = Time.utc) : PeriodView?
        Guard.authorize!(actor, nil)
        day = Partiduo::Core::Periods.date(today)
        period = Partiduo::Core::Periods.containing(day) ||
                 Partiduo::Core::Period.filter(closed_at__isnull: true, starts_on__lte: day).order("-starts_on").first ||
                 Partiduo::Core::Period.filter(closed_at__isnull: true).order(:starts_on).first
        period.try { |found| period_view(found) }
      end

      # Requête de contrôle de `create_fiscal_year`.
      def self.check_fiscal_year(actor : Actor, input : FiscalYearInput) : Result(Nil)
        Guard.authorize!(actor, "core.fiscal_year.write")
        errors = Partiduo::Core::Periods.fiscal_year_errors(input)
        errors.empty? ? Result(Nil).success(nil) : Result(Nil).failure(errors)
      end

      # Crée un exercice et ses périodes mensuelles.
      def self.create_fiscal_year(actor : Actor, input : FiscalYearInput) : Result(FiscalYearView)
        Guard.authorize!(actor, "core.fiscal_year.write")
        Transaction.run do
          # Sérialise les créations : le contrôle de chevauchement et d'unicité
          # vaut pour la transaction entière.
          lock_periods
          errors = Partiduo::Core::Periods.fiscal_year_errors(input)
          next Result(FiscalYearView).failure(errors) unless errors.empty?

          fiscal_year = Partiduo::Core::FiscalYear.create!(year: input.year,
            label: Partiduo::Core::Periods.label_of(input))
          Partiduo::Core::Periods.monthly_bounds(input.start_year, input.start_month, input.months,
            input.opening_period, input.closing_period).each do |bounds|
            Partiduo::Core::Period.create!(fiscal_year: fiscal_year, starts_on: bounds.starts_on, ends_on: bounds.ends_on)
          end
          Result(FiscalYearView).success(fiscal_year_view(fiscal_year))
        end
      end

      # Ajoute une période à un exercice ouvert, sans chevauchement.
      def self.add_period(actor : Actor, input : PeriodInput) : Result(PeriodView)
        Guard.authorize!(actor, "core.fiscal_year.write")
        Transaction.run do
          lock_periods
          fiscal_year = find_fiscal_year(input.fiscal_year_id)
          starts_on = Partiduo::Core::Periods.date(input.starts_on)
          ends_on = Partiduo::Core::Periods.date(input.ends_on)
          errors = Partiduo::Core::Periods.period_errors(fiscal_year, starts_on, ends_on)
          next Result(PeriodView).failure(errors) unless errors.empty?

          period = Partiduo::Core::Period.create!(fiscal_year: fiscal_year, starts_on: starts_on, ends_on: ends_on)
          Result(PeriodView).success(period_view(period))
        end
      end

      # Supprime une période ouverte que rien ne cite (`Periode::verify_delete` :
      # une période qui porte des écritures ne se supprime pas).
      def self.delete_period(actor : Actor, id : Int64) : Result(Nil)
        Guard.authorize!(actor, "core.fiscal_year.write")
        Transaction.run do
          period = Partiduo::Core::Period.all.lock.filter(id: id).first || raise NotFound.new("period", id)
          if period.closed?
            next Result(Nil).failure(Partiduo::Core::Periods.error(FieldError::BASE, "period", "closed"))
          end
          deleted = Partiduo::Core::Db.delete_unless_referenced([
            {"DELETE FROM core_period WHERE id = $1", [id] of ::DB::Any},
          ])
          next Result(Nil).failure(Partiduo::Core::Periods.error(FieldError::BASE, "period", "in_use")) unless deleted
          Result(Nil).success(nil)
        end
      end

      # Supprime un exercice ouvert, avec ses périodes, si aucune n'est close
      # ni citée.
      def self.delete_fiscal_year(actor : Actor, id : Int64) : Result(Nil)
        Guard.authorize!(actor, "core.fiscal_year.write")
        Transaction.run do
          fiscal_year = Partiduo::Core::FiscalYear.all.lock.filter(id: id).first || raise NotFound.new("fiscal_year", id)
          if fiscal_year.closed_at || Partiduo::Core::Period.filter(fiscal_year_id: id, closed_at__isnull: false).exists?
            next Result(Nil).failure(Partiduo::Core::Periods.error(FieldError::BASE, "fiscal_year", "closed"))
          end
          deleted = Partiduo::Core::Db.delete_unless_referenced([
            {"DELETE FROM core_period WHERE fiscal_year_id = $1", [id] of ::DB::Any},
            {"DELETE FROM core_fiscal_year WHERE id = $1", [id] of ::DB::Any},
          ])
          next Result(Nil).failure(Partiduo::Core::Periods.error(FieldError::BASE, "fiscal_year", "in_use")) unless deleted
          Result(Nil).success(nil)
        end
      end

      # Clôt une période (`Periode::close`) et publie `period.closed`. Les
      # modules qui la citent (écritures, factures) refusent ensuite toute
      # saisie à une date de cette période.
      def self.close_period(actor : Actor, id : Int64) : Result(PeriodView)
        Guard.authorize!(actor, "core.period.close")
        Transaction.run do
          period = Partiduo::Core::Period.all.lock.filter(id: id).first || raise NotFound.new("period", id)
          if period.closed?
            next Result(PeriodView).failure(Partiduo::Core::Periods.error(FieldError::BASE, "period", "already_closed"))
          end
          close!(period, actor)
          Result(PeriodView).success(period_view(period))
        end
      end

      # Rouvre une période close (`Periode::reopen`), sauf si son exercice est
      # clos.
      def self.reopen_period(actor : Actor, id : Int64) : Result(PeriodView)
        Guard.authorize!(actor, "core.period.reopen")
        Transaction.run do
          period = Partiduo::Core::Period.all.lock.filter(id: id).first || raise NotFound.new("period", id)
          errors = [] of FieldError
          errors << Partiduo::Core::Periods.error(FieldError::BASE, "period", "not_closed") unless period.closed?
          if period.fiscal_year!.closed_at
            errors << Partiduo::Core::Periods.error(FieldError::BASE, "period", "fiscal_year_closed")
          end
          next Result(PeriodView).failure(errors) unless errors.empty?

          period.closed_at = nil
          period.closed_by_id = nil
          period.save!
          Result(PeriodView).success(period_view(period))
        end
      end

      # Clôt un exercice : chacune de ses périodes encore ouvertes est close
      # (un événement `period.closed` par période), puis l'exercice.
      def self.close_fiscal_year(actor : Actor, id : Int64) : Result(FiscalYearView)
        Guard.authorize!(actor, "core.period.close")
        Transaction.run do
          fiscal_year = Partiduo::Core::FiscalYear.all.lock.filter(id: id).first || raise NotFound.new("fiscal_year", id)
          errors = [] of FieldError
          errors << Partiduo::Core::Periods.error(FieldError::BASE, "fiscal_year", "already_closed") if fiscal_year.closed_at
          periods = Partiduo::Core::Period.all.lock.filter(fiscal_year_id: id).order(:starts_on).to_a
          errors << Partiduo::Core::Periods.error(FieldError::BASE, "fiscal_year", "no_period") if periods.empty?
          next Result(FiscalYearView).failure(errors) unless errors.empty?

          periods.reject(&.closed?).each { |period| close!(period, actor) }
          fiscal_year.closed_at = Time.utc
          fiscal_year.closed_by_id = actor.user_id
          fiscal_year.save!
          Result(FiscalYearView).success(fiscal_year_view(fiscal_year))
        end
      end

      private def self.close!(period : Partiduo::Core::Period, actor : Actor) : Nil
        period.closed_at = Time.utc
        period.closed_by_id = actor.user_id
        period.save!
        Partiduo::Events.publish("period.closed", {"period_id" => period.id!.to_i64.to_s}, actor_user_id: actor.user_id)
      end

      # Verrou transactionnel qui sérialise les créations de périodes (le
      # chevauchement est aussi refusé par la contrainte d'exclusion).
      private def self.lock_periods : Nil
        Marten::DB::Connection.default.open do |db|
          db.exec("SELECT pg_advisory_xact_lock(hashtext('core_period'))")
        end
      end

      private def self.find_fiscal_year(id : Int64) : Partiduo::Core::FiscalYear
        Partiduo::Core::FiscalYear.filter(id: id).first || raise NotFound.new("fiscal_year", id)
      end

      private def self.find_period(id : Int64) : Partiduo::Core::Period
        Partiduo::Core::Period.all.join(:fiscal_year).filter(id: id).first || raise NotFound.new("period", id)
      end

      private def self.fiscal_year_view(fiscal_year : Partiduo::Core::FiscalYear,
                                        periods : Array(Partiduo::Core::Period)? = nil) : FiscalYearView
        periods ||= Partiduo::Core::Period.filter(fiscal_year_id: fiscal_year.id).order(:starts_on).to_a
        FiscalYearView.new(
          id: fiscal_year.id!.to_i64,
          year: fiscal_year.year!.to_i32,
          label: fiscal_year.label!,
          closed_at: fiscal_year.closed_at,
          periods: periods.map { |period| period_view(period, fiscal_year) },
        )
      end

      private def self.period_view(period : Partiduo::Core::Period,
                                   fiscal_year : Partiduo::Core::FiscalYear? = nil) : PeriodView
        fiscal_year ||= period.fiscal_year!
        PeriodView.new(
          id: period.id!.to_i64,
          fiscal_year_id: fiscal_year.id!.to_i64,
          fiscal_year_label: fiscal_year.label!,
          starts_on: period.starts_on!,
          ends_on: period.ends_on!,
          closed_at: period.closed_at,
        )
      end
    end
  end
end
