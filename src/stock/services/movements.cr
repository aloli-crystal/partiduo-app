# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Stock
    # Mouvements de stock : création, lecture en vues, quantités à une date,
    # état des stocks (`Stock::build_tmp_table`, `Stock::summary`),
    # historique (`Stock::create_query_histo`) et valorisation au coût moyen
    # pondéré (D-STK-005). Service interne.
    module Movements
      alias Api = Partiduo::Api::Stock

      ZERO = BigDecimal.new(0)

      # Quantité signée d'un mouvement, en SQL.
      SIGNED = "CASE WHEN m.direction = 'in' THEN m.quantity ELSE -m.quantity END"

      # --- Paramètres -------------------------------------------------------------------

      def self.setting : Setting
        Setting.filter(singleton: true).first || Setting.create!(singleton: true)
      end

      def self.default_repository : Repository?
        setting.default_repository
      end

      # Premier dépôt créé : dépôt par défaut s'il n'y en a pas encore.
      def self.adopt_default(repository : Repository) : Nil
        current = setting
        return unless current.default_repository_id.nil?
        current.default_repository = repository
        current.save!
      end

      # --- Articles suivis ---------------------------------------------------------------

      def self.items_by_card(card_ids : Array(Int64)) : Hash(Int64, Item)
        return {} of Int64 => Item if card_ids.empty?
        Item.filter(card_id__in: card_ids.uniq).to_a.index_by(&.card_id!.as(Int64))
      end

      def self.item_views(items : Array(Item)) : Array(Api::ItemView)
        cards = Cards.by_id(items.map(&.card_id!.as(Int64)))
        items.compact_map do |item|
          card = cards[item.card_id!.as(Int64)]? || next
          Api::ItemView.new(card.id, card.code, card.name, item.stock_code!)
        end.sort_by! { |view| {view.stock_code, view.card_code} }
      end

      # --- Périodes closes ---------------------------------------------------------------

      # La date tombe-t-elle dans une période close, ou un exercice clos
      # (socle) ? Les mouvements y sont figés.
      def self.closed_on?(date : Time) : Bool
        # Contrat du socle : la clôture d'un exercice clôt chacune de ses
        # périodes (`Core.close_fiscal_year`).
        Partiduo::Api::Core.period_for(Partiduo::Api::Actor.system, date).try(&.closed?) || false
      end

      # --- Création ------------------------------------------------------------------------

      def self.create!(repository_id : Int64, item : Item, direction : String, quantity : BigDecimal, date : Time,
                       unit_cost : BigDecimal? = nil, comment : String = "", source : String = "",
                       change : Change? = nil, created_by_id : Int64? = nil) : Movement
        Movement.create!(repository_id: repository_id, change: change, card_id: item.card_id,
          stock_code: item.stock_code, direction: direction, quantity: quantity, unit_cost: unit_cost,
          date: day(date), comment: comment, source: source, created_by_id: created_by_id)
      end

      def self.day(date : Time) : Time
        Time.utc(date.year, date.month, date.day)
      end

      # Quantité en stock d'un code dans un dépôt, mouvements datés jusqu'au
      # jour `date` compris.
      def self.quantity_on(repository_id : Int64, stock_code : String, date : Time) : BigDecimal
        Marten::DB::Connection.default.open do |db|
          db.query_one("SELECT coalesce(sum(#{SIGNED}), 0) FROM stock_movement m " \
                       "WHERE m.repository_id = $1 AND m.stock_code = $2 AND m.date <= $3::date",
            args: [repository_id, stock_code, date.to_s("%Y-%m-%d")], &.read(BigDecimal))
        end
      end

      # --- Vues ------------------------------------------------------------------------------

      def self.views(movements : Array(Movement)) : Array(Api::MovementView)
        return [] of Api::MovementView if movements.empty?
        cards = Cards.by_id(movements.map(&.card_id!.as(Int64)))
        repositories = Repository.filter(id__in: movements.map(&.repository_id!.as(Int64)).uniq!).to_a
          .to_h { |repository| {repository.pk!.as(Int64), repository.name!} }
        movements.map do |movement|
          card = cards[movement.card_id!.as(Int64)]?
          repository_id = movement.repository_id!.as(Int64)
          Api::MovementView.new(
            id: movement.pk!.as(Int64), repository_id: repository_id,
            repository_name: repositories[repository_id]? || "",
            card_id: movement.card_id!.as(Int64), card_code: card.try(&.code) || "", card_name: card.try(&.name) || "",
            stock_code: movement.stock_code!, direction: movement.direction!, quantity: movement.quantity!,
            unit_cost: movement.unit_cost, date: movement.date!, comment: movement.comment.to_s,
            source: movement.source.to_s, change_id: movement.change_id.try(&.as(Int).to_i64),
            created_by_id: movement.created_by_id.try(&.to_i64), created_at: movement.created_at!)
        end
      end

      def self.change_view(change : Change) : Api::ChangeView
        movements = Movement.filter(change_id: change.pk).order(:id).to_a
        repository = change.repository!
        Api::ChangeView.new(
          id: change.pk!.as(Int64), kind: change.kind!, repository_id: repository.pk!.as(Int64),
          repository_name: repository.name!, date: change.date!, comment: change.comment.to_s,
          created_by_id: change.created_by_id.try(&.to_i64), created_at: change.created_at!, movements: views(movements))
      end

      def self.repository_view(repository : Repository, counts : Hash(Int64, Int64)? = nil) : Api::RepositoryView
        id = repository.pk!.as(Int64)
        count = counts ? counts.fetch(id, 0_i64) : Movement.filter(repository_id: id).count.to_i64
        Api::RepositoryView.new(id: id, name: repository.name!, address: repository.address.to_s,
          city: repository.city.to_s, country_code: repository.country_code.to_s, phone: repository.phone.to_s,
          default: setting.default_repository_id == id, movements_count: count)
      end

      def self.movement_counts : Hash(Int64, Int64)
        counts = {} of Int64 => Int64
        Marten::DB::Connection.default.open do |db|
          db.query("SELECT repository_id, count(*) FROM stock_movement GROUP BY repository_id") do |result_set|
            result_set.each { counts[result_set.read(Int64)] = result_set.read(Int64) }
          end
        end
        counts
      end

      # --- Historique ------------------------------------------------------------------------

      # Mouvements qui répondent aux critères ; `allowed` : dépôts lisibles
      # de l'acteur (`nil` : tous, droits par dépôt D-R5-015).
      def self.history_query(query : Api::MovementQuery, allowed : Set(Int64)? = nil)
        movements = Movement.all
        query.repository_id.try { |id| movements = movements.filter(repository_id: id) }
        allowed.try { |ids| movements = movements.filter(repository_id__in: ids.to_a) }
        query.card_id.try { |id| movements = movements.filter(card_id: id) }
        query.stock_code.try { |code| movements = movements.filter(stock_code: Rules.normalize_code(code)) }
        query.direction.try { |direction| movements = movements.filter(direction: direction) }
        query.date_from.try { |date| movements = movements.filter(date__gte: day(date)) }
        query.date_to.try { |date| movements = movements.filter(date__lte: day(date)) }
        query.source.try { |source| movements = movements.filter(source__startswith: source) }
        movements
      end

      def self.history(query : Api::MovementQuery, allowed : Set(Int64)? = nil) : Array(Api::MovementView)
        offset = query.offset.clamp(0, Int32::MAX)
        limit = query.limit.clamp(0, 10_000)
        return [] of Api::MovementView if limit.zero?
        views(history_query(query, allowed).order(:date, :id)[offset...(offset + limit)].to_a)
      end

      # --- État des stocks ----------------------------------------------------------------------

      def self.state(query : Api::StateQuery) : Api::StateView
        from = day(query.date_from)
        to = day(query.date_to)
        args = [from.to_s("%Y-%m-%d"), to.to_s("%Y-%m-%d")] of ::DB::Any
        filter = ""
        if repository_id = query.repository_id
          args << repository_id
          filter = " AND m.repository_id = $3"
        end
        sql = <<-SQL
          SELECT m.repository_id, r.name, m.stock_code,
                 coalesce(sum(CASE WHEN m.date < $1::date THEN #{SIGNED} END), 0),
                 coalesce(sum(CASE WHEN m.date >= $1::date AND m.direction = 'in' THEN m.quantity END), 0),
                 coalesce(sum(CASE WHEN m.date >= $1::date AND m.direction = 'out' THEN m.quantity END), 0)
          FROM stock_movement m JOIN stock_repository r ON r.id = m.repository_id
          WHERE m.date <= $2::date#{filter}
          GROUP BY m.repository_id, r.name, m.stock_code
          ORDER BY r.name, m.stock_code
          SQL
        raw = [] of {Int64, String, String, BigDecimal, BigDecimal, BigDecimal}
        Marten::DB::Connection.default.open do |db|
          db.query(sql, args: args) do |result_set|
            result_set.each do
              raw << {result_set.read(Int64), result_set.read(String), result_set.read(String),
                      result_set.read(BigDecimal), result_set.read(BigDecimal), result_set.read(BigDecimal)}
            end
          end
        end
        names = card_names(raw.map { |row| row[2] })
        rows = raw.map do |(repository_id, name, code, opening, quantity_in, quantity_out)|
          Api::StateRowView.new(repository_id, name, code, names.fetch(code, [] of String), opening, quantity_in, quantity_out)
        end
        Api::StateView.new(from, to, rows)
      end

      # Noms des fiches d'un code stock : fiches suivies sous ce code et
      # fiches des mouvements qui l'ont porté.
      def self.card_names(codes : Array(String)) : Hash(String, Array(String))
        names = {} of String => Array(String)
        return names if codes.empty?
        Marten::DB::Connection.default.open do |db|
          db.query(<<-SQL, args: [codes.uniq]) do |result_set|
            SELECT DISTINCT s.stock_code, c.name
            FROM (SELECT stock_code, card_id FROM stock_item WHERE stock_code = ANY($1)
                  UNION SELECT stock_code, card_id FROM stock_movement WHERE stock_code = ANY($1)) s
            JOIN cards_card c ON c.id = s.card_id
            ORDER BY s.stock_code, c.name
            SQL
            result_set.each do
              code = result_set.read(String)
              (names[code] ||= [] of String) << result_set.read(String)
            end
          end
        end
        names
      end

      # Quantités théoriques d'un dépôt à une date, par code stock, pour
      # chaque article suivi (inventaire proposé, `take_last_inventory`).
      def self.inventory_proposal(repository_id : Int64, date : Time) : Array(Api::InventoryLineView)
        quantities = {} of String => BigDecimal
        Marten::DB::Connection.default.open do |db|
          db.query("SELECT m.stock_code, sum(#{SIGNED}) FROM stock_movement m " \
                   "WHERE m.repository_id = $1 AND m.date <= $2::date GROUP BY m.stock_code",
            args: [repository_id, day(date).to_s("%Y-%m-%d")]) do |result_set|
            result_set.each { quantities[result_set.read(String)] = result_set.read(BigDecimal) }
          end
        end
        seen = Set(String).new
        item_views(Item.all.to_a).compact_map do |item|
          next unless seen.add?(item.stock_code)
          Api::InventoryLineView.new(item.card_id, item.card_code, item.card_name, item.stock_code,
            quantities.fetch(item.stock_code, ZERO))
        end
      end

      # --- Valorisation -----------------------------------------------------------------------

      # Coût moyen pondéré des mouvements valorisés de chaque code stock
      # jusqu'à `date` (tous dépôts confondus) : Σ(quantité × coût) ÷
      # Σ(quantité), quantités signées (une entrée extournée se retranche) —
      # {total, quantité} par code.
      def self.cost_bases(date : Time) : Hash(String, {BigDecimal, BigDecimal})
        bases = {} of String => {BigDecimal, BigDecimal}
        Marten::DB::Connection.default.open do |db|
          db.query("SELECT m.stock_code, sum(#{SIGNED} * m.unit_cost), sum(#{SIGNED}) FROM stock_movement m " \
                   "WHERE m.unit_cost IS NOT NULL AND m.date <= $1::date GROUP BY m.stock_code",
            args: [day(date).to_s("%Y-%m-%d")]) do |result_set|
            result_set.each { bases[result_set.read(String)] = {result_set.read(BigDecimal), result_set.read(BigDecimal)} }
          end
        end
        bases
      end

      def self.valuation(date : Time, repository_id : Int64?) : Api::ValuationView
        on = day(date)
        state = state(Api::StateQuery.new(on, on, repository_id))
        bases = cost_bases(on)
        rows = state.rows.compact_map do |row|
          quantity = row.closing
          next if quantity.zero?
          unit_cost, value = nil, nil
          if (base = bases[row.stock_code]?) && base[1] > 0
            unit_cost = (base[0] / base[1]).round(4, mode: :ties_away)
            value = (quantity * base[0] / base[1]).round(2, mode: :ties_away)
          end
          Api::ValuationRowView.new(row.repository_id, row.repository_name, row.stock_code, row.card_names,
            quantity, unit_cost, value)
        end
        Api::ValuationView.new(on, rows)
      end
    end
  end
end
