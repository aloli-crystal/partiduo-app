# SPDX-License-Identifier: AGPL-3.0-or-later

require "log"

module Partiduo
  module Liberal
    # Exercices du module (DECISIONS D-LIB2-001, D-LIB5-001 à D-LIB5-004) :
    # l'exercice d'une ligne est l'année civile de sa date, celle de la 2035.
    # Trois états, notés dans `liberal_year.state` :
    #
    # * *ouvert* (`open`) : ses lignes se modifient et se suppriment ;
    # * *clôturé* (`closed`) : le professionnel l'a clôturé (`close!`) ; les
    #   lignes sont figées ; il le rouvre (`reopen!`) tant que la 2035 n'est
    #   pas transmise ;
    # * *verrouillé* (`locked`) : 2035 transmise (`tax_return.transmitted`,
    #   publié par l'extension qui la transmet) ; définitif, sauf rejet de ce
    #   dépôt (`tax_return.rejected`), qui le rend clôturé.
    #
    # La clôture au socle (toutes les périodes qui couvrent l'année closes)
    # est un verrou de plus, lu sur les périodes : l'exercice est alors
    # clôturé et ne se rouvre pas par le module. Une période close au milieu
    # d'un exercice ouvert fige les lignes de cette période seulement.
    #
    # Plusieurs exercices sont ouverts en même temps (l'année N se saisit
    # pendant que N-1 s'achève). Au figement, l'empreinte de la 2035 est
    # gardée (`frozen_fingerprint`) : un écart ultérieur (identification
    # changée) est signalé par un contrôle. Chaque passage est tracé dans
    # `liberal_year_change` (qui, quand). Service interne.
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
      def self.core_closed_at(year : Int32, list : Array(Partiduo::Api::Core::PeriodView) = periods) : Time?
        from, to = Time.utc(year, 1, 1), Time.utc(year, 12, 31)
        covering = list.select { |period| period.starts_on <= to && period.ends_on >= from }
        return if covering.empty? || !covering.all?(&.closed?)
        covering.compact_map(&.closed_at).max?
      end

      def self.row(year : Int32) : Year?
        Year.filter(year: year).first
      end

      # Années clôturées ou verrouillées par le module : année → état.
      def self.held : Hash(Int32, String)
        Year.filter(state__in: %w[closed locked]).to_a.to_h { |item| {item.year!.to_i32, item.state.to_s} }
      end

      # État noté par le module (`open` sans ligne).
      def self.state(year : Int32) : String
        row(year).try(&.state.to_s) || "open"
      end

      # Clôturée ou verrouillée par le module.
      def self.held?(year : Int32) : Bool
        Year.filter(year: year, state__in: %w[closed locked]).exists?
      end

      # Années verrouillées (2035 transmise) : date de la transmission.
      def self.transmitted : Hash(Int32, Time)
        Year.filter(state: "locked").to_a.to_h { |item| {item.year!.to_i32, item.transmitted_at!} }
      end

      def self.transmitted?(year : Int32) : Bool
        Year.filter(year: year, state: "locked").exists?
      end

      # Années figées (clôturées ou verrouillées par le module, ou closes au
      # socle), parmi celles que couvrent les périodes du socle et celles
      # notées par le module.
      def self.frozen(list : Array(Partiduo::Api::Core::PeriodView) = periods) : Set(Int32)
        result = held.keys.to_set
        candidates = list.flat_map { |period| (period.starts_on.year..period.ends_on.year).to_a }.uniq!
        candidates.each { |year| result << year if core_closed_at(year, list) }
        result
      end

      def self.frozen?(year : Int32) : Bool
        held?(year) || !core_closed_at(year).nil?
      end

      # Une année figée postérieure ou égale à `year` (une immobilisation
      # acquise cette année-là compte dans sa 2035).
      def self.frozen_from?(year : Int32) : Bool
        frozen.any? { |value| value >= year }
      end

      # État de l'exercice `year` : verrouillé si sa 2035 est transmise,
      # clôturé s'il l'est par le module ou au socle, ouvert sinon.
      def self.view(year : Int32, list : Array(Partiduo::Api::Core::PeriodView) = periods) : Api::YearView
        found = row(year)
        noted = found.try(&.state.to_s) || "open"
        core = core_closed_at(year, list)
        state = noted == "open" && core ? "closed" : noted
        closed_at = found.try(&.closed_at) || core
        fingerprint = state == "open" ? "" : found.try(&.frozen_fingerprint.to_s) || ""
        closed_by_id = found.try(&.closed_by_id.try(&.to_i64))
        reopened_by_id = found.try(&.reopened_by_id.try(&.to_i64))
        Api::YearView.new(year, state, state == "open" ? nil : closed_at, found.try(&.transmitted_at),
          found.try(&.reference.to_s) || "", fingerprint, closed_by_id: closed_by_id, closed_by: user_name(closed_by_id),
          reopened_at: found.try(&.reopened_at), reopened_by_id: reopened_by_id, reopened_by: user_name(reopened_by_id),
          core_closed_at: core)
      end

      # Passages de l'exercice, du plus ancien au plus récent.
      def self.history(year : Int32) : Array(Api::YearChangeView)
        names = {} of Int64 => String
        YearChange.filter(year: year).order(:at, :id).to_a.map do |item|
          user_id = item.user_id.try(&.to_i64)
          name = user_id ? (names[user_id] ||= user_name(user_id)) : ""
          Api::YearChangeView.new(year, item.action.to_s, item.at!, user_id, name, item.reference.to_s)
        end
      end

      # Nom de l'utilisateur (socle), vide s'il est inconnu.
      def self.user_name(id : Int64?) : String
        return "" unless id
        user = Partiduo::Api::Auth.user(system, id)
        user.full_name.presence || user.email
      rescue Partiduo::Api::NotFound
        ""
      end

      # --- Clôture et réouverture (D-LIB5-001) ----------------------------------------

      # Refus de clôturer : année hors bornes, à venir, déjà clôturée ou
      # verrouillée.
      def self.close_errors(year : Int32) : Array(Partiduo::Api::FieldError)
        return [Registers.error("year", "year.invalid")] unless 1900 <= year <= 2999
        return [Registers.error("year", "year.close.future", {"year" => year.to_s})] if year > Partiduo::Config.today.year
        case view(year).state
        when "locked" then [Registers.error("year", "year.close.locked", {"year" => year.to_s})]
        when "closed" then [Registers.error("year", "year.close.already", {"year" => year.to_s})]
        else               [] of Partiduo::Api::FieldError
        end
      end

      # Clôture l'exercice ouvert `year` : lignes figées (déclencheurs),
      # empreinte de la 2035 gardée, passage tracé.
      def self.close!(year : Int32, user_id : Int64?, at : Time = Time.utc) : Year
        found = locked_row(year)
        found.state = "closed"
        found.closed_at = at
        found.closed_by_id = user_id
        found.frozen_fingerprint = TaxReturn.prepare(year).fingerprint
        found.frozen_at = at
        found.save!
        trace(year, "closed", user_id, at)
        found
      end

      # Refus de rouvrir : ouvert, verrouillé (2035 transmise), clos au socle.
      def self.reopen_errors(year : Int32) : Array(Partiduo::Api::FieldError)
        return [Registers.error("year", "year.invalid")] unless 1900 <= year <= 2999
        exercise = view(year)
        return [Registers.error("year", "year.reopen.locked", {"year" => year.to_s})] if exercise.locked?
        return [Registers.error("year", "year.reopen.core_closed", {"year" => year.to_s})] if exercise.core_closed_at
        return [Registers.error("year", "year.reopen.open", {"year" => year.to_s})] unless exercise.closed?
        [] of Partiduo::Api::FieldError
      end

      # Rouvre l'exercice clôturé `year` : ses lignes redeviennent
      # modifiables ; l'empreinte du figement est oubliée.
      def self.reopen!(year : Int32, user_id : Int64?, at : Time = Time.utc) : Year
        found = locked_row(year)
        found.state = "open"
        found.closed_at = nil
        found.closed_by_id = nil
        found.reopened_at = at
        found.reopened_by_id = user_id
        found.frozen_fingerprint = ""
        found.frozen_at = nil
        found.save!
        trace(year, "reopened", user_id, at)
        found
      end

      # Ligne de l'exercice, créée au besoin, prise sous verrou.
      private def self.locked_row(year : Int32) : Year
        Marten::DB::Connection.default.open do |db|
          db.exec("INSERT INTO liberal_year (year, state) VALUES ($1, 'open') ON CONFLICT (year) DO NOTHING", year)
        end
        Year.filter(year: year).lock.first || raise "exercice #{year} absent"
      end

      private def self.trace(year : Int32, action : String, user_id : Int64?, at : Time, reference : String = "") : Nil
        YearChange.create!(year: year, action: action, at: at, user_id: user_id, reference: reference[0, 128])
      end

      # --- Événements -------------------------------------------------------------

      # Abonné de `tax_return.transmitted`, `tax_return.rejected` (événements
      # adoptés le 1er octobre 2026, D-LIB5-002) et `period.closed`. La
      # transmission a déjà eu lieu hors de Partiduo : rien n'est jamais
      # refusé ; un échec est consigné (point de sauvegarde) et l'opération
      # d'origine suit son cours.
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

      # 2035 transmise : l'exercice est verrouillé ; l'empreinte de la 2035
      # préparée est gardée (celle transmise aussi, pour comparaison). Un
      # exercice encore ouvert (transmission notée à la main, ou réouverture
      # concurrente) est d'abord clôturé d'office, au nom de l'auteur de la
      # transmission (D-LIB5-002) : rien n'est jamais refusé.
      def self.transmitted(event : Partiduo::Events::Event) : Nil
        year = year_of(event) || return
        found = locked_row(year)
        return if found.state == "locked"
        at = Time.utc
        user_id = event.actor_user_id
        found = close!(year, user_id, at) if found.state == "open"
        found.state = "locked"
        found.transmitted_at = at
        found.transmitted_by_id = user_id
        found.reference = event["reference"][0, 128]
        found.transmitted_fingerprint = event["fingerprint"]?.to_s[0, 64]
        found.frozen_fingerprint = TaxReturn.prepare(year).fingerprint
        found.frozen_at = at
        found.save!
        trace(year, "locked", user_id, at, found.reference.to_s)
      end

      # Dépôt rejeté : le verrou de ce dépôt est levé, l'exercice redevient
      # clôturé (réversible) pour correction et nouvel envoi.
      def self.rejected(event : Partiduo::Events::Event) : Nil
        year = year_of(event) || return
        found = row(year) || return
        return unless found.state == "locked" && found.reference == event["reference"]
        found = locked_row(year)
        reference = found.reference.to_s
        found.state = "closed"
        found.transmitted_at = nil
        found.transmitted_by_id = nil
        found.reference = ""
        found.transmitted_fingerprint = ""
        found.save!
        trace(year, "unlocked", event.actor_user_id, Time.utc, reference)
      end

      # Période close : chaque année qu'elle couvre et qui se trouve dès lors
      # close au socle garde l'empreinte de sa 2035, si le module ne l'a pas
      # déjà figée (sa clôture ou sa transmission fait foi).
      def self.period_closed(event : Partiduo::Events::Event) : Nil
        period = Partiduo::Api::Core.period(system, event["period_id"].to_i64)
        list = periods
        (period.starts_on.year..period.ends_on.year).each do |year|
          next unless core_closed_at(year, list)
          found = row(year) || Year.new(year: year)
          next unless found.state.to_s.in?("", "open")
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
