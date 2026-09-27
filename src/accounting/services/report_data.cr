# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Accounting
    # Données communes des éditions (lot 3) : période par défaut, sommes par
    # compte (et par fiche) calculées par PostgreSQL, fiches de tiers.
    # Service interne ; SQL paramétré, montants relus en `BigDecimal`.
    module ReportData
      alias Api = Partiduo::Api::Accounting

      ZERO = BigDecimal.new(0)

      # Sommes d'un compte, ou d'un couple compte × fiche : solde signé
      # d'ouverture, débit et crédit de la période, nombre de lignes de la
      # période.
      record Sum,
        number : String,
        label : String,
        kind : String,
        card_id : Int64?,
        opening : BigDecimal,
        debit : BigDecimal,
        credit : BigDecimal,
        lines : Int32 do
        def balance : BigDecimal
          opening + debit - credit
        end

        def movement : BigDecimal
          debit - credit
        end
      end

      # Premier jour de l'exercice qui contient `day`, ou `nil` hors
      # exercice.
      def self.fiscal_start(day : Time) : Time?
        fiscal_bounds(day).try(&.[0])
      end

      # Premier et dernier jour de l'exercice qui contient `day`.
      def self.fiscal_bounds(day : Time) : {Time, Time}?
        period = Partiduo::Api::Core.period_for(Partiduo::Api::Actor.system, day) || return
        year = Partiduo::Api::Core.fiscal_year(Partiduo::Api::Actor.system, period.fiscal_year_id)
        from = year.starts_on || return
        to = year.ends_on || return
        {from, to}
      end

      # Bornes d'une édition : `date_to` (défaut : aujourd'hui) et
      # `date_from` (défaut : début de l'exercice de `date_to`, sinon le
      # 1ᵉʳ janvier).
      def self.range(date_from : Time?, date_to : Time?) : {Time, Time}
        to = Posting.day(date_to || Partiduo::Config.today)
        from = date_from.try { |day| Posting.day(day) } || fiscal_start(to) || Time.utc(to.year, 1, 1)
        {from, to}
      end

      # Journaux retenus : visibles de l'acteur, restreints aux
      # identifiants et aux types demandés.
      def self.ledgers(readable : Array(Int64), ids : Array(Int64)?, kinds : Array(Api::LedgerKind)? = nil) : Array(Int64)
        selected = ids ? readable & ids : readable
        if kinds
          codes = kinds.map(&.code)
          allowed = Ledger.filter(kind__in: codes).pluck(:id).map { |row| row.first.as(Int64) }
          selected &= allowed
        end
        selected
      end

      # Sommes des lignes de `from` à `to`, avec le solde d'ouverture des
      # lignes de l'exercice antérieures à `from` ; par compte, ou par
      # compte et fiche (`by_card`). `card_ids` : lignes de ces fiches
      # seulement ; `account_prefix` : comptes qui commencent par ce numéro.
      def self.sums(ledger_ids : Array(Int64), from : Time, to : Time, *, by_card : Bool = false,
                    account_from : String? = nil, account_to : String? = nil, account_prefix : String? = nil,
                    card_ids : Array(Int64)? = nil, opening : Bool = true) : Array(Sum)
        return [] of Sum if ledger_ids.empty? || from > to
        return [] of Sum if card_ids && card_ids.empty?
        start = opening ? (fiscal_start(from) || from) : from
        start = from if start > from
        args = [start, from, to] of ::DB::Any
        clauses = ["e.ledger_id IN (#{ledger_ids.join(", ")})", "e.date >= $1::date", "e.date <= $3::date"]
        clauses.concat(account_clauses(args, account_from, account_to, account_prefix))
        clauses << "x.card_id IN (#{card_ids.join(", ")})" if card_ids
        card_column = by_card ? "x.card_id" : "NULL::bigint"
        sql = <<-SQL
          SELECT a.number, a.label, a.kind, #{card_column},
                 COALESCE(sum(CASE WHEN x.side = 'debit' THEN x.amount ELSE -x.amount END) FILTER (WHERE e.date < $2::date), 0),
                 COALESCE(sum(x.amount) FILTER (WHERE e.date >= $2::date AND x.side = 'debit'), 0),
                 COALESCE(sum(x.amount) FILTER (WHERE e.date >= $2::date AND x.side = 'credit'), 0),
                 count(*) FILTER (WHERE e.date >= $2::date)
          FROM accounting_entry_line x
          JOIN accounting_entry e ON e.id = x.entry_id
          JOIN accounting_account a ON a.id = x.account_id
          WHERE #{clauses.join(" AND ")}
          GROUP BY a.number, a.label, a.kind#{by_card ? ", x.card_id" : ""}
          ORDER BY a.number#{by_card ? ", x.card_id" : ""}
          SQL
        Marten::DB::Connection.default.open do |db|
          db.query_all(sql, args: args) do |result_set|
            Sum.new(
              number: result_set.read(String), label: result_set.read(String), kind: result_set.read(String),
              card_id: result_set.read(Int64?), opening: result_set.read(BigDecimal),
              debit: result_set.read(BigDecimal), credit: result_set.read(BigDecimal),
              lines: result_set.read(Int64).to_i32,
            )
          end
        end
      end

      # Conditions sur le numéro de compte (`a.number`), paramètres ajoutés à
      # `args` : à partir de `from`, jusqu'à `to` (lui et ses sous-comptes
      # compris : `4` couvre `411`, là où `Acc_Balance` comparait le texte
      # seul), commençant par `prefix`.
      def self.account_clauses(args : Array(::DB::Any), from : String?, to : String?, prefix : String?) : Array(String)
        clauses = [] of String
        param = ->(value : ::DB::Any) { args << value; "$#{args.size}" }
        from.try(&.strip.presence).try { |low| clauses << "a.number >= #{param.call(Chart.normalize(low))}" }
        to.try(&.strip.presence).try do |high|
          normalized = Chart.normalize(high)
          clauses << "(a.number <= #{param.call(normalized)} OR a.number LIKE #{param.call(normalized + "%")})"
        end
        prefix.try(&.strip.presence).try { |start| clauses << "a.number LIKE #{param.call(Chart.normalize(start) + "%")}" }
        clauses
      end

      # Fiches de tiers des natures `kinds` (toutes, actives ou non), par
      # identifiant.
      def self.cards(kinds : Array(String)) : Hash(Int64, Partiduo::Api::Cards::CardView)
        result = {} of Int64 => Partiduo::Api::Cards::CardView
        kinds.each do |kind|
          offset = 0
          loop do
            page = Partiduo::Api::Cards.cards(Partiduo::Api::Actor.system,
              Partiduo::Api::Cards::CardQuery.new(kind: kind, enabled: nil, limit: 1000, offset: offset))
            page.each { |card| result[card.id] = card }
            break if page.size < 1000
            offset += 1000
          end
        end
        result
      end

      # Natures retenues : `kind` s'il est donné, sinon `defaults`.
      def self.kinds(kind : String?, defaults : Array(String)) : Array(String)
        kind.try(&.strip.presence).try { |value| [value] } || defaults
      end

      # Fiches Banque et Article (toutes) : leurs lignes ne répartissent pas
      # un compte entre actif et passif (`-D`, `-C`).
      def self.neutral_card_ids : Set(Int64)
        (Partiduo::Api::Cards::KINDS - Balances::AUXILIARY_KINDS).flat_map do |kind|
          Partiduo::Api::Cards.card_ids(Partiduo::Api::Actor.system,
            Partiduo::Api::Cards::CardQuery.new(kind: kind, enabled: nil))
        end.to_set
      end

      def self.account_kind(code : String) : Api::AccountKind?
        Api::AccountKind.from_code(code)
      rescue ArgumentError
        nil
      end
    end
  end
end
