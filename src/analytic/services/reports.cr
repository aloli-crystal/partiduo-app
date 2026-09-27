# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Analytic
    # Éditions analytiques : balance simple (`Anc_Balance_Simple`), balance
    # croisée double (`Anc_Balance_Double`), balance par groupe (`Anc_Group`),
    # historique (`Anc_Listing`), grand livre (`Anc_GrandLivre`), tableau
    # postes × comptes ou fiches (`Anc_Table`, `Anc_Acc_List`). Les
    # imputations des journaux que l'acteur ne voit pas sont écartées
    # (D-ANA-007). Service interne.
    module Reports
      alias Api = Partiduo::Api::Analytic
      alias AccountingApi = Partiduo::Api::Accounting

      ZERO = BigDecimal.new(0)

      # Opération lue avec son imputation, son poste et son groupe.
      record Row,
        id : Int64,
        distribution_id : Int64,
        row : Int32,
        kind : String,
        date : Time,
        entry_id : Int64?,
        ledger_id : Int64?,
        ledger_code : String,
        internal_code : String,
        receipt : String,
        account_number : String,
        account_label : String,
        card_id : Int64?,
        card_code : String,
        description : String,
        plan_id : Int64,
        post_id : Int64,
        post_code : String,
        post_description : String,
        group_code : String?,
        group_description : String?,
        side : Api::Side,
        amount : BigDecimal do
        def signed : BigDecimal
          side.debit? ? amount : -amount
        end

        def amounts : Api::Amounts
          side.debit? ? Api::Amounts.new(amount, ZERO) : Api::Amounts.new(ZERO, amount)
        end

        def post_ref : Api::PostRef
          Api::PostRef.new(post_id, plan_id, post_code, post_description)
        end
      end

      # Filtre commun des éditions : plan, dates et bornes de postes ($1 à
      # $5), puis journaux visibles ($6, imputations sans journal toujours
      # retenues).
      FILTER = <<-SQL
        FROM analytic_operation o
        JOIN analytic_distribution d ON d.id = o.distribution_id
        JOIN analytic_post p ON p.id = o.post_id
        LEFT JOIN analytic_group g ON g.id = p.group_id
        WHERE o.plan_id = $1 AND ($2::date IS NULL OR d.date >= $2::date) AND ($3::date IS NULL OR d.date <= $3::date)
          AND ($4::text IS NULL OR p.code >= $4::text) AND ($5::text IS NULL OR p.code <= $5::text)
        SQL

      VISIBLE = " AND (d.ledger_id IS NULL OR d.ledger_id = ANY($6::bigint[]))"

      # Sélection d'une édition : arguments SQL et si des imputations de
      # journaux invisibles de l'acteur sont écartées.
      record Selection, args : Array(::DB::Any | Array(Int64)), partial : Bool

      def self.selection(actor : Partiduo::Api::Actor, plan_id : Int64, date_from : Time?, date_to : Time?,
                         post_from : String?, post_to : String?) : Selection
        args = [plan_id, date_arg(date_from), date_arg(date_to), code_arg(post_from), code_arg(post_to)] of ::DB::Any
        ledgers = [] of Int64
        Marten::DB::Connection.default.open do |db|
          db.query("SELECT DISTINCT d.ledger_id #{FILTER} AND d.ledger_id IS NOT NULL", args: args) do |result_set|
            result_set.each { ledgers << result_set.read(Int64) }
          end
        end
        visible = visible_ledgers(actor, ledgers)
        Selection.new(args.map(&.as(::DB::Any | Array(Int64))) << visible.to_a, visible.size != ledgers.size)
      end

      # Opérations d'un plan, triées par date, imputation et ligne ;
      # renvoie aussi si des opérations de journaux invisibles ont été écartées.
      def self.rows(actor : Partiduo::Api::Actor, plan_id : Int64, date_from : Time?, date_to : Time?,
                    post_from : String?, post_to : String?) : {Array(Row), Bool}
        selection = selection(actor, plan_id, date_from, date_to, post_from, post_to)
        {rows(selection), selection.partial}
      end

      # Opérations d'une sélection, découpées en SQL (`offset`, `limit`).
      def self.rows(selection : Selection, offset : Int32 = 0, limit : Int32? = nil) : Array(Row)
        sql = String.build do |io|
          io << <<-SQL
            SELECT o.id, d.id, o.row, d.kind, d.date, d.entry_id, d.ledger_id, d.ledger_code, d.internal_code,
                   d.receipt, d.account_number, d.account_label, o.card_id, o.card_code, d.description,
                   o.plan_id, p.id, p.code, p.description, g.code, g.description, o.side, o.amount
            SQL
          io << ' ' << FILTER << VISIBLE << " ORDER BY d.date, d.id, o.row, o.id"
          io << " OFFSET " << offset.clamp(0, Int32::MAX) if offset > 0
          io << " LIMIT " << limit.clamp(0, Int32::MAX) if limit
        end
        rows = [] of Row
        Marten::DB::Connection.default.open do |db|
          db.query(sql, args: selection.args) do |result_set|
            result_set.each do
              rows << Row.new(
                id: result_set.read(Int64), distribution_id: result_set.read(Int64), row: result_set.read(Int32), kind: result_set.read(String),
                date: result_set.read(Time), entry_id: result_set.read(Int64?), ledger_id: result_set.read(Int64?), ledger_code: result_set.read(String),
                internal_code: result_set.read(String), receipt: result_set.read(String), account_number: result_set.read(String),
                account_label: result_set.read(String), card_id: result_set.read(Int64?), card_code: result_set.read(String),
                description: result_set.read(String), plan_id: result_set.read(Int64), post_id: result_set.read(Int64), post_code: result_set.read(String),
                post_description: result_set.read(String), group_code: result_set.read(String?), group_description: result_set.read(String?),
                side: Api::Side.from_code(result_set.read(String)), amount: result_set.read(BigDecimal),
              )
            end
          end
        end
        rows
      end

      # Nombre d'opérations et totaux débit / crédit d'une sélection.
      def self.summary(selection : Selection) : {Int32, Api::Amounts}
        sql = "SELECT count(*), coalesce(sum(CASE WHEN o.side = 'debit' THEN o.amount END), 0), " \
              "coalesce(sum(CASE WHEN o.side = 'credit' THEN o.amount END), 0) #{FILTER}#{VISIBLE}"
        Marten::DB::Connection.default.open do |db|
          db.query_one(sql, args: selection.args) do |result_set|
            count = result_set.read(Int64).to_i32
            {count, Api::Amounts.new(result_set.read(BigDecimal), result_set.read(BigDecimal))}
          end
        end
      end

      # --- Balances ---------------------------------------------------------------------

      def self.balance(plan : Api::PlanView, query : Api::ReportQuery, rows : Array(Row), partial : Bool) : Api::BalanceView
        list = balance_rows(rows)
        Api::BalanceView.new(plan, query.date_from, query.date_to, list, sum(list), partial)
      end

      def self.balance_rows(rows : Array(Row)) : Array(Api::BalanceRowView)
        rows.group_by(&.post_id).map do |_, list|
          first = list.first
          Api::BalanceRowView.new(first.post_ref, first.group_code, first.group_description,
            list.sum(Api::Amounts.zero, &.amounts))
        end.sort_by!(&.post.code)
      end

      def self.cross_balance(plan : Api::PlanView, other : Api::PlanView, query : Api::CrossBalanceQuery,
                             rows : Array(Row), others : Array(Row), partial : Bool) : Api::CrossBalanceView
        index = others.index_by { |row| {row.distribution_id, row.row} }
        pairs = rows.compact_map do |row|
          match = index[{row.distribution_id, row.row}]? || next
          {row, match}
        end
        grouped = pairs.group_by { |(row, match)| {row.post_id, match.post_id} }
        list = grouped.map do |_, items|
          Api::CrossBalanceRowView.new(items.first[0].post_ref, items.first[1].post_ref,
            items.sum(Api::Amounts.zero) { |(row, _)| row.amounts })
        end
        list.sort_by! { |item| {item.post.code, item.other_post.code} }
        subtotals = list.group_by(&.post.id).map do |_, items|
          Api::BalanceRowView.new(items.first.post, nil, nil, items.sum(Api::Amounts.zero, &.amounts))
        end
        total = list.sum(Api::Amounts.zero, &.amounts)
        Api::CrossBalanceView.new(plan, other, list, subtotals, total, partial)
      end

      def self.group_balance(plan : Api::PlanView, rows : Array(Row), partial : Bool) : Api::GroupBalanceView
        list = balance_rows(rows)
        sections = list.group_by(&.group_code).map do |code, items|
          Api::GroupBalanceSectionView.new(code, items.first.group_description, items, sum(items))
        end
        sections.sort_by! { |section| {section.group_code.nil? ? 1 : 0, section.group_description || "", section.group_code || ""} }
        Api::GroupBalanceView.new(plan, sections, sum(list), partial)
      end

      # --- Historique et grand livre ---------------------------------------------------

      def self.operation(row : Row) : Api::OperationView
        Api::OperationView.new(
          id: row.id, distribution_id: row.distribution_id, kind: row.kind, date: row.date, entry_id: row.entry_id,
          ledger_code: row.ledger_code, internal_code: row.internal_code, receipt: row.receipt,
          account_number: row.account_number, card_code: row.card_code.presence, description: row.description,
          post: row.post_ref, side: row.side, amount: row.amount,
        )
      end

      def self.ledger(plan : Api::PlanView, rows : Array(Row), partial : Bool) : Api::LedgerView
        sections = rows.group_by(&.post_id).map do |_, list|
          running = ZERO
          lines = list.map do |row|
            running += row.signed
            Api::LedgerLineView.new(operation(row), running)
          end
          Api::LedgerSectionView.new(list.first.post_ref, lines, list.sum(Api::Amounts.zero, &.amounts))
        end
        sections.sort_by!(&.post.code)
        Api::LedgerView.new(plan, sections, rows.sum(Api::Amounts.zero, &.amounts), partial)
      end

      # --- Tableau croisé ----------------------------------------------------------------

      def self.table(plan : Api::PlanView, axis : Api::TableAxis, rows : Array(Row), partial : Bool) : Api::TableView
        keys = {} of String => String
        cells = Hash(String, Hash(Int64, BigDecimal)).new { |hash, key| hash[key] = Hash(Int64, BigDecimal).new(ZERO) }
        posts = {} of Int64 => Api::PostRef
        accounts = {} of Int64 => {String, String}
        cards = {} of Int64 => {String, String}
        rows.each do |row|
          card_id = row.card_id
          key, label = axis.card? && card_id ? card_key(card_id, cards) : account_key(row, accounts)
          keys[key] ||= label
          posts[row.post_id] ||= row.post_ref
          cells[key][row.post_id] += -row.signed
        end
        table_rows = keys.compact_map do |key, label|
          amounts = cells[key].reject { |_, value| value.zero? }
          next if amounts.empty?
          Api::TableRowView.new(key, label, amounts, amounts.values.sum(ZERO))
        end
        table_rows.sort_by! { |row| axis.card? ? {row.label.downcase, row.key} : {row.key, row.label} }
        column_totals = Hash(Int64, BigDecimal).new(ZERO)
        table_rows.each { |row| row.amounts.each { |post_id, value| column_totals[post_id] += value } }
        columns = posts.values.select { |post| column_totals[post.id]? }.sort_by!(&.code)
        Api::TableView.new(plan, axis, columns, table_rows, column_totals.to_h, table_rows.sum(ZERO, &.total), partial)
      end

      # --- Outils ------------------------------------------------------------------------

      def self.sum(list : Array(Api::BalanceRowView)) : Api::Amounts
        list.sum(Api::Amounts.zero, &.amounts)
      end

      private def self.account_key(row : Row, cache : Hash(Int64, {String, String})) : {String, String}
        return {row.account_number, row.account_label} unless row.account_number.empty?
        card_id = row.card_id
        return {"", ""} if card_id.nil?
        cache[card_id] ||= begin
          system = Partiduo::Api::Actor.system
          AccountingApi.card_account(system, card_id).try { |link| {link.account.number, link.account.label} } || {"", ""}
        end
      end

      private def self.card_key(card_id : Int64, cache : Hash(Int64, {String, String})) : {String, String}
        cache[card_id] ||= begin
          card = Partiduo::Api::Cards.card(Partiduo::Api::Actor.system, card_id)
          {card.code, card.name}
        end
      end

      private def self.visible_ledgers(actor : Partiduo::Api::Actor, ids : Array(Int64)) : Set(Int64)
        return ids.to_set if actor.system || actor.can?("accounting.ledger.write")
        ids.select do |id|
          access = AccountingApi.ledger_access(actor, id)
          access.read? || access.write?
        end.to_set
      end

      private def self.date_arg(value : Time?) : String?
        value.try { |day| Distributions.day(day).to_s("%Y-%m-%d") }
      end

      private def self.code_arg(value : String?) : String?
        value.try { |code| Plans.normalize_post(code).presence }
      end
    end
  end
end
