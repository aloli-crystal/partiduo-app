# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Analytic
    # Plans, groupes et postes (`Anc_Plan`, `Anc_Group`, `Anc_Account_Table`,
    # déclencheurs `plan_analytic_ins_upd`, `group_analytic_ins_upd`,
    # `poste_analytique_ins_upd`). Service interne.
    module Plans
      alias FieldError = Partiduo::Api::FieldError
      alias Api = Partiduo::Api::Analytic

      # `Anc_Plan::isAppend` (D-ANA-003).
      MAX_PLANS = 10

      GROUP_CODE_MAX = 10

      # Nom de plan, code de groupe : majuscules, sans espace.
      def self.normalize(text : String) : String
        text.upcase.gsub(/\s+/, "")
      end

      # Code de poste : en plus, sans `'`, `<`, `>`.
      def self.normalize_post(text : String) : String
        normalize(text).delete("'<>")
      end

      # --- Validation ----------------------------------------------------------------

      def self.plan_errors(input : Api::PlanInput, id : Int64? = nil) : Array(FieldError)
        errors = [] of FieldError
        name = normalize(input.name)
        if name.empty?
          errors << FieldError.new("name", "analytic.errors.plan.name_required")
        elsif name.size > 100
          errors << FieldError.new("name", "analytic.errors.plan.name_too_long", {"max" => "100"})
        elsif Plan.filter(name: name).exclude(id: id || 0_i64).exists?
          errors << FieldError.new("name", "analytic.errors.plan.name_taken", {"name" => name})
        end
        if id.nil? && Plan.all.count >= MAX_PLANS
          errors << FieldError.base("analytic.errors.plan.limit", {"max" => MAX_PLANS.to_s})
        end
        errors
      end

      def self.group_errors(input : Api::GroupInput, id : Int64? = nil) : Array(FieldError)
        errors = [] of FieldError
        errors << FieldError.new("plan_id", "analytic.errors.plan.unknown") unless Plan.filter(id: input.plan_id).exists?
        code = normalize(input.code)
        if code.empty?
          errors << FieldError.new("code", "analytic.errors.group.code_required")
        elsif code.size > GROUP_CODE_MAX
          errors << FieldError.new("code", "analytic.errors.group.code_too_long", {"max" => GROUP_CODE_MAX.to_s})
        elsif Group.filter(plan_id: input.plan_id, code: code).exclude(id: id || 0_i64).exists?
          errors << FieldError.new("code", "analytic.errors.group.code_taken", {"code" => code})
        end
        errors
      end

      def self.post_errors(input : Api::PostInput, id : Int64? = nil) : Array(FieldError)
        errors = [] of FieldError
        errors << FieldError.new("plan_id", "analytic.errors.plan.unknown") unless Plan.filter(id: input.plan_id).exists?
        code = normalize_post(input.code)
        if code.empty?
          errors << FieldError.new("code", "analytic.errors.post.code_required")
        elsif code.size > 100
          errors << FieldError.new("code", "analytic.errors.post.code_too_long", {"max" => "100"})
        elsif Post.filter(plan_id: input.plan_id, code: code).exclude(id: id || 0_i64).exists?
          errors << FieldError.new("code", "analytic.errors.post.code_taken", {"code" => code})
        end
        if group_id = input.group_id
          group = Group.filter(id: group_id).first
          if group.nil?
            errors << FieldError.new("group_id", "analytic.errors.group.unknown")
          elsif group.plan_id != input.plan_id
            errors << FieldError.new("group_id", "analytic.errors.post.group_plan")
          end
        end
        errors
      end

      # --- Périodes closes -------------------------------------------------------------

      # Le poste (ou un poste du plan) porte-t-il une imputation d'une période
      # close ? (`Anc_Account_Table::delete`).
      def self.used_in_closed_period?(post_ids : Array(Int64)) : Bool
        return false if post_ids.empty?
        Marten::DB::Connection.default.open do |db|
          db.scalar(<<-SQL, args: [post_ids]).as(Bool)
            SELECT EXISTS (
              SELECT 1 FROM analytic_operation o
              JOIN analytic_distribution d ON d.id = o.distribution_id
              WHERE o.post_id = ANY($1) AND analytic_date_closed(d.date))
            SQL
        end
      end

      # Imputations restées sans opération après la suppression d'un poste
      # ou d'un plan.
      def self.delete_empty_distributions : Nil
        Marten::DB::Connection.default.open do |db|
          db.exec(<<-SQL)
            DELETE FROM analytic_distribution d
            WHERE NOT EXISTS (SELECT 1 FROM analytic_operation o WHERE o.distribution_id = d.id)
            SQL
        end
      end

      # Lignes de clé restées sans poste après la suppression d'un poste ou
      # d'un plan : retirées ; la clé, dont le total n'atteint plus 100 %,
      # apparaît incomplète (`KeyView#complete?`) et n'est plus appliquée
      # tant qu'elle n'est pas corrigée (D-ANA-013).
      def self.delete_empty_key_rows : Nil
        Marten::DB::Connection.default.open do |db|
          db.exec(<<-SQL)
            DELETE FROM analytic_key_row r
            WHERE NOT EXISTS (SELECT 1 FROM analytic_key_row_post p WHERE p.row_id = r.id)
            SQL
        end
      end

      # --- Vues ------------------------------------------------------------------------

      def self.plan_view(plan : Plan) : Api::PlanView
        plan_views([plan]).first
      end

      # Plans et leurs nombres de postes et de groupes, comptés en une
      # requête par table (pas une par plan).
      def self.plan_views(plans : Array(Plan)) : Array(Api::PlanView)
        ids = plans.map(&.pk!.as(Int64))
        posts = counts("analytic_post", "plan_id", ids)
        groups = counts("analytic_group", "plan_id", ids)
        plans.map do |plan|
          id = plan.pk!.as(Int64)
          Api::PlanView.new(id, plan.name.to_s, plan.description.to_s, (posts[id]? || 0_i64).to_i32,
            (groups[id]? || 0_i64).to_i32)
        end
      end

      def self.group_view(group : Group) : Api::GroupView
        group_views([group]).first
      end

      def self.group_views(groups : Array(Group)) : Array(Api::GroupView)
        posts = counts("analytic_post", "group_id", groups.map(&.pk!.as(Int64)))
        groups.map do |group|
          id = group.pk!.as(Int64)
          Api::GroupView.new(id, group.plan_id!.as(Int).to_i64, group.code.to_s, group.description.to_s,
            (posts[id]? || 0_i64).to_i32)
        end
      end

      # Nombre de lignes de `table` par valeur de `column` (noms fixes,
      # jamais saisis).
      private def self.counts(table : String, column : String, ids : Array(Int64)) : Hash(Int64, Int64)
        result = {} of Int64 => Int64
        return result if ids.empty?
        Marten::DB::Connection.default.open do |db|
          db.query("SELECT #{column}, count(*) FROM #{table} WHERE #{column} = ANY($1) GROUP BY #{column}", args: [ids]) do |result_set|
            result_set.each { result[result_set.read(Int64)] = result_set.read(Int64) }
          end
        end
        result
      end

      def self.post_views(posts : Array(Post)) : Array(Api::PostView)
        return [] of Api::PostView if posts.empty?
        ids = posts.map(&.pk!.as(Int64))
        plans = Plan.filter(id__in: posts.map(&.plan_id!.as(Int).to_i64).uniq!).to_a.to_h { |plan| {plan.pk!.as(Int64), plan.name.to_s} }
        group_ids = posts.compact_map(&.group_id.try(&.as(Int).to_i64)).uniq!
        groups = group_ids.empty? ? {} of Int64 => String : Group.filter(id__in: group_ids).to_a.to_h { |group| {group.pk!.as(Int64), group.code.to_s} }
        counts = operation_counts(ids)
        posts.map do |post|
          id = post.pk!.as(Int64)
          plan_id = post.plan_id!.as(Int).to_i64
          group_id = post.group_id.try(&.as(Int).to_i64)
          Api::PostView.new(
            id: id, plan_id: plan_id, plan_name: plans[plan_id]? || "", code: post.code.to_s,
            description: post.description.to_s, group_id: group_id, group_code: group_id.try { |gid| groups[gid]? },
            active: post.active || false, operations_count: counts[id]? || 0_i64,
          )
        end
      end

      def self.post_ref(post : Post) : Api::PostRef
        Api::PostRef.new(post.pk!.as(Int64), post.plan_id!.as(Int).to_i64, post.code.to_s, post.description.to_s)
      end

      # Références des postes cités, par identifiant.
      def self.refs(ids : Enumerable(Int64)) : Hash(Int64, Api::PostRef)
        list = ids.to_a.uniq
        return {} of Int64 => Api::PostRef if list.empty?
        Post.filter(id__in: list).to_a.to_h { |post| {post.pk!.as(Int64), post_ref(post)} }
      end

      private def self.operation_counts(ids : Array(Int64)) : Hash(Int64, Int64)
        counts = {} of Int64 => Int64
        Marten::DB::Connection.default.open do |db|
          db.query("SELECT post_id, count(*) FROM analytic_operation WHERE post_id = ANY($1) GROUP BY post_id", args: [ids]) do |result_set|
            result_set.each { counts[result_set.read(Int64)] = result_set.read(Int64) }
          end
        end
        counts
      end
    end
  end
end
