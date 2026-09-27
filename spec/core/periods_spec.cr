# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias Api = Partiduo::Api::Core
private alias R = ReferentialSpec

private def d(text : String) : Time
  R.date(text)
end

private def writer : Partiduo::Api::Actor
  actor_with("core.fiscal_year.write", "core.period.close", "core.period.reopen")
end

private def db_exec(sql : String, *args) : Nil
  Marten::DB::Connection.default.open(&.exec(sql, *args))
end

describe "Partiduo::Api::Core — exercices et périodes" do
  describe ".create_fiscal_year" do
    it "découpe l'exercice en périodes mensuelles (Periode::insert_exercice)" do
      view = Api.create_fiscal_year(writer, Api::FiscalYearInput.new(year: 2026, start_year: 2026)).value!
      view.label.should eq("2026")
      view.periods.size.should eq(12)
      view.starts_on.should eq(d("2026-01-01"))
      view.ends_on.should eq(d("2026-12-31"))
      view.periods[1].starts_on.should eq(d("2026-02-01"))
      view.periods[1].ends_on.should eq(d("2026-02-28"))
      view.closed?.should be_false
    end

    it "commence en cours d'année et déborde sur l'année suivante" do
      view = R.fiscal_year(2026, start_year: 2026, start_month: 7, months: 18, label: "2026-2027")
      view.periods.size.should eq(18)
      view.starts_on.should eq(d("2026-07-01"))
      view.ends_on.should eq(d("2027-12-31"))
    end

    it "isole les jours d'ouverture et de clôture" do
      view = R.fiscal_year(2026, opening_period: true, closing_period: true)
      view.periods.size.should eq(14)
      view.periods.first.single_day?.should be_true
      view.periods.first.starts_on.should eq(d("2026-01-01"))
      view.periods[1].starts_on.should eq(d("2026-01-02"))
      view.periods[-2].ends_on.should eq(d("2026-12-30"))
      view.periods.last.single_day?.should be_true
      view.periods.last.starts_on.should eq(d("2026-12-31"))
    end

    it "contrôle les paramètres comme insert_exercice" do
      result = Api.create_fiscal_year(writer, Api::FiscalYearInput.new(year: 1800, start_year: 2026, start_month: 13, months: 61))
      result.error_keys.should eq([
        "core.errors.fiscal_year.year.out_of_range",
        "core.errors.fiscal_year.start_month.invalid",
        "core.errors.fiscal_year.months.out_of_range",
      ])
      R.expect_translated(result)
    end

    it "refuse un exercice ou un libellé déjà pris (check_periode)" do
      R.fiscal_year(2026, label: "Exercice 2026")
      result = Api.create_fiscal_year(writer, Api::FiscalYearInput.new(year: 2026, start_year: 2027))
      result.error_keys.should eq(["core.errors.fiscal_year.year.taken"])
      result = Api.create_fiscal_year(writer, Api::FiscalYearInput.new(year: 2027, start_year: 2027, label: "exercice 2026"))
      result.error_keys.should eq(["core.errors.fiscal_year.label.taken"])
      R.expect_translated(result)
    end

    it "refuse des périodes qui chevauchent un exercice existant" do
      R.fiscal_year(2026)
      result = Api.create_fiscal_year(writer, Api::FiscalYearInput.new(year: 2027, start_year: 2026, start_month: 12))
      result.error_keys.should eq(["core.errors.period.overlap"])
      result.errors.first.params.should eq({"starts_on" => "2026-12-01", "ends_on" => "2026-12-31"})
      Api.fiscal_years(writer).size.should eq(1)
    end

    it "exige la permission core.fiscal_year.write" do
      expect_raises(Partiduo::Api::Forbidden) do
        Api.create_fiscal_year(actor_with, Api::FiscalYearInput.new(year: 2026, start_year: 2026))
      end
    end

    it "offre une requête de contrôle" do
      Api.check_fiscal_year(writer, Api::FiscalYearInput.new(year: 2026, start_year: 2026)).success?.should be_true
      Api.fiscal_years(writer).should be_empty
    end
  end

  describe ".add_period (Periode::insert, periodeTest::testInsert)" do
    it "ajoute une période libre à un exercice" do
      year = R.fiscal_year(2023, months: 1)
      period = Api.add_period(writer, Api::PeriodInput.new(year.id, d("2023-02-01"), d("2023-02-28"))).value!
      period.fiscal_year_label.should eq("2023")
      Api.fiscal_year(writer, year.id).periods.size.should eq(2)
    end

    it "refuse le chevauchement et les bornes inversées" do
      year = R.fiscal_year(2023, months: 1)
      overlap = Api.add_period(writer, Api::PeriodInput.new(year.id, d("2023-01-31"), d("2023-02-28")))
      overlap.error_keys.should eq(["core.errors.period.overlap"])
      inverted = Api.add_period(writer, Api::PeriodInput.new(year.id, d("2023-02-01"), d("2023-01-28")))
      inverted.error_keys.should eq(["core.errors.period.ends_on.before_start"])
      R.expect_translated(overlap)
      R.expect_translated(inverted)
    end

    it "ignore l'heure des dates saisies" do
      year = R.fiscal_year(2023, months: 1)
      period = Api.add_period(writer, Api::PeriodInput.new(year.id, Time.utc(2023, 2, 1, 15, 30), Time.utc(2023, 2, 28, 8, 0))).value!
      period.starts_on.should eq(d("2023-02-01"))
      period.ends_on.should eq(d("2023-02-28"))
    end
  end

  describe "recherche de période" do
    it "trouve la période d'une date (find_periode) et la période courante" do
      R.fiscal_year(2026)
      R.present(Api.period_for(actor_with, d("2026-03-15"))).starts_on.should eq(d("2026-03-01"))
      Api.period_for(actor_with, d("2027-01-01")).should be_nil
      R.present(Api.current_period(actor_with, d("2026-05-10"))).starts_on.should eq(d("2026-05-01"))
      # Hors de tout exercice : la dernière période ouverte déjà commencée.
      R.present(Api.current_period(actor_with, d("2027-06-01"))).starts_on.should eq(d("2026-12-01"))
      # Avant tout exercice : la première période ouverte.
      R.present(Api.current_period(actor_with, d("2020-06-01"))).starts_on.should eq(d("2026-01-01"))
    end

    it "liste les périodes ouvertes d'un exercice" do
      year = R.fiscal_year(2026)
      Api.close_period(writer, year.periods.first.id).success?.should be_true
      Api.periods(actor_with, year.id, open_only: true).size.should eq(11)
      Api.periods(actor_with).size.should eq(12)
    end

    it "signale une période inconnue" do
      expect_raises(Partiduo::Api::NotFound) { Api.period(actor_with, 999_999_i64) }
    end
  end

  describe "clôture" do
    it "clôt une période et publie period.closed" do
      year = R.fiscal_year(2026)
      R.capture_events("period.closed") do |events|
        view = Api.close_period(writer, year.periods.first.id).value!
        view.closed?.should be_true
        events.map(&.["period_id"]).should eq([year.periods.first.id.to_s])
        events.first.actor_user_id.should eq(1_i64)
      end
      Api.close_period(writer, year.periods.first.id).error_keys.should eq(["core.errors.period.already_closed"])
    end

    it "rouvre une période close (Periode::reopen)" do
      year = R.fiscal_year(2026)
      period = year.periods.first
      Api.close_period(writer, period.id)
      Api.reopen_period(writer, period.id).value!.closed?.should be_false
      Api.reopen_period(writer, period.id).error_keys.should eq(["core.errors.period.not_closed"])
    end

    it "clôt un exercice : toutes ses périodes, puis plus de réouverture ni d'ajout" do
      year = R.fiscal_year(2026)
      Api.close_period(writer, year.periods.first.id)
      view = Api.close_fiscal_year(writer, year.id).value!
      view.closed?.should be_true
      view.periods.all?(&.closed?).should be_true

      Api.reopen_period(writer, year.periods.first.id).error_keys.should eq(["core.errors.period.fiscal_year_closed"])
      Api.close_fiscal_year(writer, year.id).error_keys.should eq(["core.errors.fiscal_year.already_closed"])
      added = Api.add_period(writer, Api::PeriodInput.new(year.id, d("2027-01-01"), d("2027-01-31")))
      added.error_keys.should eq(["core.errors.period.fiscal_year_closed"])
    end

    it "sépare les droits de clôture et de réouverture" do
      year = R.fiscal_year(2026)
      expect_raises(Partiduo::Api::Forbidden) { Api.close_period(actor_with("core.fiscal_year.write"), year.periods.first.id) }
      Api.close_period(actor_with("core.period.close"), year.periods.first.id).success?.should be_true
      expect_raises(Partiduo::Api::Forbidden) { Api.reopen_period(actor_with("core.period.close"), year.periods.first.id) }
    end
  end

  describe "suppression (Periode::verify_delete)" do
    it "supprime une période ouverte, pas une période close" do
      year = R.fiscal_year(2026, months: 2)
      Api.delete_period(writer, year.periods.last.id).success?.should be_true
      Api.close_period(writer, year.periods.first.id)
      Api.delete_period(writer, year.periods.first.id).error_keys.should eq(["core.errors.period.closed"])
    end

    it "refuse de supprimer une période citée par un module" do
      year = R.fiscal_year(2026, months: 1)
      db_exec("CREATE TABLE spec_period_ref (id bigserial PRIMARY KEY, period_id bigint REFERENCES core_period (id))")
      begin
        db_exec("INSERT INTO spec_period_ref (period_id) VALUES ($1)", year.periods.first.id)
        result = Api.delete_period(writer, year.periods.first.id)
        result.error_keys.should eq(["core.errors.period.in_use"])
        Api.delete_fiscal_year(writer, year.id).error_keys.should eq(["core.errors.fiscal_year.in_use"])
        Api.fiscal_year(writer, year.id).periods.size.should eq(1)
      ensure
        db_exec("DROP TABLE spec_period_ref")
      end
    end

    it "supprime un exercice ouvert et ses périodes" do
      year = R.fiscal_year(2026)
      Api.delete_fiscal_year(writer, year.id).success?.should be_true
      Api.fiscal_years(writer).should be_empty
      Api.periods(writer).should be_empty
    end
  end

  describe "contraintes en base" do
    it "refuse deux périodes qui se chevauchent, quel que soit le code qui écrit" do
      year = R.fiscal_year(2026, months: 1)
      expect_raises(Exception, /core_period_no_overlap/) do
        db_exec("INSERT INTO core_period (fiscal_year_id, starts_on, ends_on, created_at, updated_at) " \
                "VALUES ($1, '2026-01-15', '2026-02-15', now(), now())", year.id)
      end
    end

    it "refuse de modifier ou de supprimer une période close" do
      year = R.fiscal_year(2026, months: 1)
      period = year.periods.first
      Api.close_period(writer, period.id)
      expect_raises(Exception, /close/) do
        db_exec("UPDATE core_period SET ends_on = '2026-01-20' WHERE id = $1", period.id)
      end
      expect_raises(Exception, /close/) do
        db_exec("DELETE FROM core_period WHERE id = $1", period.id)
      end
    end

    it "refuse de déplacer une période ouverte vers un exercice clos, ou d'en sortir une" do
      open_year = R.fiscal_year(2026, months: 1)
      closed_year = R.fiscal_year(2025, months: 1)
      Api.close_fiscal_year(writer, closed_year.id).success?.should be_true
      expect_raises(Exception, /exercice clos/) do
        db_exec("UPDATE core_period SET fiscal_year_id = $1 WHERE id = $2", closed_year.id, open_year.periods.first.id)
      end
    end

    it "trouve la période d'une date en SQL (core_period_for)" do
      year = R.fiscal_year(2026, months: 1)
      id = Marten::DB::Connection.default.open { |db| db.scalar("SELECT core_period_for('2026-01-10')") }
      id.should eq(year.periods.first.id)
    end
  end
end
