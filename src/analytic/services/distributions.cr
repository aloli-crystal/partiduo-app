# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Analytic
    # Ventilation des lignes d'écriture (`Anc_Operation::save_form_plan`,
    # `save_update_form`) et opérations diverses analytiques
    # (`Anc_Group_Operation`). Service interne : la ligne, son écriture et son
    # journal sont lus par le contrat de la Comptabilité, jamais par ses
    # tables.
    module Distributions
      alias FieldError = Partiduo::Api::FieldError
      alias Api = Partiduo::Api::Analytic
      alias AccountingApi = Partiduo::Api::Accounting

      ZERO      = BigDecimal.new(0)
      MAX_SCALE = 4

      # --- Règles des lignes de ventilation ------------------------------------------

      # Postes cités par des lignes (ventilations ou opérations diverses).
      def self.posts_for(post_ids : Enumerable(Int64)) : Hash(Int64, Post)
        list = post_ids.to_a.uniq
        return {} of Int64 => Post if list.empty?
        Post.filter(id__in: list).to_a.index_by(&.pk!.as(Int64))
      end

      # Contrôle d'une ligne : montant, postes connus et actifs (sauf déjà
      # imputés à cette ventilation), un seul poste par plan. Renvoie les
      # erreurs sous `path`.
      def self.row_errors(path : String, amount : BigDecimal, post_ids : Array(Int64), posts : Hash(Int64, Post),
                          allowed : Set(Int64)) : Array(FieldError)
        errors = [] of FieldError
        if amount <= 0
          errors << FieldError.new("#{path}.amount", "analytic.errors.distribution.amount_invalid")
        elsif amount.scale > MAX_SCALE
          errors << FieldError.new("#{path}.amount", "analytic.errors.distribution.amount_scale",
            {"max" => MAX_SCALE.to_s})
        end
        errors << FieldError.new("#{path}.post_ids", "analytic.errors.distribution.post_required") if post_ids.empty?
        plans = Set(Int64).new
        post_ids.each do |post_id|
          post = posts[post_id]?
          if post.nil?
            errors << FieldError.new("#{path}.post_ids", "analytic.errors.post.unknown", {"id" => post_id.to_s})
          elsif !plans.add?(post.plan_id!.as(Int).to_i64)
            errors << FieldError.new("#{path}.post_ids", "analytic.errors.distribution.plan_twice")
          elsif !post.active && !allowed.includes?(post_id)
            errors << FieldError.new("#{path}.post_ids", "analytic.errors.distribution.post_inactive",
              {"code" => post.code.to_s})
          end
        end
        errors
      end

      # Totaux par plan d'une ventilation.
      def self.plan_totals(rows : Array(Api::DistributionRowInput), posts : Hash(Int64, Post)) : Hash(Int64, BigDecimal)
        totals = Hash(Int64, BigDecimal).new { ZERO }
        rows.each do |row|
          row.post_ids.each do |post_id|
            post = posts[post_id]? || next
            plan_id = post.plan_id!.as(Int).to_i64
            totals[plan_id] = totals[plan_id] + row.amount
          end
        end
        totals
      end

      # --- Ventilation d'une écriture ------------------------------------------------

      # Règles de ventilation des lignes `inputs` de l'écriture `entry` :
      # ligne de l'écriture et compte ventilé, période ouverte, lignes
      # valides, total par plan au plus égal au montant de la ligne — égal en
      # mode obligatoire. `require_all` : toute ligne d'un compte ventilé doit
      # être ventilée (mode obligatoire, à l'enregistrement de l'écriture).
      # `prefix` : chemin des erreurs (`lines`).
      def self.entry_errors(actor : Partiduo::Api::Actor, entry : AccountingApi::EntryView,
                            inputs : Array(Api::LineDistributionInput), require_all : Bool,
                            prefix : String = "lines", paths : Hash(Int64, String)? = nil) : Array(FieldError)
        settings = Settings.view
        plan_ids = Plan.all.to_a.map(&.pk!.as(Int64))
        if !inputs.empty? && plan_ids.empty?
          return [FieldError.base("analytic.errors.distribution.no_plan")]
        end
        errors = [] of FieldError
        errors << FieldError.base("analytic.errors.distribution.closed_period") if date_closed?(entry.date)
        context = LineContext.new(settings, plan_ids, settings.mandatory && !plan_ids.empty?,
          posts_for(inputs.flat_map(&.rows.flat_map(&.post_ids))))
        lines = entry.lines.index_by(&.id)
        seen = Set(Int64).new
        inputs.each_with_index do |input, index|
          path = paths.try(&.[input.line_id]?) || "#{prefix}[#{index}]"
          line = lines[input.line_id]?
          if line.nil?
            errors << FieldError.new("#{path}.line_id", "analytic.errors.distribution.line_unknown")
          elsif !seen.add?(input.line_id)
            errors << FieldError.new("#{path}.line_id", "analytic.errors.distribution.line_twice")
          else
            errors.concat(line_errors(path, line, input, context))
          end
        end
        errors.concat(missing_errors(entry, seen, context, prefix, paths)) if require_all
        errors
      end

      # Paramètres, plans et postes communs aux lignes d'une ventilation.
      private record LineContext, settings : Api::SettingsView, plan_ids : Array(Int64), mandatory : Bool,
        posts : Hash(Int64, Post)

      private def self.line_errors(path : String, line : AccountingApi::EntryLineView, input : Api::LineDistributionInput,
                                   context : LineContext) : Array(FieldError)
        errors = [] of FieldError
        unless context.settings.analytic_account?(line.account_number)
          unless input.rows.empty?
            errors << FieldError.new(path, "analytic.errors.distribution.account_not_analytic",
              {"account" => line.account_number})
          end
          return errors
        end
        if input.rows.empty?
          errors << FieldError.new(path, "analytic.errors.distribution.required") if context.mandatory
          return errors
        end
        allowed = used_post_ids(input.line_id)
        input.rows.each_with_index do |row, row_index|
          errors.concat(row_errors("#{path}.rows[#{row_index}]", row.amount, row.post_ids, context.posts, allowed))
        end
        errors.concat(total_errors(path, line.amount, plan_totals(input.rows, context.posts), context))
      end

      private def self.total_errors(path : String, amount : BigDecimal, totals : Hash(Int64, BigDecimal),
                                    context : LineContext) : Array(FieldError)
        context.plan_ids.compact_map do |plan_id|
          total = totals[plan_id]
          params = {"plan" => plan_name(plan_id), "total" => Exports.raw(total), "amount" => Exports.raw(amount)}
          if total > amount
            FieldError.new(path, "analytic.errors.distribution.exceeds", params)
          elsif context.mandatory && total != amount
            FieldError.new(path, "analytic.errors.distribution.incomplete", params)
          end
        end
      end

      # Mode obligatoire : lignes des comptes ventilés absentes de la saisie.
      private def self.missing_errors(entry : AccountingApi::EntryView, seen : Set(Int64), context : LineContext,
                                      prefix : String, paths : Hash(Int64, String)?) : Array(FieldError)
        return [] of FieldError unless context.mandatory
        entry_lines = entry.lines
        entry_lines.compact_map do |line|
          next if seen.includes?(line.id) || !context.settings.analytic_account?(line.account_number)
          path = paths.try(&.[line.id]?) || "#{prefix}[#{line.position}]"
          FieldError.new(path, "analytic.errors.distribution.required", {"account" => line.account_number})
        end
      end

      # Ventilations d'une écriture à enregistrer, désignées par le rang de
      # leur ligne saisie (`InputDistributionInput`), traduites en
      # ventilations de lignes d'écriture (`EntryLineView#input_index`) :
      # lignes explicites, clé appliquée au montant de la ligne d'écriture ou
      # ligne entière. Renvoie les erreurs de désignation, les ventilations et
      # le chemin d'erreur de chaque ligne (`distributions[i]`).
      def self.resolve_inputs(entry : AccountingApi::EntryView, inputs : Array(Api::InputDistributionInput),
                              input_size : Int32) : {Array(FieldError), Array(Api::LineDistributionInput), Hash(Int64, String)}
        errors = [] of FieldError
        resolved = [] of Api::LineDistributionInput
        paths = {} of Int64 => String
        by_input = {} of Int32 => AccountingApi::EntryLineView
        entry_lines = entry.lines
        entry_lines.each { |line| line.input_index.try { |index| by_input[index] ||= line } }
        inputs.each_with_index do |item, index|
          path = "distributions[#{index}]"
          line = by_input[item.input_index]?
          if line.nil?
            # Ligne saisie sans ligne d'écriture (article nul) : rien à
            # ventiler, sauf lignes explicites.
            next if item.rows.empty? && 0 <= item.input_index < input_size
            errors << FieldError.new("#{path}.input_index", "analytic.errors.distribution.line_unknown")
            next
          end
          rows = rows_for(item, line, path, errors) || next
          paths[line.id] = path
          resolved << Api::LineDistributionInput.new(line.id, rows)
        end
        {errors, resolved, paths}
      end

      private def self.rows_for(item : Api::InputDistributionInput, line : AccountingApi::EntryLineView, path : String,
                                errors : Array(FieldError)) : Array(Api::DistributionRowInput)?
        return item.rows unless item.rows.empty?
        if key_id = item.key_id
          key = Key.filter(id: key_id).first
          if key.nil?
            errors << FieldError.new("#{path}.key_id", "analytic.errors.key.unknown")
            return
          end
          view = Keys.view(key)
          unless view.complete?
            errors << FieldError.new("#{path}.key_id", "analytic.errors.key.incomplete", {"name" => view.name})
            return
          end
          return Keys.apply(view, line.amount)
        end
        return if item.post_ids.empty?
        [Api::DistributionRowInput.new(line.amount, item.post_ids)]
      end

      # Sérialise les ventilations d'une même écriture (verrou transactionnel) :
      # deux ventilations concurrentes d'une ligne ne se heurtent pas à
      # l'unicité de `entry_line_id`.
      def self.lock_entry!(entry_id : Int64) : Nil
        Marten::DB::Connection.default.open do |db|
          db.exec("SELECT pg_advisory_xact_lock(hashtext($1))", "analytic_entry:#{entry_id}")
        end
      end

      # Remplace la ventilation des lignes citées (une ligne sans lignes de
      # ventilation n'est plus ventilée).
      def self.write!(actor : Partiduo::Api::Actor, entry : AccountingApi::EntryView,
                      inputs : Array(Api::LineDistributionInput)) : Array(Distribution)
        lines = entry.lines.index_by(&.id)
        posts = posts_for(inputs.flat_map(&.rows.flat_map(&.post_ids)))
        inputs.compact_map do |input|
          line = lines[input.line_id]
          Distribution.filter(entry_line_id: line.id).each(&.delete)
          next if input.rows.empty?
          distribution = Distribution.create!(
            kind: "entry", entry_id: entry.id, entry_line_id: line.id, ledger_id: entry.ledger_id,
            ledger_code: entry.ledger_code, internal_code: entry.internal_code, receipt: entry.receipt || "",
            account_number: line.account_number, account_label: line.account_label, line_amount: line.amount,
            date: entry.date, description: line.label.presence || entry.label, created_by_id: actor.user_id,
          )
          input.rows.each_with_index do |row, position|
            row.post_ids.each do |post_id|
              post = posts[post_id]
              Operation.create!(
                distribution: distribution, row: position, plan_id: post.plan_id, post: post, amount: row.amount,
                side: line.side.code, card_id: line.card_id, card_code: line.card_code || "",
              )
            end
          end
          distribution
        end
      end

      # Extourne (`Acc_Ledger::reverse`) : chaque ligne ventilée de l'écriture
      # annulée transmet sa ventilation, en sens inverse, à la ligne de même
      # rang de l'extourne, à la date de l'extourne.
      def self.on_entry_cancelled(event : Partiduo::Events::Event) : Nil
        original_id = event["entry_id"].to_i64
        reversal_id = event["reversal_entry_id"]?.try(&.to_i64) || return
        sources = Distribution.filter(entry_id: original_id, kind: "entry").to_a
        return if sources.empty?
        system = Partiduo::Api::Actor.system
        original = AccountingApi.entry(system, original_id)
        reversal = AccountingApi.entry(system, reversal_id)
        positions = original.lines.to_h { |line| {line.id, line.position} }
        targets = reversal.lines.index_by(&.position)
        sources.each do |source|
          position = positions[source.entry_line_id.try(&.as(Int).to_i64) || 0_i64]? || next
          line = targets[position]? || next
          copy = Distribution.create!(
            kind: "entry", entry_id: reversal.id, entry_line_id: line.id, ledger_id: reversal.ledger_id,
            ledger_code: reversal.ledger_code, internal_code: reversal.internal_code,
            receipt: reversal.receipt || "", account_number: line.account_number, account_label: line.account_label,
            line_amount: line.amount, date: reversal.date, description: line.label.presence || reversal.label,
            created_by_id: event.actor_user_id,
          )
          Operation.filter(distribution_id: source.pk).order(:row, :plan_id).each do |operation|
            Operation.create!(
              distribution: copy, row: operation.row, plan_id: operation.plan_id, post_id: operation.post_id,
              amount: operation.amount, side: AccountingApi::Side.from_code(operation.side.to_s).opposite.code,
              card_id: operation.card_id, card_code: operation.card_code,
            )
          end
        end
      end

      # --- Opérations diverses ----------------------------------------------------------

      def self.misc_errors(actor : Partiduo::Api::Actor, input : Api::MiscOperationInput,
                           existing : Distribution? = nil) : Array(FieldError)
        errors = [] of FieldError
        errors << FieldError.new("description", "analytic.errors.misc.description_required") if input.description.strip.empty?
        period = Partiduo::Api::Core.period_for(actor, day(input.date))
        if period.nil?
          errors << FieldError.new("date", "analytic.errors.misc.no_period")
        elsif period.closed? || date_closed?(input.date)
          errors << FieldError.new("date", "analytic.errors.distribution.closed_period")
        end
        if Plan.all.count.zero?
          errors << FieldError.base("analytic.errors.distribution.no_plan")
          return errors
        end
        errors << FieldError.new("rows", "analytic.errors.misc.rows_required") if input.rows.empty?
        errors.concat(misc_rows_errors(input, existing))
      end

      # Lignes d'une opération diverse et équilibre de chaque plan.
      private def self.misc_rows_errors(input : Api::MiscOperationInput, existing : Distribution?) : Array(FieldError)
        errors = [] of FieldError
        posts = posts_for(input.rows.flat_map(&.post_ids))
        allowed = existing ? Operation.filter(distribution_id: existing.pk).to_a.map(&.post_id!.as(Int).to_i64).to_set : Set(Int64).new
        balances = Hash(Int64, BigDecimal).new { ZERO }
        input.rows.each_with_index do |row, index|
          path = "rows[#{index}]"
          errors.concat(row_errors(path, row.amount, row.post_ids, posts, allowed))
          code = row.card.try(&.strip).presence
          if code && card(code).nil?
            errors << FieldError.new("#{path}.card", "analytic.errors.misc.card_unknown", {"code" => code})
          end
          signed = row.side.debit? ? row.amount : -row.amount
          row.post_ids.each do |post_id|
            post = posts[post_id]? || next
            plan_id = post.plan_id!.as(Int).to_i64
            balances[plan_id] = balances[plan_id] + signed
          end
        end
        balances.each do |plan_id, balance|
          next if balance.zero?
          errors << FieldError.base("analytic.errors.misc.unbalanced",
            {"plan" => plan_name(plan_id), "difference" => Exports.raw(balance.abs)})
        end
        errors
      end

      def self.write_misc!(actor : Partiduo::Api::Actor, input : Api::MiscOperationInput,
                           existing : Distribution? = nil) : Distribution
        distribution = existing || Distribution.new(kind: "misc", created_by_id: actor.user_id)
        distribution.date = day(input.date)
        distribution.description = input.description.strip
        distribution.save!
        Operation.filter(distribution_id: distribution.pk).each(&.delete)
        posts = posts_for(input.rows.flat_map(&.post_ids))
        input.rows.each_with_index do |row, position|
          found = row.card.try(&.strip).presence.try { |code| card(code) }
          row.post_ids.each do |post_id|
            post = posts[post_id]
            Operation.create!(
              distribution: distribution, row: position, plan_id: post.plan_id, post: post, amount: row.amount,
              side: row.side.code, card_id: found.try(&.id), card_code: found.try(&.code) || "",
            )
          end
        end
        distribution
      end

      # --- Vues -----------------------------------------------------------------------

      def self.views(distributions : Array(Distribution)) : Array(Api::DistributionView)
        return [] of Api::DistributionView if distributions.empty?
        operations = Operation.filter(distribution_id__in: distributions.map(&.pk!)).order(:row, :plan_id).to_a
        refs = Plans.refs(operations.map(&.post_id!.as(Int).to_i64))
        by_distribution = operations.group_by(&.distribution_id!.as(Int).to_i64)
        distributions.map do |distribution|
          id = distribution.pk!.as(Int64)
          rows = (by_distribution[id]? || [] of Operation).group_by { |operation| (operation.row || 0).to_i32 }.to_a.sort_by!(&.first).map do |(row, list)|
            first = list.first
            Api::DistributionRowView.new(
              position: row, amount: first.amount!, side: AccountingApi::Side.from_code(first.side.to_s),
              posts: list.compact_map { |operation| refs[operation.post_id!.as(Int).to_i64]? },
              card_id: first.card_id.try(&.as(Int).to_i64), card_code: first.card_code.to_s.presence,
            )
          end
          Api::DistributionView.new(
            id: id, kind: distribution.kind.to_s, entry_id: distribution.entry_id.try(&.as(Int).to_i64),
            entry_line_id: distribution.entry_line_id.try(&.as(Int).to_i64), ledger_code: distribution.ledger_code.to_s,
            internal_code: distribution.internal_code.to_s, receipt: distribution.receipt.to_s,
            account_number: distribution.account_number.to_s, account_label: distribution.account_label.to_s,
            line_amount: distribution.line_amount, date: distribution.date!, description: distribution.description.to_s,
            rows: rows,
          )
        end
      end

      # --- Outils ---------------------------------------------------------------------

      def self.day(value : Time) : Time
        Time.utc(value.year, value.month, value.day)
      end

      def self.date_closed?(value : Time) : Bool
        Marten::DB::Connection.default.open do |db|
          db.scalar("SELECT analytic_date_closed($1::date)", args: [day(value).to_s("%Y-%m-%d")]).as(Bool)
        end
      end

      # Totaux ventilés par plan de chaque ligne d'écriture citée.
      def self.line_plan_totals(line_ids : Array(Int64)) : Hash(Int64, Hash(Int64, BigDecimal))
        totals = {} of Int64 => Hash(Int64, BigDecimal)
        return totals if line_ids.empty?
        Marten::DB::Connection.default.open do |db|
          db.query(<<-SQL, args: [line_ids]) do |result_set|
            SELECT d.entry_line_id, o.plan_id, sum(o.amount)
            FROM analytic_distribution d JOIN analytic_operation o ON o.distribution_id = d.id
            WHERE d.entry_line_id = ANY($1)
            GROUP BY d.entry_line_id, o.plan_id
            SQL
            result_set.each do
              line_id = result_set.read(Int64)
              plan_id = result_set.read(Int64)
              (totals[line_id] ||= {} of Int64 => BigDecimal)[plan_id] = result_set.read(BigDecimal)
            end
          end
        end
        totals
      end

      def self.card(code : String) : Partiduo::Api::Cards::CardView?
        Partiduo::Api::Cards.card_by_code(Partiduo::Api::Actor.system, code)
      end

      def self.plan_name(plan_id : Int64) : String
        Plan.filter(id: plan_id).first.try(&.name.to_s) || plan_id.to_s
      end

      private def self.used_post_ids(line_id : Int64) : Set(Int64)
        distribution = Distribution.filter(entry_line_id: line_id).first
        return Set(Int64).new if distribution.nil?
        Operation.filter(distribution_id: distribution.pk).to_a.map(&.post_id!.as(Int).to_i64).to_set
      end
    end
  end
end
