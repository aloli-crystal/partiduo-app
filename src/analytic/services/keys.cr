# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Analytic
    # Clés de répartition (`Anc_Key`) : validation, enregistrement,
    # application à un montant (`fill_table`). Service interne.
    module Keys
      alias FieldError = Partiduo::Api::FieldError
      alias Api = Partiduo::Api::Analytic

      HUNDRED = BigDecimal.new(100)
      ZERO    = BigDecimal.new(0)

      def self.errors(input : Api::KeyInput, ledger_exists : Int64 -> Bool) : Array(FieldError)
        errors = header_errors(input)
        posts = Post.filter(id__in: input.rows.flat_map(&.post_ids).uniq!).to_a.index_by(&.pk!.as(Int64))
        input.rows.each_with_index { |row, index| errors.concat(row_errors("rows[#{index}]", row, posts)) }
        total = input.rows.sum(ZERO, &.percent)
        if !input.rows.empty? && total != HUNDRED
          errors << FieldError.new("rows", "analytic.errors.key.total", {"total" => total.to_s.sub(/\.0+$/, "")})
        end
        input.ledger_ids.each_with_index do |ledger_id, index|
          next if ledger_exists.call(ledger_id)
          errors << FieldError.new("ledger_ids[#{index}]", "analytic.errors.key.ledger_unknown", {"id" => ledger_id.to_s})
        end
        errors
      end

      private def self.header_errors(input : Api::KeyInput) : Array(FieldError)
        errors = [] of FieldError
        name = input.name.strip
        if name.empty?
          errors << FieldError.new("name", "analytic.errors.key.name_required")
        elsif name.size > 100
          errors << FieldError.new("name", "analytic.errors.key.name_too_long", {"max" => "100"})
        end
        errors << FieldError.new("rows", "analytic.errors.key.rows_required") if input.rows.empty?
        errors
      end

      private def self.row_errors(path : String, row : Api::KeyRowInput, posts : Hash(Int64, Post)) : Array(FieldError)
        errors = [] of FieldError
        if row.percent <= 0 || row.percent > HUNDRED
          errors << FieldError.new("#{path}.percent", "analytic.errors.key.percent_invalid")
        elsif row.percent.scale > 4
          errors << FieldError.new("#{path}.percent", "analytic.errors.key.percent_scale")
        end
        errors << FieldError.new("#{path}.post_ids", "analytic.errors.key.post_required") if row.post_ids.empty?
        plans = Set(Int64).new
        row.post_ids.each do |post_id|
          post = posts[post_id]?
          if post.nil?
            errors << FieldError.new("#{path}.post_ids", "analytic.errors.post.unknown", {"id" => post_id.to_s})
          elsif !plans.add?(post.plan_id!.as(Int).to_i64)
            errors << FieldError.new("#{path}.post_ids", "analytic.errors.distribution.plan_twice")
          end
        end
        errors
      end

      # Remplace nom, lignes et journaux de la clé.
      def self.save!(key : Key, input : Api::KeyInput) : Key
        key.name = input.name.strip
        key.description = input.description.strip
        key.save!
        KeyRow.filter(key_id: key.pk).delete
        KeyLedger.filter(key_id: key.pk).delete
        posts = Post.filter(id__in: input.rows.flat_map(&.post_ids).uniq!).to_a.index_by(&.pk!.as(Int64))
        input.rows.each_with_index do |row_input, index|
          row = KeyRow.create!(key: key, position: index, percent: row_input.percent)
          row_input.post_ids.each do |post_id|
            post = posts[post_id]
            KeyRowPost.create!(row: row, plan_id: post.plan_id, post: post)
          end
        end
        input.ledger_ids.uniq.each { |ledger_id| KeyLedger.create!(key: key, ledger_id: ledger_id) }
        key
      end

      def self.view(key : Key) : Api::KeyView
        rows = KeyRow.filter(key_id: key.pk).order(:position).to_a
        links = rows.empty? ? [] of KeyRowPost : KeyRowPost.filter(row_id__in: rows.map(&.pk!)).to_a
        refs = Plans.refs(links.map(&.post_id!.as(Int).to_i64))
        by_row = links.group_by(&.row_id!.as(Int).to_i64)
        row_views = rows.map do |row|
          id = row.pk!.as(Int64)
          posts = (by_row[id]? || [] of KeyRowPost).compact_map { |link| refs[link.post_id!.as(Int).to_i64]? }
          Api::KeyRowView.new(id, (row.position || 0).to_i32, row.percent!, posts.sort_by!(&.plan_id))
        end
        ledgers = KeyLedger.filter(key_id: key.pk).to_a.map(&.ledger_id!.as(Int).to_i64).sort!
        Api::KeyView.new(key.pk!.as(Int64), key.name.to_s, key.description.to_s, row_views, ledgers)
      end

      # Lignes de ventilation d'un montant selon la clé : montant × % / 100
      # arrondi au centime, la dernière ligne recevant l'écart d'arrondi
      # (D-ANA-004). Le signe du montant est ignoré. Une ligne ne reçoit
      # jamais plus que le reste à répartir : quelques centimes répartis sur
      # beaucoup de lignes ne donnent pas de montant négatif (D-ANA-011).
      def self.apply(key : Api::KeyView, amount : BigDecimal) : Array(Api::DistributionRowInput)
        total = amount.abs
        rows = [] of Api::DistributionRowInput
        allocated = ZERO
        key.rows.each_with_index do |row, index|
          value = if index == key.rows.size - 1
                    total - allocated
                  else
                    {(total * row.percent / HUNDRED).round(2, mode: :ties_away), total - allocated}.min
                  end
          allocated += value
          rows << Api::DistributionRowInput.new(value, row.posts.map(&.id))
        end
        rows.reject(&.amount.zero?)
      end
    end
  end
end
