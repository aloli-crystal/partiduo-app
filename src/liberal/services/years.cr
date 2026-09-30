# SPDX-License-Identifier: AGPL-3.0-or-later

require "log"

module Partiduo
  module Liberal
    # Exercices du module (DECISIONS D-LIB2-001, D-LIB2-003) : l'exercice
    # d'une ligne est l'année civile de sa date, celle de la 2035. Il est
    # *ouvert* — ses lignes se modifient et se suppriment — jusqu'au premier
    # de deux événements, qui le *figent* :
    #
    # * sa clôture au socle (`close_fiscal_year`, ou toutes les périodes qui
    #   couvrent l'année closes) : lue sur les périodes du socle ;
    # * la transmission de sa 2035 (`tax_return.transmitted`, publié par
    #   l'extension qui la transmet ; `tax_return.rejected` la retire si le
    #   dépôt est rejeté) : notée dans `liberal_year`.
    #
    # Plusieurs exercices sont ouverts en même temps (l'année N se saisit
    # pendant que N-1 s'achève). Au figement, l'empreinte de la 2035 est
    # gardée (`frozen_fingerprint`) : un écart ultérieur (identification
    # changée) est signalé par un contrôle. Une période close du socle au
    # milieu d'un exercice ouvert fige les lignes de cette période seulement.
    # Service interne.
    module Years
      Log = ::Log.for("partiduo.liberal")

      alias Api = Partiduo::Api::Liberal

      FORM = "2035"

      def self.system : Partiduo::Api::Actor
        Partiduo::Api::Actor.system
      end

      def self.periods : Array(Partiduo::Api::Core::PeriodView)
        Partiduo::Api::Core.periods(system)
      end

      # Clôture de l'année au socle : toutes les périodes qui la couvrent
      # sont closes (au moins une) ; date de la dernière clôture, `nil` sinon.
      def self.closed_at(year : Int32, list : Array(Partiduo::Api::Core::PeriodView) = periods) : Time?
        from, to = Time.utc(year, 1, 1), Time.utc(year, 12, 31)
        covering = list.select { |period| period.starts_on <= to && period.ends_on >= from }
        return if covering.empty? || !covering.all?(&.closed?)
        covering.compact_map(&.closed_at).max?
      end

      def self.row(year : Int32) : Year?
        Year.filter(year: year).first
      end

      # Années dont la 2035 est transmise.
      def self.transmitted : Hash(Int32, Time)
        Year.filter(transmitted_at__isnull: false).to_a.to_h { |item| {item.year!.to_i32, item.transmitted_at!} }
      end

      def self.transmitted?(year : Int32) : Bool
        Year.filter(year: year, transmitted_at__isnull: false).exists?
      end

      # Années figées (clôturées ou transmises), parmi celles que couvrent
      # les périodes du socle et celles notées transmises.
      def self.frozen(list : Array(Partiduo::Api::Core::PeriodView) = periods) : Set(Int32)
        result = transmitted.keys.to_set
        candidates = list.flat_map { |period| (period.starts_on.year..period.ends_on.year).to_a }.uniq!
        candidates.each { |year| result << year if closed_at(year, list) }
        result
      end

      def self.frozen?(year : Int32) : Bool
        transmitted?(year) || !closed_at(year).nil?
      end

      # Une année figée postérieure ou égale à `year` (une immobilisation
      # acquise cette année-là compte dans sa 2035).
      def self.frozen_from?(year : Int32) : Bool
        frozen.any? { |value| value >= year }
      end

      # État de l'exercice `year`.
      def self.view(year : Int32, list : Array(Partiduo::Api::Core::PeriodView) = periods) : Api::YearView
        found = row(year)
        closed = closed_at(year, list)
        transmitted_at = found.try(&.transmitted_at)
        state = if transmitted_at && (closed.nil? || transmitted_at <= closed)
                  "transmitted"
                elsif closed
                  "closed"
                else
                  "open"
                end
        fingerprint = state == "open" ? "" : found.try(&.frozen_fingerprint.to_s) || ""
        Api::YearView.new(year, state, closed, transmitted_at, found.try(&.reference.to_s) || "", fingerprint)
      end

      # --- Événements -------------------------------------------------------------

      # Abonné de `tax_return.transmitted`, `tax_return.rejected` et
      # `period.closed`. La transmission a déjà eu lieu hors de Partiduo :
      # rien n'est jamais refusé ; un échec est consigné (point de
      # sauvegarde) et l'opération d'origine suit son cours.
      def self.on_event(event : Partiduo::Events::Event) : Nil
        result = Partiduo::Api::Transaction.run do
          case event.name
          when "tax_return.transmitted" then transmitted(event)
          when "tax_return.rejected"    then rejected(event)
          when "period.closed"          then period_closed(event)
          end
          Partiduo::Api::Result(Nil).success(nil)
        end
        Log.warn { "#{event.name} #{event.payload} : exercice non mis à jour" } if result.failure?
      rescue ex
        Log.error(exception: ex) { "#{event.name} #{event.payload} : exercice non mis à jour" }
      end

      # 2035 transmise : l'exercice est figé ; l'empreinte de la 2035
      # préparée est gardée (celle transmise aussi, pour comparaison).
      def self.transmitted(event : Partiduo::Events::Event) : Nil
        year = year_of(event) || return
        found = row(year) || Year.new(year: year)
        return if found.transmitted_at
        found.transmitted_at = Time.utc
        found.transmitted_by_id = event.actor_user_id
        found.reference = event["reference"][0, 128]
        found.transmitted_fingerprint = event["fingerprint"]?.to_s[0, 64]
        found.frozen_fingerprint = TaxReturn.prepare(year).fingerprint
        found.frozen_at = found.transmitted_at
        found.save!
      end

      # Dépôt rejeté : la transmission de ce dépôt ne fige plus l'exercice
      # (il reste figé s'il est clôturé).
      def self.rejected(event : Partiduo::Events::Event) : Nil
        year = year_of(event) || return
        found = row(year) || return
        return unless found.transmitted_at && found.reference == event["reference"]
        found.transmitted_at = nil
        found.transmitted_by_id = nil
        found.reference = ""
        found.transmitted_fingerprint = ""
        unless closed_at(year)
          found.frozen_fingerprint = ""
          found.frozen_at = nil
        end
        found.save!
      end

      # Période close : chaque année qu'elle couvre et qui se trouve dès lors
      # clôturée garde l'empreinte de sa 2035 (sauf si elle a été transmise
      # avant : l'empreinte de la transmission fait foi).
      def self.period_closed(event : Partiduo::Events::Event) : Nil
        period = Partiduo::Api::Core.period(system, event["period_id"].to_i64)
        list = periods
        (period.starts_on.year..period.ends_on.year).each do |year|
          next unless closed_at(year, list)
          found = row(year) || Year.new(year: year)
          next if found.transmitted_at
          found.frozen_fingerprint = TaxReturn.prepare(year).fingerprint
          found.frozen_at = Time.utc
          found.save!
        end
      end

      private def self.year_of(event : Partiduo::Events::Event) : Int32?
        return unless event["form"] == FORM
        event["year"].to_i?.try { |year| 1900 <= year <= 2999 ? year : nil }
      end
    end
  end
end
