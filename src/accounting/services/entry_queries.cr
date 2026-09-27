# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Accounting
    # Requêtes de consultation : recherche d'écritures (`Acc_Ledger_Search`)
    # et relevé d'un compte ou d'un tiers (`Lettering::get_balance_ageing`,
    # historique d'un poste ou d'une fiche). SQL paramétré ; les montants
    # passent en texte et sont relus en `BigDecimal`. Service interne.
    module EntryQueries
      alias Api = Partiduo::Api::Accounting

      # --- Recherche -----------------------------------------------------------

      # Clause `WHERE` et paramètres d'une recherche ; `nil` si elle ne peut
      # rien trouver (fiche inconnue, aucun journal visible).
      def self.where(query : Api::EntryQuery, ledger_ids : Array(Int64)) : {String, Array(::DB::Any)}?
        return if ledger_ids.empty?
        clauses = ["e.ledger_id IN (#{ledger_ids.join(", ")})"]
        args = [] of ::DB::Any
        param = ->(value : ::DB::Any) { args << value; "$#{args.size}" }

        query.ledger_id.try { |id| clauses << "e.ledger_id = #{param.call(id)}" }
        query.ledger_kind.try { |kind| clauses << "l.kind = #{param.call(kind.code)}" }
        query.date_from.try { |day| clauses << "e.date >= #{param.call(Posting.day(day))}::date" }
        query.date_to.try { |day| clauses << "e.date <= #{param.call(Posting.day(day))}::date" }
        query.period_id.try { |id| clauses << "e.period_id = #{param.call(id)}" }
        if number = query.account.try(&.strip).presence
          normalized = Chart.normalize(number)
          condition = query.account_prefix ? "a.number LIKE #{param.call(normalized + "%")}" : "a.number = #{param.call(normalized)}"
          clauses << "EXISTS (SELECT 1 FROM accounting_entry_line x JOIN accounting_account a ON a.id = x.account_id " \
                     "WHERE x.entry_id = e.id AND #{condition})"
        end
        if code = query.card.try(&.strip).presence
          card = Partiduo::Api::Cards.card_by_code(Partiduo::Api::Actor.system, code)
          return if card.nil?
          clauses << "EXISTS (SELECT 1 FROM accounting_entry_line x WHERE x.entry_id = e.id AND x.card_id = #{param.call(card.id)})"
        end
        query.receipt.try(&.strip).presence.try { |text| clauses << "e.receipt ILIKE #{param.call("%#{escape_like(text)}%")}" }
        if text = query.text.try(&.strip).presence
          placeholder = param.call("%#{escape_like(text)}%")
          clauses << "(e.label ILIKE #{placeholder} OR e.internal_code ILIKE #{placeholder} OR e.receipt ILIKE #{placeholder})"
        end
        query.amount_min.try { |amount| clauses << "e.amount >= #{param.call(amount.to_s)}::numeric" }
        query.amount_max.try { |amount| clauses << "e.amount <= #{param.call(amount.to_s)}::numeric" }
        query.source.try(&.strip).presence.try { |source| clauses << "e.source = #{param.call(source)}" }
        unless query.include_cancelled
          clauses << "e.reversal_of_id IS NULL"
          clauses << "NOT EXISTS (SELECT 1 FROM accounting_entry r WHERE r.reversal_of_id = e.id)"
        end
        {clauses.join(" AND "), args}
      end

      def self.search_ids(query : Api::EntryQuery, ledger_ids : Array(Int64)) : Array(Int64)
        where = where(query, ledger_ids)
        return [] of Int64 if where.nil?
        clause, args = where
        limit = query.limit.clamp(1, 500)
        offset = Math.max(query.offset, 0)
        sql = "SELECT e.id FROM accounting_entry e JOIN accounting_ledger l ON l.id = e.ledger_id " \
              "WHERE #{clause} ORDER BY e.date, e.id LIMIT #{limit} OFFSET #{offset}"
        Marten::DB::Connection.default.open do |db|
          db.query_all(sql, args: args, as: Int64)
        end
      end

      def self.count(query : Api::EntryQuery, ledger_ids : Array(Int64)) : Int64
        where = where(query, ledger_ids)
        return 0_i64 if where.nil?
        clause, args = where
        sql = "SELECT count(*) FROM accounting_entry e JOIN accounting_ledger l ON l.id = e.ledger_id WHERE #{clause}"
        Marten::DB::Connection.default.open do |db|
          db.query_one(sql, args: args, as: Int64)
        end
      end

      private def self.escape_like(text : String) : String
        text.gsub(/[\\%_]/) { |char| "\\#{char}" }
      end

      # --- Relevé d'un compte ou d'un tiers ------------------------------------

      record Row,
        line_id : Int64,
        entry_id : Int64,
        date : Time,
        ledger_code : String,
        receipt : String?,
        label : String,
        due_date : Time?,
        debit : Bool,
        amount : BigDecimal,
        matching_id : Int64? do
        def signed : BigDecimal
          debit ? amount : -amount
        end

        # Date de référence de l'échu : l'échéance, sinon la date.
        def reference : Time
          due_date || date
        end
      end

      STATEMENT_SQL = <<-SQL
        SELECT x.id, e.id, e.date, l.code, e.receipt,
               COALESCE(NULLIF(x.label, ''), e.label), e.due_date, x.side = 'debit', x.amount, x.matching_id
        FROM accounting_entry_line x
        JOIN accounting_entry e ON e.id = x.entry_id
        JOIN accounting_ledger l ON l.id = e.ledger_id
        WHERE %{selection} AND e.ledger_id IN (%{ledgers})
        ORDER BY e.date, e.id, x.position
        SQL

      # Lignes d'un compte (`account_id`) ou d'une fiche (`card_id`), dans les
      # journaux visibles, jusqu'à `date_to`.
      def self.statement_rows(account_id : Int64?, card_id : Int64?, ledger_ids : Array(Int64), date_to : Time?) : Array(Row)
        return [] of Row if ledger_ids.empty?
        selection = account_id ? "x.account_id = $1" : "x.card_id = $1"
        args = [(account_id || card_id).as(::DB::Any)]
        if date_to
          selection += " AND e.date <= $2::date"
          args << Posting.day(date_to)
        end
        sql = STATEMENT_SQL % {selection: selection, ledgers: ledger_ids.join(", ")}
        Marten::DB::Connection.default.open do |db|
          db.query_all(sql, args: args) do |result_set|
            Row.new(
              line_id: result_set.read(Int64), entry_id: result_set.read(Int64), date: result_set.read(Time),
              ledger_code: result_set.read(String), receipt: result_set.read(String?), label: result_set.read(String),
              due_date: result_set.read(Time?), debit: result_set.read(Bool), amount: result_set.read(BigDecimal),
              matching_id: result_set.read(Int64?),
            )
          end
        end
      end

      # Écart débit − crédit de chaque lettrage (toutes ses lignes) ; avec
      # `date_to`, seules comptent les lignes d'écritures datées au plus tard
      # ce jour-là : un paiement postérieur ne solde pas encore la facture
      # (relevé arrêté à une date, D-TST-002).
      def self.matching_differences(ids : Array(Int64), date_to : Time? = nil) : Hash(Int64, BigDecimal)
        result = {} of Int64 => BigDecimal
        return result if ids.empty?
        args = [] of ::DB::Any
        cut = ""
        if date_to
          cut = " AND e.date <= $1::date"
          args << Posting.day(date_to)
        end
        sql = "SELECT x.matching_id, sum(CASE WHEN x.side = 'debit' THEN x.amount ELSE -x.amount END) " \
              "FROM accounting_entry_line x JOIN accounting_entry e ON e.id = x.entry_id " \
              "WHERE x.matching_id IN (#{ids.join(", ")})#{cut} GROUP BY x.matching_id"
        Marten::DB::Connection.default.open do |db|
          db.query_all(sql, args: args) do |result_set|
            id = result_set.read(Int64)
            result[id] = result_set.read(BigDecimal)
          end
        end
        result
      end

      # Reste dû et échu par fiche, pour les fiches `card_ids`, calculés par
      # PostgreSQL avec les règles de `statement` : éléments ouverts = lignes
      # non lettrées, et reliquat de chaque lettrage partiel (écart de toutes
      # ses lignes) daté de la plus ancienne échéance de la fiche dans ce
      # lettrage ; échu = éléments dont l'échéance (sinon la date) précède
      # `as_of`. Fiches sans élément ouvert absentes.
      def self.party_balances(card_ids : Array(Int64), ledger_ids : Array(Int64),
                              as_of : Time) : Hash(Int64, {BigDecimal, BigDecimal})
        result = {} of Int64 => {BigDecimal, BigDecimal}
        return result if card_ids.empty? || ledger_ids.empty?
        sql = <<-SQL
          WITH rows AS (
            SELECT x.card_id, x.matching_id,
                   CASE WHEN x.side = 'debit' THEN x.amount ELSE -x.amount END AS signed,
                   COALESCE(e.due_date, e.date) AS ref
            FROM accounting_entry_line x
            JOIN accounting_entry e ON e.id = x.entry_id
            WHERE x.card_id IN (#{card_ids.join(", ")}) AND e.ledger_id IN (#{ledger_ids.join(", ")})
          ), differences AS (
            SELECT x.matching_id, sum(CASE WHEN x.side = 'debit' THEN x.amount ELSE -x.amount END) AS difference
            FROM accounting_entry_line x
            WHERE x.matching_id IN (SELECT DISTINCT matching_id FROM rows WHERE matching_id IS NOT NULL)
            GROUP BY x.matching_id
          ), items AS (
            SELECT card_id, signed AS amount, ref FROM rows WHERE matching_id IS NULL
            UNION ALL
            SELECT r.card_id, d.difference, min(r.ref)
            FROM rows r JOIN differences d ON d.matching_id = r.matching_id
            WHERE d.difference <> 0
            GROUP BY r.card_id, r.matching_id, d.difference
          )
          SELECT card_id, sum(amount), COALESCE(sum(amount) FILTER (WHERE ref < $1::date), 0)
          FROM items GROUP BY card_id HAVING sum(amount) <> 0 OR COALESCE(sum(amount) FILTER (WHERE ref < $1::date), 0) <> 0
          SQL
        Marten::DB::Connection.default.open do |db|
          db.query_all(sql, args: [Posting.day(as_of).as(::DB::Any)]) do |result_set|
            id = result_set.read(Int64)
            result[id] = {result_set.read(BigDecimal), result_set.read(BigDecimal)}
          end
        end
        result
      end

      # Élément ouvert : montant signé et date de référence de l'échu.
      alias Item = {BigDecimal, Time}

      # Construit le relevé : solde d'ouverture, mouvements avec solde
      # progressif, reste dû, échu et balance âgée des éléments ouverts
      # (lignes non lettrées ; lettrage partiel = un seul élément, son
      # reliquat, daté de sa plus ancienne échéance).
      def self.statement(rows : Array(Row), query : Api::StatementQuery, account : Api::AccountView?,
                         card : Partiduo::Api::Cards::CardView?) : Api::AccountStatementView
        as_of = Posting.day(query.as_of || Partiduo::Config.today)
        differences = matching_differences(rows.compact_map(&.matching_id).uniq!, query.date_to)
        items = open_items(rows, differences)
        buckets, overdue = ageing(items, as_of)
        opening, totals, lines = movements(rows, query, differences, as_of)
        balance = opening + totals[0] - totals[1]

        Api::AccountStatementView.new(
          account: account, card_id: card.try(&.id), card_code: card.try(&.code), card_name: card.try(&.name),
          opening_balance: opening, total_debit: totals[0], total_credit: totals[1], balance: balance,
          remaining: items.sum(BigDecimal.new(0), &.[0]), overdue: overdue,
          ageing: Api::AgeingView.new(buckets[0], buckets[1], buckets[2], buckets[3]), lines: lines,
        )
      end

      # Une ligne est ouverte si elle n'est pas lettrée, ou si son lettrage
      # est partiel.
      private def self.open?(row : Row, differences : Hash(Int64, BigDecimal)) : Bool
        matching_id = row.matching_id
        matching_id.nil? || !differences[matching_id]?.try(&.zero?)
      end

      private def self.open_items(rows : Array(Row), differences : Hash(Int64, BigDecimal)) : Array(Item)
        items = [] of Item
        partials = {} of Int64 => Time
        rows.each do |row|
          next unless open?(row, differences)
          if matching_id = row.matching_id
            partials[matching_id] = [partials[matching_id]? || row.reference, row.reference].min
          else
            items << {row.signed, row.reference}
          end
        end
        partials.each { |id, reference| items << {differences[id], reference} }
        items
      end

      # Balance âgée (non échu, 1–30, 31–60, plus de 60 jours) et échu.
      private def self.ageing(items : Array(Item), as_of : Time) : {Array(BigDecimal), BigDecimal}
        buckets = Array.new(4) { BigDecimal.new(0) }
        overdue = BigDecimal.new(0)
        items.each do |(amount, reference)|
          days = (as_of - reference).days
          index = if days <= 0
                    0
                  elsif days <= 30
                    1
                  elsif days <= 60
                    2
                  else
                    3
                  end
          buckets[index] += amount
          overdue += amount if days > 0
        end
        {buckets, overdue}
      end

      # Solde d'ouverture, totaux débit et crédit de la fenêtre, mouvements
      # avec solde progressif.
      private def self.movements(rows : Array(Row), query : Api::StatementQuery, differences : Hash(Int64, BigDecimal),
                                 as_of : Time) : {BigDecimal, {BigDecimal, BigDecimal}, Array(Api::StatementLineView)}
        zero = BigDecimal.new(0)
        date_from = query.date_from.try { |day| Posting.day(day) }
        opening = zero
        debit = zero
        credit = zero
        lines = [] of Api::StatementLineView
        rows.each do |row|
          if date_from && row.date < date_from
            opening += row.signed
            next
          end
          row.debit ? (debit += row.amount) : (credit += row.amount)
          is_open = open?(row, differences)
          next if query.unmatched_only && !is_open
          lines << Api::StatementLineView.new(
            line_id: row.line_id, entry_id: row.entry_id, date: row.date, ledger_code: row.ledger_code,
            receipt: row.receipt, label: row.label, due_date: row.due_date,
            overdue: is_open && (row.due_date.try { |due| due < as_of } || false),
            debit: row.debit ? row.amount : zero, credit: row.debit ? zero : row.amount,
            balance: opening + debit - credit,
            matching_id: row.matching_id, matching_code: row.matching_id.try { |id| Matchings.code(id) },
          )
        end
        {opening, {debit, credit}, lines}
      end
    end
  end
end
