# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Accounting
    module VatReturns
      # Encaissements d'une opération d'achat ou de vente, pour la TVA
      # exigible à l'encaissement au prorata des sommes reçues ou versées
      # (CGI, art. 269-2-c : prestations de services ; DECISIONS D-R5-005).
      #
      # Un lettrage peut réunir plusieurs factures et plusieurs paiements sans
      # répartition enregistrée : ses lignes au débit et au crédit sont
      # appariées dans l'ordre chronologique (date, écriture, ligne), la plus
      # ancienne dette réglée d'abord. Une ligne de l'opération reçoit ainsi
      # les montants des lignes de l'autre sens qui lui sont appariées, à leur
      # date — jamais avant la date de l'opération (acompte reçu avant la
      # facture, avoir ou extourne lettrés : la plus tardive des deux dates).
      #
      # Part encaissée à une date : sommes appariées jusqu'à cette date,
      # rapportées au total TTC de l'opération (ses lignes sans rôle de TVA du
      # sens des lignes lettrées), plafonnée à 1. Un lettrage soldé donne 1 :
      # l'opération entièrement payée est entièrement exigible, comme avant.
      module Collections
        ZERO = BigDecimal.new(0)
        ONE  = BigDecimal.new(1)

        # Encaissement daté d'une opération.
        record Event, date : Time, amount : BigDecimal

        # Échéancier des encaissements d'une opération : total TTC et
        # encaissements datés, triés.
        class Schedule
          getter gross : BigDecimal
          getter events : Array(Event)

          def initialize(@gross : BigDecimal, events : Array(Event))
            @events = events.sort_by(&.date)
          end

          # Part encaissée cumulée au `date` inclus (0 à 1).
          def share(date : Time) : BigDecimal
            return ZERO if gross <= ZERO
            paid = events.select(&.date.<=(date)).sum(ZERO, &.amount)
            paid >= gross ? ONE : paid / gross
          end

          # Part d'un montant exigible de `before` (exclu) à `to` (inclus),
          # chaque cumul arrondi au centime : les parties successives
          # totalisent le montant.
          def part(amount : BigDecimal, before : Time, to : Time) : BigDecimal
            round(amount * share(to)) - round(amount * share(before))
          end

          # Date du dernier encaissement de la période, `nil` si la période
          # n'en compte aucun (rien d'exigible).
          def last_date(from : Time, to : Time) : Time?
            inside = events.select { |event| event.date >= from && event.date <= to && !event.amount.zero? }
            return if inside.empty?
            return if share(to) == share(from - 1.day)
            inside.max_of(&.date)
          end

          private def round(value : BigDecimal) : BigDecimal
            value.round(2, mode: :ties_away)
          end
        end

        # Ligne d'un lettrage.
        private record Line, id : Int64, entry_id : Int64, date : Time, debit : Bool, amount : BigDecimal,
          matching_id : Int64

        # Échéanciers des opérations `entry_ids` (celles sans ligne lettrée
        # n'ont aucun encaissement).
        def self.schedules(entry_ids : Array(Int64)) : Hash(Int64, Schedule)
          return {} of Int64 => Schedule if entry_ids.empty?
          lines = matched_lines(entry_ids)
          dates = lines.to_h { |line| {line.entry_id, line.date} }
          events = Hash(Int64, Array(Event)).new { |hash, key| hash[key] = [] of Event }
          sides = {} of Int64 => Bool
          wanted = entry_ids.to_set
          lines.group_by(&.matching_id).each_value do |group|
            pairs(group).each do |(debt, payment, amount)|
              {debt, payment}.each_with_index do |line, index|
                next unless wanted.includes?(line.entry_id)
                other = index.zero? ? payment : debt
                own = dates[line.entry_id]
                events[line.entry_id] << Event.new(other.date > own ? other.date : own, amount)
                sides[line.entry_id] = line.debit
              end
            end
          end
          gross = gross_totals(sides)
          sides.to_h { |entry_id, _| {entry_id, Schedule.new(gross[entry_id]? || ZERO, events[entry_id])} }
        end

        # Appariement chronologique des lignes au débit et au crédit d'un
        # lettrage : {ligne au débit, ligne au crédit, montant}.
        private def self.pairs(group : Array(Line)) : Array({Line, Line, BigDecimal})
          order = ->(line : Line) { {line.date, line.entry_id, line.id} }
          debits = group.select(&.debit).sort_by! { |line| order.call(line) }
          credits = group.reject(&.debit).sort_by! { |line| order.call(line) }
          result = [] of {Line, Line, BigDecimal}
          left = debits.map(&.amount)
          right = credits.map(&.amount)
          i = j = 0
          while i < debits.size && j < credits.size
            amount = {left[i], right[j]}.min
            result << {debits[i], credits[j], amount} if amount > ZERO
            left[i] -= amount
            right[j] -= amount
            i += 1 if left[i] <= ZERO
            j += 1 if right[j] <= ZERO
          end
          result
        end

        # Lignes de tous les lettrages qui touchent ces opérations.
        private def self.matched_lines(entry_ids : Array(Int64)) : Array(Line)
          sql = <<-SQL
            SELECT y.id, y.entry_id, e.date, y.side = 'debit', y.amount, y.matching_id
            FROM accounting_entry_line y
            JOIN accounting_entry e ON e.id = y.entry_id
            WHERE y.matching_id IN (
              SELECT DISTINCT x.matching_id FROM accounting_entry_line x
              WHERE x.matching_id IS NOT NULL AND x.entry_id IN (#{id_list(entry_ids)})
            )
            SQL
          Marten::DB::Connection.default.open do |db|
            db.query_all(sql) do |result_set|
              Line.new(id: result_set.read(Int64), entry_id: result_set.read(Int64), date: result_set.read(Time),
                debit: result_set.read(Bool), amount: result_set.read(BigDecimal), matching_id: result_set.read(Int64))
            end
          end
        end

        # Liste d'identifiants pour `IN` : entiers lus en base, sans saisie.
        private def self.id_list(ids : Array(Int64)) : String
          ids.join(", ")
        end

        # Total TTC de chaque opération : ses lignes sans rôle de TVA du sens
        # de ses lignes lettrées (le tiers).
        private def self.gross_totals(sides : Hash(Int64, Bool)) : Hash(Int64, BigDecimal)
          return {} of Int64 => BigDecimal if sides.empty?
          sql = <<-SQL
            SELECT x.entry_id, x.side = 'debit', sum(x.amount)
            FROM accounting_entry_line x
            WHERE x.entry_id IN (#{id_list(sides.keys)}) AND x.vat_role IS NULL
            GROUP BY x.entry_id, x.side
            SQL
          totals = {} of Int64 => BigDecimal
          Marten::DB::Connection.default.open do |db|
            db.query_each(sql) do |result_set|
              entry_id, debit, amount = result_set.read(Int64), result_set.read(Bool), result_set.read(BigDecimal)
              totals[entry_id] = amount if sides[entry_id]? == debit
            end
          end
          totals
        end
      end
    end
  end
end
