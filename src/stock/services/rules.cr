# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Stock
    # Règles de saisie du module Stock (dépôts, articles suivis, opérations
    # manuelles, inventaires) : erreurs par champ, clés
    # `stock.errors.<objet>.<code>`. Service interne.
    module Rules
      alias FieldError = Partiduo::Api::FieldError
      alias Api = Partiduo::Api::Stock

      MAX_SCALE = 4
      ZERO      = BigDecimal.new(0)

      def self.error(field : String, object : String, code : String, params = {} of String => String) : FieldError
        FieldError.new(field, "stock.errors.#{object}.#{code}", params)
      end

      # --- Dépôts ---------------------------------------------------------------------

      def self.repository_errors(input : Api::RepositoryInput, id : Int64? = nil) : Array(FieldError)
        errors = [] of FieldError
        name = input.name.strip
        if name.empty?
          errors << error("name", "repository", "name_required")
        elsif name.size > 100
          errors << error("name", "repository", "name_too_long", {"max" => "100"})
        else
          taken = Repository.filter(name__iexact: name)
          taken = taken.exclude(id: id) if id
          errors << error("name", "repository", "name_taken", {"name" => name}) if taken.exists?
        end
        country = input.country_code.strip
        unless country.empty? || country.matches?(/\A[A-Za-z]{2}\z/)
          errors << error("country_code", "repository", "country_invalid")
        end
        errors << error("city", "repository", "too_long", {"max" => "100"}) if input.city.strip.size > 100
        errors << error("phone", "repository", "too_long", {"max" => "40"}) if input.phone.strip.size > 40
        errors
      end

      def self.assign(repository : Repository, input : Api::RepositoryInput) : Repository
        repository.name = input.name.strip
        repository.address = input.address.strip
        repository.city = input.city.strip
        repository.country_code = input.country_code.strip.upcase
        repository.phone = input.phone.strip
        repository
      end

      # --- Articles suivis ----------------------------------------------------------

      def self.normalize_code(code : String) : String
        code.strip.upcase
      end

      # Code stock effectif : celui saisi, sinon le code de la fiche, tous
      # deux normalisés ; c'est ce code que valide `item_errors`.
      def self.effective_code(input : Api::ItemInput, card : Cards::Info?) : String
        normalize_code(input.stock_code).presence || normalize_code(card.try(&.code) || "")[0, 40]
      end

      # Fiche de nature `item`, code stock effectif (saisi ou repris de la
      # fiche) de 40 caractères au plus, sans espace.
      def self.item_errors(input : Api::ItemInput) : Array(FieldError)
        errors = [] of FieldError
        card = Cards.card(input.card_id)
        if card.nil?
          errors << error("card_id", "item", "card_unknown", {"id" => input.card_id.to_s})
        elsif card.kind != "item"
          errors << error("card_id", "item", "not_an_item", {"code" => card.code})
        end
        code = effective_code(input, card)
        errors << error("stock_code", "item", "too_long", {"max" => "40"}) if code.size > 40
        errors << error("stock_code", "item", "invalid") if code.matches?(/\s/)
        errors
      end

      # --- Opérations manuelles -------------------------------------------------------

      def self.header_errors(repository_id : Int64, date : Time, comment : String) : Array(FieldError)
        errors = [] of FieldError
        unless Repository.filter(id: repository_id).exists?
          errors << error("repository_id", "change", "repository_unknown", {"id" => repository_id.to_s})
        end
        if Movements.closed_on?(date)
          errors << error("date", "change", "closed_period", {"date" => date.to_s("%Y-%m-%d")})
        end
        errors << error("comment", "change", "too_long", {"max" => "1000"}) if comment.strip.size > 1000
        errors
      end

      def self.change_errors(input : Api::ChangeInput) : Array(FieldError)
        errors = header_errors(input.repository_id, input.date, input.comment)
        errors << error("lines", "change", "lines_required") if input.lines.empty?
        items = Movements.items_by_card(input.lines.map(&.card_id))
        input.lines.each_with_index do |line, index|
          path = "lines[#{index}]"
          errors.concat(card_errors(path, line.card_id, items))
          if line.quantity.zero?
            errors << error("#{path}.quantity", "change", "quantity_zero")
          elsif line.quantity.scale > MAX_SCALE
            errors << error("#{path}.quantity", "change", "quantity_scale", {"max" => MAX_SCALE.to_s})
          end
          errors.concat(cost_errors(path, line.unit_cost, line.quantity > 0))
        end
        errors
      end

      def self.inventory_errors(input : Api::InventoryInput) : Array(FieldError)
        errors = header_errors(input.repository_id, input.date, input.comment)
        errors << error("lines", "inventory", "lines_required") if input.lines.empty?
        items = Movements.items_by_card(input.lines.map(&.card_id))
        seen = Set(String).new
        input.lines.each_with_index do |line, index|
          path = "lines[#{index}]"
          errors.concat(card_errors(path, line.card_id, items))
          # Une quantité comptée par code stock (plusieurs fiches peuvent
          # partager un code).
          if (item = items[line.card_id]?) && !seen.add?(item.stock_code!)
            errors << error("#{path}.card_id", "inventory", "code_twice", {"code" => item.stock_code!})
          end
          if line.counted < 0
            errors << error("#{path}.counted", "inventory", "counted_negative")
          elsif line.counted.scale > MAX_SCALE
            errors << error("#{path}.counted", "change", "quantity_scale", {"max" => MAX_SCALE.to_s})
          end
          errors.concat(cost_errors(path, line.unit_cost, true))
        end
        errors
      end

      private def self.card_errors(path : String, card_id : Int64, items : Hash(Int64, Item)) : Array(FieldError)
        return [] of FieldError if items.has_key?(card_id)
        [error("#{path}.card_id", "change", "not_tracked", {"id" => card_id.to_s})]
      end

      private def self.cost_errors(path : String, cost : BigDecimal?, entry : Bool) : Array(FieldError)
        return [] of FieldError if cost.nil?
        errors = [] of FieldError
        if !entry
          errors << error("#{path}.unit_cost", "change", "cost_on_exit")
        elsif cost < 0
          errors << error("#{path}.unit_cost", "change", "cost_negative")
        elsif cost.scale > MAX_SCALE
          errors << error("#{path}.unit_cost", "change", "cost_scale", {"max" => MAX_SCALE.to_s})
        end
        errors
      end
    end

    # Lecture des fiches du socle (nom, quick code, nature) en bloc.
    module Cards
      record Info, id : Int64, code : String, name : String, kind : String

      def self.card(id : Int64) : Info?
        by_id([id])[id]?
      end

      def self.by_id(ids : Array(Int64)) : Hash(Int64, Info)
        found = {} of Int64 => Info
        return found if ids.empty?
        Marten::DB::Connection.default.open do |db|
          db.query("SELECT c.id, c.code, c.name, k.kind FROM cards_card c JOIN cards_category k ON k.id = c.category_id " \
                   "WHERE c.id = ANY($1)", args: [ids.uniq]) do |result_set|
            result_set.each do
              info = Info.new(result_set.read(Int64), result_set.read(String), result_set.read(String), result_set.read(String))
              found[info.id] = info
            end
          end
        end
        found
      end
    end
  end
end
