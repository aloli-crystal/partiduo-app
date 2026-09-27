# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    # Contrat du module Stock (lot 6, ADR-006 D1) : dépôts, paramètres,
    # articles suivis, opérations manuelles et inventaires, historique, état
    # des stocks, valorisation et exports CSV. Types dans `types.cr` ;
    # référence : `doc/api/stock.adoc`.
    #
    # Toute commande et toute requête lèvent `ModuleDisabled` si le Stock est
    # inactif. Les mouvements issus de la Facturation et de la Comptabilité
    # naissent des événements (`Partiduo::Stock::Feeds`, D-STK-004).
    module Stock
      MODULE_CODE    = "STOCK"
      READ           = "stock.movement.read"
      WRITE          = "stock.movement.write"
      SETTINGS_WRITE = "stock.settings.write"

      # --- Paramètres ------------------------------------------------------------------

      def self.settings(actor : Actor) : SettingsView
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        settings_view
      end

      def self.update_settings(actor : Actor, input : SettingsInput) : Result(SettingsView)
        Guard.authorize!(actor, SETTINGS_WRITE, module_code: MODULE_CODE)
        Transaction.run do
          repository = nil
          if id = input.default_repository_id
            repository = Partiduo::Stock::Repository.filter(id: id).first
            if repository.nil?
              next Result(SettingsView).failure(Partiduo::Stock::Rules.error("default_repository_id", "settings",
                "repository_unknown", {"id" => id.to_s}))
            end
          end
          setting = Partiduo::Stock::Movements.setting
          setting.default_repository = repository
          setting.save!
          Result(SettingsView).success(settings_view)
        end
      end

      private def self.settings_view : SettingsView
        repository = Partiduo::Stock::Movements.default_repository
        SettingsView.new(repository.try(&.pk!.as(Int64)), repository.try(&.name!))
      end

      # --- Dépôts ----------------------------------------------------------------------

      def self.repositories(actor : Actor) : Array(RepositoryView)
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        counts = Partiduo::Stock::Movements.movement_counts
        Partiduo::Stock::Repository.all.order(:name).to_a.map { |row| Partiduo::Stock::Movements.repository_view(row, counts) }
      end

      def self.repository(actor : Actor, id : Int64) : RepositoryView
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        Partiduo::Stock::Movements.repository_view(find_repository(id))
      end

      def self.check_repository(actor : Actor, input : RepositoryInput, id : Int64? = nil) : Result(Nil)
        Guard.authorize!(actor, SETTINGS_WRITE, module_code: MODULE_CODE)
        errors = Partiduo::Stock::Rules.repository_errors(input, id)
        errors.empty? ? Result(Nil).success(nil) : Result(Nil).failure(errors)
      end

      # Le premier dépôt devient le dépôt par défaut.
      def self.create_repository(actor : Actor, input : RepositoryInput) : Result(RepositoryView)
        Guard.authorize!(actor, SETTINGS_WRITE, module_code: MODULE_CODE)
        Transaction.run do
          lock_references
          errors = Partiduo::Stock::Rules.repository_errors(input)
          next Result(RepositoryView).failure(errors) unless errors.empty?
          repository = Partiduo::Stock::Rules.assign(Partiduo::Stock::Repository.new, input)
          repository.save!
          Partiduo::Stock::Movements.adopt_default(repository)
          Result(RepositoryView).success(Partiduo::Stock::Movements.repository_view(repository))
        end
      end

      def self.update_repository(actor : Actor, id : Int64, input : RepositoryInput) : Result(RepositoryView)
        Guard.authorize!(actor, SETTINGS_WRITE, module_code: MODULE_CODE)
        Transaction.run do
          lock_references
          repository = find_repository(id)
          errors = Partiduo::Stock::Rules.repository_errors(input, id)
          next Result(RepositoryView).failure(errors) unless errors.empty?
          Partiduo::Stock::Rules.assign(repository, input).save!
          Result(RepositoryView).success(Partiduo::Stock::Movements.repository_view(repository))
        end
      end

      # Refusé si le dépôt porte des mouvements ou des opérations
      # (`stock_goods`, `stock_change`) ; dépôt par défaut : le paramètre
      # revient à vide.
      def self.delete_repository(actor : Actor, id : Int64) : Result(Nil)
        Guard.authorize!(actor, SETTINGS_WRITE, module_code: MODULE_CODE)
        Transaction.run do
          repository = find_repository(id)
          if Partiduo::Stock::Movement.filter(repository_id: id).exists? ||
             Partiduo::Stock::Change.filter(repository_id: id).exists?
            next Result(Nil).failure(Partiduo::Stock::Rules.error(FieldError::BASE, "repository", "in_use"))
          end
          repository.delete
          Result(Nil).success(nil)
        end
      end

      # --- Articles suivis ---------------------------------------------------------------

      def self.items(actor : Actor) : Array(ItemView)
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        Partiduo::Stock::Movements.item_views(Partiduo::Stock::Item.all.to_a)
      end

      # Article suivi d'une fiche, ou `nil`.
      def self.item(actor : Actor, card_id : Int64) : ItemView?
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        item = Partiduo::Stock::Item.filter(card_id: card_id).first || return
        Partiduo::Stock::Movements.item_views([item]).first?
      end

      # Suit une fiche article en stock, ou change son code stock ; code vide
      # = quick code de la fiche. Les mouvements passés gardent leur code.
      def self.track_item(actor : Actor, input : ItemInput) : Result(ItemView)
        Guard.authorize!(actor, SETTINGS_WRITE, module_code: MODULE_CODE)
        Transaction.run do
          # Verrou par fiche : deux suivis concurrents de la même fiche
          # s'enchaînent (le second met à jour) au lieu de violer l'unicité.
          Marten::DB::Connection.default.open(&.exec("SELECT pg_advisory_xact_lock(hashtext($1))", "stock_item:#{input.card_id}"))
          errors = Partiduo::Stock::Rules.item_errors(input)
          next Result(ItemView).failure(errors) unless errors.empty?
          card = Partiduo::Stock::Cards.card(input.card_id) || raise NotFound.new("card", input.card_id)
          code = Partiduo::Stock::Rules.effective_code(input, card)
          item = Partiduo::Stock::Item.filter(card_id: input.card_id).first || Partiduo::Stock::Item.new(card_id: input.card_id)
          item.stock_code = code
          item.save!
          Result(ItemView).success(Partiduo::Stock::Movements.item_views([item]).first)
        end
      end

      # Cesse de suivre la fiche : ses mouvements restent.
      def self.untrack_item(actor : Actor, card_id : Int64) : Result(Nil)
        Guard.authorize!(actor, SETTINGS_WRITE, module_code: MODULE_CODE)
        Transaction.run do
          item = Partiduo::Stock::Item.filter(card_id: card_id).first || raise NotFound.new("stock_item", card_id)
          item.delete
          Result(Nil).success(nil)
        end
      end

      # --- Opérations manuelles -------------------------------------------------------------

      def self.check_change(actor : Actor, input : ChangeInput) : Result(Nil)
        Guard.authorize!(actor, WRITE, module_code: MODULE_CODE)
        errors = Partiduo::Stock::Rules.change_errors(input)
        errors.empty? ? Result(Nil).success(nil) : Result(Nil).failure(errors)
      end

      # Mouvements saisis (`Stock_Goods::record_save`) : quantité positive =
      # entrée, négative = sortie ; refusé dans une période close.
      def self.record_change(actor : Actor, input : ChangeInput) : Result(ChangeView)
        Guard.authorize!(actor, WRITE, module_code: MODULE_CODE)
        Transaction.run do
          errors = Partiduo::Stock::Rules.change_errors(input)
          next Result(ChangeView).failure(errors) unless errors.empty?
          change = create_change("change", input.repository_id, input.date, input.comment, actor)
          items = Partiduo::Stock::Movements.items_by_card(input.lines.map(&.card_id))
          rows = input.lines
          rows.each do |line|
            direction = line.quantity > 0 ? "in" : "out"
            Partiduo::Stock::Movements.create!(input.repository_id, items[line.card_id], direction, line.quantity.abs,
              input.date, unit_cost: line.unit_cost, comment: change.comment.to_s, change: change,
              created_by_id: actor.user_id)
          end
          Result(ChangeView).success(Partiduo::Stock::Movements.change_view(change))
        end
      end

      # Quantités théoriques d'un dépôt au jour `date` pour chaque code
      # stock suivi : point de départ d'un inventaire (`take_last_inventory`).
      def self.inventory_proposal(actor : Actor, repository_id : Int64, date : Time) : Array(InventoryLineView)
        Guard.authorize!(actor, WRITE, module_code: MODULE_CODE)
        find_repository(repository_id)
        Partiduo::Stock::Movements.inventory_proposal(repository_id, date)
      end

      def self.check_inventory(actor : Actor, input : InventoryInput) : Result(Nil)
        Guard.authorize!(actor, WRITE, module_code: MODULE_CODE)
        errors = Partiduo::Stock::Rules.inventory_errors(input)
        errors.empty? ? Result(Nil).success(nil) : Result(Nil).failure(errors)
      end

      # Inventaire : pour chaque code stock compté, l'écart entre la quantité
      # comptée et la quantité théorique du dépôt au jour de l'inventaire
      # devient un mouvement (entrée ou sortie) ; aucun mouvement sans écart.
      def self.record_inventory(actor : Actor, input : InventoryInput) : Result(ChangeView)
        Guard.authorize!(actor, WRITE, module_code: MODULE_CODE)
        Transaction.run do
          lock_inventory(input.repository_id)
          errors = Partiduo::Stock::Rules.inventory_errors(input)
          next Result(ChangeView).failure(errors) unless errors.empty?
          change = create_change("inventory", input.repository_id, input.date, input.comment, actor)
          items = Partiduo::Stock::Movements.items_by_card(input.lines.map(&.card_id))
          rows = input.lines
          rows.each do |line|
            item = items[line.card_id]
            theoretical = Partiduo::Stock::Movements.quantity_on(input.repository_id, item.stock_code!, input.date)
            difference = line.counted - theoretical
            next if difference.zero?
            direction = difference > 0 ? "in" : "out"
            Partiduo::Stock::Movements.create!(input.repository_id, item, direction, difference.abs, input.date,
              unit_cost: direction == "in" ? line.unit_cost : nil, comment: change.comment.to_s, change: change,
              created_by_id: actor.user_id)
          end
          Result(ChangeView).success(Partiduo::Stock::Movements.change_view(change))
        end
      end

      def self.changes(actor : Actor, query : ChangeQuery = ChangeQuery.new) : Array(ChangeView)
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        changes = Partiduo::Stock::Change.all
        query.repository_id.try { |id| changes = changes.filter(repository_id: id) }
        query.date_from.try { |date| changes = changes.filter(date__gte: Partiduo::Stock::Movements.day(date)) }
        query.date_to.try { |date| changes = changes.filter(date__lte: Partiduo::Stock::Movements.day(date)) }
        query.kind.try { |kind| changes = changes.filter(kind: kind) }
        changes.order(:date, :id).to_a.map { |change| Partiduo::Stock::Movements.change_view(change) }
      end

      def self.change(actor : Actor, id : Int64) : ChangeView
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        Partiduo::Stock::Movements.change_view(find_change(id))
      end

      # Supprime l'opération et ses mouvements (`stock_inv_histo`) ; refusé
      # dans une période close.
      def self.delete_change(actor : Actor, id : Int64) : Result(Nil)
        Guard.authorize!(actor, WRITE, module_code: MODULE_CODE)
        Transaction.run do
          change = Partiduo::Stock::Change.filter(id: id).lock.first || raise NotFound.new("stock_change", id)
          if Partiduo::Stock::Movements.closed_on?(change.date!)
            next Result(Nil).failure(Partiduo::Stock::Rules.error(FieldError::BASE, "change", "closed_period",
              {"date" => change.date!.to_s("%Y-%m-%d")}))
          end
          Partiduo::Stock::Movement.filter(change_id: id).delete
          change.delete
          Result(Nil).success(nil)
        end
      end

      # --- Historique, état, valorisation -------------------------------------------------------

      def self.movements(actor : Actor, query : MovementQuery = MovementQuery.new) : Array(MovementView)
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        Partiduo::Stock::Movements.history(query)
      end

      def self.count_movements(actor : Actor, query : MovementQuery = MovementQuery.new) : Int64
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        Partiduo::Stock::Movements.history_query(query).count.to_i64
      end

      # Quantité en stock d'une fiche suivie (son code stock) au jour `date`,
      # dans un dépôt ou dans tous.
      def self.quantity(actor : Actor, card_id : Int64, date : Time = Partiduo::Config.today,
                        repository_id : Int64? = nil) : BigDecimal
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        item = Partiduo::Stock::Item.filter(card_id: card_id).first || raise NotFound.new("stock_item", card_id)
        ids = repository_id ? [repository_id] : Partiduo::Stock::Repository.all.to_a.map(&.pk!.as(Int64))
        ids.sum(BigDecimal.new(0)) { |id| Partiduo::Stock::Movements.quantity_on(id, item.stock_code!, date) }
      end

      def self.state(actor : Actor, query : StateQuery) : StateView
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        Partiduo::Stock::Movements.state(query)
      end

      def self.valuation(actor : Actor, date : Time = Partiduo::Config.today, repository_id : Int64? = nil) : ValuationView
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        Partiduo::Stock::Movements.valuation(date, repository_id)
      end

      # Exports CSV (sans plafond de lignes).
      def self.export_movements(actor : Actor, query : MovementQuery = MovementQuery.new) : FileView
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        rows = Partiduo::Stock::Movements.history_query(query).order(:date, :id).to_a
        Partiduo::Stock::Exports.history(Partiduo::Stock::Movements.views(rows))
      end

      def self.export_state(actor : Actor, query : StateQuery) : FileView
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        Partiduo::Stock::Exports.state(Partiduo::Stock::Movements.state(query))
      end

      def self.export_valuation(actor : Actor, date : Time = Partiduo::Config.today, repository_id : Int64? = nil) : FileView
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        Partiduo::Stock::Exports.valuation(Partiduo::Stock::Movements.valuation(date, repository_id))
      end

      # --- Interne ---------------------------------------------------------------------------

      private def self.create_change(kind : String, repository_id : Int64, date : Time, comment : String,
                                     actor : Actor) : Partiduo::Stock::Change
        Partiduo::Stock::Change.create!(kind: kind, repository_id: repository_id,
          date: Partiduo::Stock::Movements.day(date), comment: comment.strip, created_by_id: actor.user_id)
      end

      # Sérialise les créations et renommages de dépôts (unicité du nom sans
      # casse, la contrainte en base restant le dernier rempart).
      private def self.lock_references : Nil
        Marten::DB::Connection.default.open(&.exec("SELECT pg_advisory_xact_lock(hashtext('stock_repository'))"))
      end

      # Deux inventaires concurrents d'un même dépôt calculeraient leurs
      # écarts sur la même quantité théorique.
      private def self.lock_inventory(repository_id : Int64) : Nil
        Marten::DB::Connection.default.open(&.exec("SELECT pg_advisory_xact_lock(hashtext('stock_inventory'), $1::int)",
          repository_id.to_i32))
      end

      private def self.find_repository(id : Int64) : Partiduo::Stock::Repository
        Partiduo::Stock::Repository.filter(id: id).first || raise NotFound.new("stock_repository", id)
      end

      private def self.find_change(id : Int64) : Partiduo::Stock::Change
        Partiduo::Stock::Change.filter(id: id).first || raise NotFound.new("stock_change", id)
      end
    end
  end
end
