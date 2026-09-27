# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    # Contrat du module Analytique (lot 5, ADR-006 D1, ADR-003 D6 « plans et
    # postes ») : plans, groupes, postes, paramètres, clés de répartition,
    # ventilation des lignes d'écriture, opérations diverses analytiques,
    # éditions et exports CSV. Types dans `types.cr` ; référence :
    # `doc/api/analytic.adoc`.
    #
    # Toute commande et toute requête lèvent `ModuleDisabled` si l'Analytique
    # est inactive. Les lignes d'écriture sont lues par
    # `Partiduo::Api::Accounting` : les droits de l'acteur sur les écritures et
    # les journaux s'appliquent.
    module Analytic
      MODULE_CODE = "ANALYTIC"

      # --- Paramètres ------------------------------------------------------------------

      def self.settings(actor : Actor) : SettingsView
        Guard.authorize!(actor, "analytic.plan.read", module_code: MODULE_CODE)
        Partiduo::Analytic::Settings.view
      end

      # `MY_ANALYTIC` (obligatoire ou facultatif) et `MY_ANC_FILTER`.
      def self.update_settings(actor : Actor, input : SettingsInput) : Result(SettingsView)
        Guard.authorize!(actor, "analytic.plan.write", module_code: MODULE_CODE)
        errors = Partiduo::Analytic::Settings.errors(input)
        return Result(SettingsView).failure(errors) unless errors.empty?
        Transaction.run do
          setting = Partiduo::Analytic::Settings.current
          setting.mandatory = input.mandatory
          setting.account_filter = Partiduo::Analytic::Settings.normalized_filter(input.account_filter)
          setting.save!
          Result(SettingsView).success(Partiduo::Analytic::Settings.view(setting))
        end
      end

      # Mode obligatoire en vigueur (au moins un plan) : lisible de tout
      # utilisateur authentifié, pour qu'une interface avertisse celui qui
      # saisit des écritures sans pouvoir les ventiler (D-ANA-018).
      def self.distribution_required?(actor : Actor) : Bool
        Guard.authorize!(actor, nil, module_code: MODULE_CODE)
        Partiduo::Analytic::Settings.view.mandatory && Partiduo::Analytic::Plan.all.exists?
      end

      # --- Plans -----------------------------------------------------------------------

      def self.plans(actor : Actor) : Array(PlanView)
        Guard.authorize!(actor, "analytic.plan.read", module_code: MODULE_CODE)
        Partiduo::Analytic::Plans.plan_views(Partiduo::Analytic::Plan.all.order(:name).to_a)
      end

      def self.plan(actor : Actor, id : Int64) : PlanView
        Guard.authorize!(actor, "analytic.plan.read", module_code: MODULE_CODE)
        Partiduo::Analytic::Plans.plan_view(find_plan(id))
      end

      def self.check_plan(actor : Actor, input : PlanInput, id : Int64? = nil) : Result(Nil)
        Guard.authorize!(actor, "analytic.plan.write", module_code: MODULE_CODE)
        errors = Partiduo::Analytic::Plans.plan_errors(input, id)
        errors.empty? ? Result(Nil).success(nil) : Result(Nil).failure(errors)
      end

      def self.create_plan(actor : Actor, input : PlanInput) : Result(PlanView)
        Guard.authorize!(actor, "analytic.plan.write", module_code: MODULE_CODE)
        Transaction.run do
          errors = Partiduo::Analytic::Plans.plan_errors(input)
          next Result(PlanView).failure(errors) unless errors.empty?
          plan = Partiduo::Analytic::Plan.create!(name: Partiduo::Analytic::Plans.normalize(input.name),
            description: input.description.strip)
          Result(PlanView).success(Partiduo::Analytic::Plans.plan_view(plan))
        end
      end

      def self.update_plan(actor : Actor, id : Int64, input : PlanInput) : Result(PlanView)
        Guard.authorize!(actor, "analytic.plan.write", module_code: MODULE_CODE)
        Transaction.run do
          plan = find_plan(id)
          errors = Partiduo::Analytic::Plans.plan_errors(input, id)
          next Result(PlanView).failure(errors) unless errors.empty?
          plan.name = Partiduo::Analytic::Plans.normalize(input.name)
          plan.description = input.description.strip
          plan.save!
          Result(PlanView).success(Partiduo::Analytic::Plans.plan_view(plan))
        end
      end

      # Supprime le plan, ses groupes, ses postes, ses opérations et les
      # postes de clé qui le citent (`Anc_Plan::delete`) ; une ligne de clé
      # restée sans poste est retirée et la clé devient incomplète
      # (`KeyView#complete?`, D-ANA-013). Refusé si un de ses postes est
      # imputé dans une période close.
      def self.delete_plan(actor : Actor, id : Int64) : Result(Nil)
        Guard.authorize!(actor, "analytic.plan.write", module_code: MODULE_CODE)
        Transaction.run do
          plan = find_plan(id)
          post_ids = Partiduo::Analytic::Post.filter(plan_id: id).to_a.map(&.pk!.as(Int64))
          if Partiduo::Analytic::Plans.used_in_closed_period?(post_ids)
            next Result(Nil).failure(FieldError.base("analytic.errors.plan.closed_period"))
          end
          plan.delete
          Partiduo::Analytic::Plans.delete_empty_distributions
          Partiduo::Analytic::Plans.delete_empty_key_rows
          Result(Nil).success(nil)
        end
      end

      # --- Groupes ---------------------------------------------------------------------

      def self.groups(actor : Actor, plan_id : Int64? = nil) : Array(GroupView)
        Guard.authorize!(actor, "analytic.plan.read", module_code: MODULE_CODE)
        query = Partiduo::Analytic::Group.all
        query = query.filter(plan_id: plan_id) if plan_id
        Partiduo::Analytic::Plans.group_views(query.order(:plan_id, :code).to_a)
      end

      def self.group(actor : Actor, id : Int64) : GroupView
        Guard.authorize!(actor, "analytic.plan.read", module_code: MODULE_CODE)
        Partiduo::Analytic::Plans.group_view(find_group(id))
      end

      def self.create_group(actor : Actor, input : GroupInput) : Result(GroupView)
        Guard.authorize!(actor, "analytic.plan.write", module_code: MODULE_CODE)
        Transaction.run do
          errors = Partiduo::Analytic::Plans.group_errors(input)
          next Result(GroupView).failure(errors) unless errors.empty?
          group = Partiduo::Analytic::Group.create!(plan_id: input.plan_id,
            code: Partiduo::Analytic::Plans.normalize(input.code), description: input.description.strip)
          Result(GroupView).success(Partiduo::Analytic::Plans.group_view(group))
        end
      end

      # Le plan d'un groupe ne change pas (`plan_id` de l'entrée ignoré).
      def self.update_group(actor : Actor, id : Int64, input : GroupInput) : Result(GroupView)
        Guard.authorize!(actor, "analytic.plan.write", module_code: MODULE_CODE)
        Transaction.run do
          group = find_group(id)
          input = input.copy_with(plan_id: group.plan_id!.as(Int).to_i64)
          errors = Partiduo::Analytic::Plans.group_errors(input, id)
          next Result(GroupView).failure(errors) unless errors.empty?
          group.code = Partiduo::Analytic::Plans.normalize(input.code)
          group.description = input.description.strip
          group.save!
          Result(GroupView).success(Partiduo::Analytic::Plans.group_view(group))
        end
      end

      # Supprime le groupe ; ses postes n'ont plus de groupe
      # (`group_analytique_del`).
      def self.delete_group(actor : Actor, id : Int64) : Result(Nil)
        Guard.authorize!(actor, "analytic.plan.write", module_code: MODULE_CODE)
        Transaction.run do
          group = find_group(id)
          Partiduo::Analytic::Post.filter(group_id: id).update(group_id: nil)
          group.delete
          Result(Nil).success(nil)
        end
      end

      # --- Postes ----------------------------------------------------------------------

      # Postes d'un plan (ou de tous), par code ; actifs seulement si
      # `active_only`.
      def self.posts(actor : Actor, plan_id : Int64? = nil, active_only : Bool = false) : Array(PostView)
        Guard.authorize!(actor, "analytic.plan.read", module_code: MODULE_CODE)
        query = Partiduo::Analytic::Post.all
        query = query.filter(plan_id: plan_id) if plan_id
        query = query.filter(active: true) if active_only
        Partiduo::Analytic::Plans.post_views(query.order(:plan_id, :code).to_a)
      end

      def self.post(actor : Actor, id : Int64) : PostView
        Guard.authorize!(actor, "analytic.plan.read", module_code: MODULE_CODE)
        Partiduo::Analytic::Plans.post_views([find_post(id)]).first
      end

      # Poste d'un plan par son code (`Anc_Account::load_by_code`) ; `nil` s'il
      # n'existe pas.
      def self.post_by_code(actor : Actor, plan_id : Int64, code : String) : PostView?
        Guard.authorize!(actor, "analytic.plan.read", module_code: MODULE_CODE)
        post = Partiduo::Analytic::Post.filter(plan_id: plan_id, code: Partiduo::Analytic::Plans.normalize_post(code)).first
        post.try { |found| Partiduo::Analytic::Plans.post_views([found]).first }
      end

      def self.check_post(actor : Actor, input : PostInput, id : Int64? = nil) : Result(Nil)
        Guard.authorize!(actor, "analytic.plan.write", module_code: MODULE_CODE)
        errors = Partiduo::Analytic::Plans.post_errors(input, id)
        errors.empty? ? Result(Nil).success(nil) : Result(Nil).failure(errors)
      end

      def self.create_post(actor : Actor, input : PostInput) : Result(PostView)
        Guard.authorize!(actor, "analytic.plan.write", module_code: MODULE_CODE)
        Transaction.run do
          errors = Partiduo::Analytic::Plans.post_errors(input)
          next Result(PostView).failure(errors) unless errors.empty?
          post = Partiduo::Analytic::Post.create!(
            plan_id: input.plan_id, code: Partiduo::Analytic::Plans.normalize_post(input.code),
            description: input.description.strip, group_id: input.group_id, active: input.active,
          )
          Result(PostView).success(Partiduo::Analytic::Plans.post_views([post]).first)
        end
      end

      # Le plan d'un poste ne change pas (`pa_id` non modifiable).
      def self.update_post(actor : Actor, id : Int64, input : PostInput) : Result(PostView)
        Guard.authorize!(actor, "analytic.plan.write", module_code: MODULE_CODE)
        Transaction.run do
          post = find_post(id)
          input = input.copy_with(plan_id: post.plan_id!.as(Int).to_i64)
          errors = Partiduo::Analytic::Plans.post_errors(input, id)
          next Result(PostView).failure(errors) unless errors.empty?
          post.code = Partiduo::Analytic::Plans.normalize_post(input.code)
          post.description = input.description.strip
          post.group_id = input.group_id
          post.active = input.active
          post.save!
          Result(PostView).success(Partiduo::Analytic::Plans.post_views([post]).first)
        end
      end

      # Supprime le poste et ses opérations (`Anc_Account_Table::delete`) ;
      # une ligne de clé restée sans poste est retirée (D-ANA-013). Refusé
      # s'il est imputé dans une période close.
      def self.delete_post(actor : Actor, id : Int64) : Result(Nil)
        Guard.authorize!(actor, "analytic.plan.write", module_code: MODULE_CODE)
        Transaction.run do
          post = find_post(id)
          if Partiduo::Analytic::Plans.used_in_closed_period?([id])
            next Result(Nil).failure(FieldError.base("analytic.errors.post.closed_period"))
          end
          post.delete
          Partiduo::Analytic::Plans.delete_empty_distributions
          Partiduo::Analytic::Plans.delete_empty_key_rows
          Result(Nil).success(nil)
        end
      end

      # --- Clés de répartition -------------------------------------------------------

      def self.keys(actor : Actor) : Array(KeyView)
        Guard.authorize!(actor, "analytic.plan.read", module_code: MODULE_CODE)
        Partiduo::Analytic::Key.all.order(:name, :id).map { |key| Partiduo::Analytic::Keys.view(key) }
      end

      def self.key(actor : Actor, id : Int64) : KeyView
        Guard.authorize!(actor, "analytic.plan.read", module_code: MODULE_CODE)
        Partiduo::Analytic::Keys.view(find_key(id))
      end

      # Clés proposées pour un journal (`Anc_Key::key_available`,
      # `display_choice`).
      def self.keys_for_ledger(actor : Actor, ledger_id : Int64) : Array(KeyView)
        Guard.authorize!(actor, "analytic.plan.read", module_code: MODULE_CODE)
        ids = Partiduo::Analytic::KeyLedger.filter(ledger_id: ledger_id).to_a.map(&.key_id!.as(Int).to_i64)
        return [] of KeyView if ids.empty?
        Partiduo::Analytic::Key.filter(id__in: ids).order(:name, :id).map { |key| Partiduo::Analytic::Keys.view(key) }
      end

      def self.check_key(actor : Actor, input : KeyInput) : Result(Nil)
        Guard.authorize!(actor, "analytic.plan.write", module_code: MODULE_CODE)
        errors = Partiduo::Analytic::Keys.errors(input, ledger_exists(actor))
        errors.empty? ? Result(Nil).success(nil) : Result(Nil).failure(errors)
      end

      def self.create_key(actor : Actor, input : KeyInput) : Result(KeyView)
        Guard.authorize!(actor, "analytic.plan.write", module_code: MODULE_CODE)
        Transaction.run do
          errors = Partiduo::Analytic::Keys.errors(input, ledger_exists(actor))
          next Result(KeyView).failure(errors) unless errors.empty?
          key = Partiduo::Analytic::Keys.save!(Partiduo::Analytic::Key.new, input)
          Result(KeyView).success(Partiduo::Analytic::Keys.view(key))
        end
      end

      def self.update_key(actor : Actor, id : Int64, input : KeyInput) : Result(KeyView)
        Guard.authorize!(actor, "analytic.plan.write", module_code: MODULE_CODE)
        Transaction.run do
          key = find_key(id)
          errors = Partiduo::Analytic::Keys.errors(input, ledger_exists(actor))
          next Result(KeyView).failure(errors) unless errors.empty?
          Partiduo::Analytic::Keys.save!(key, input)
          Result(KeyView).success(Partiduo::Analytic::Keys.view(key))
        end
      end

      def self.delete_key(actor : Actor, id : Int64) : Result(Nil)
        Guard.authorize!(actor, "analytic.plan.write", module_code: MODULE_CODE)
        Transaction.run do
          find_key(id).delete
          Result(Nil).success(nil)
        end
      end

      # Lignes de ventilation d'un montant selon une clé (`Anc_Key::fill_table`),
      # à soumettre telles quelles ou à corriger.
      def self.apply_key(actor : Actor, id : Int64, amount : BigDecimal) : Array(DistributionRowInput)
        Guard.authorize!(actor, "analytic.plan.read", module_code: MODULE_CODE)
        Partiduo::Analytic::Keys.apply(Partiduo::Analytic::Keys.view(find_key(id)), amount)
      end

      # --- Ventilation des écritures -------------------------------------------------

      # Ventilations des lignes d'une écriture visible de l'acteur : droit de
      # lire les éditions *ou* de ventiler (l'écran de ventilation relit la
      # ventilation qu'il modifie).
      def self.entry_distributions(actor : Actor, entry_id : Int64) : Array(DistributionView)
        authorize_any!(actor, "analytic.report.read", "analytic.operation.write")
        entry = Partiduo::Api::Accounting.entry(actor, entry_id)
        list = Partiduo::Analytic::Distribution.filter(entry_id: entry.id, kind: "entry").to_a
        positions = entry.lines.to_h { |line| {line.id, line.position} }
        list.sort_by! { |item| positions[item.entry_line_id.try(&.as(Int).to_i64) || 0_i64]? || 0 }
        Partiduo::Analytic::Distributions.views(list)
      end

      # Requête de contrôle : règles de `distribute_entry`, sans écrire.
      def self.check_distribution(actor : Actor, entry_id : Int64, lines : Array(LineDistributionInput)) : Result(Nil)
        Guard.authorize!(actor, "analytic.operation.write", module_code: MODULE_CODE)
        entry = writable_entry(actor, entry_id)
        return Result(Nil).failure([cancelled_error]) if entry.cancelled? || entry.reversal?
        errors = Partiduo::Analytic::Distributions.entry_errors(actor, entry, lines, require_all: false)
        errors.empty? ? Result(Nil).success(nil) : Result(Nil).failure(errors)
      end

      # Ventile (ou reventile) des lignes d'une écriture enregistrée
      # (`save_update_form`) : la ventilation de chaque ligne citée est
      # remplacée ; `rows` vide la retire (refusé en mode obligatoire).
      # Écriture d'une période close : refusée. Écriture annulée ou extourne :
      # refusée (`cancelled_entry`) — l'extourne a reçu la ventilation
      # inverse de l'écriture annulée, les deux restent symétriques
      # (D-ANA-006, D-ANA-014). Les ventilations d'une même écriture sont
      # sérialisées (verrou transactionnel).
      def self.distribute_entry(actor : Actor, entry_id : Int64, lines : Array(LineDistributionInput)) : Result(Array(DistributionView))
        Guard.authorize!(actor, "analytic.operation.write", module_code: MODULE_CODE)
        Transaction.run do
          entry = writable_entry(actor, entry_id)
          if entry.cancelled? || entry.reversal?
            next Result(Array(DistributionView)).failure([cancelled_error])
          end
          Partiduo::Analytic::Distributions.lock_entry!(entry.id)
          errors = Partiduo::Analytic::Distributions.entry_errors(actor, entry, lines, require_all: false)
          next Result(Array(DistributionView)).failure(errors) unless errors.empty?
          written = Partiduo::Analytic::Distributions.write!(actor, entry, lines)
          Result(Array(DistributionView)).success(Partiduo::Analytic::Distributions.views(written))
        end
      end

      # Enregistre une écriture (`Partiduo::Api::Accounting.post_entry`) et la
      # ventilation de ses lignes, désignées par le rang de leur ligne saisie
      # (`InputDistributionInput#input_index`), dans une seule transaction :
      # en mode obligatoire, toute ligne d'un compte ventilé doit l'être
      # entièrement dans chaque plan, sinon rien n'est enregistré. Erreurs de
      # ventilation sous `distributions[i]` (ventilation citée) ou
      # `distributions[input=n]` (ligne saisie `n` non ventilée) ;
      # `distributions[position=p]` pour une ligne calculée.
      def self.post_entry(actor : Actor, input : Partiduo::Api::Accounting::EntryInput,
                          distributions : Array(InputDistributionInput)) : Result(Partiduo::Api::Accounting::EntryView)
        post_with(actor, distributions, input.lines.size) { Partiduo::Api::Accounting.post_entry(actor, input) }
      end

      # Facture ou avoir d'achat ventilé (lignes calculées de `check_document`).
      def self.post_purchase(actor : Actor, input : Partiduo::Api::Accounting::DocumentInput,
                             distributions : Array(InputDistributionInput)) : Result(Partiduo::Api::Accounting::EntryView)
        post_with(actor, distributions, input.lines.size) { Partiduo::Api::Accounting.post_purchase(actor, input) }
      end

      # Facture ou avoir de vente ventilé.
      def self.post_sale(actor : Actor, input : Partiduo::Api::Accounting::DocumentInput,
                         distributions : Array(InputDistributionInput)) : Result(Partiduo::Api::Accounting::EntryView)
        post_with(actor, distributions, input.lines.size) { Partiduo::Api::Accounting.post_sale(actor, input) }
      end

      # Lignes des comptes ventilés, entre deux dates, dont la ventilation
      # manque ou n'atteint pas le montant de la ligne dans un plan au moins
      # (contrôle du mode obligatoire). Extournes et écritures extournées
      # comprises.
      def self.undistributed_lines(actor : Actor, date_from : Time, date_to : Time) : Array(UndistributedLineView)
        Guard.authorize!(actor, "analytic.report.read", module_code: MODULE_CODE)
        settings = Partiduo::Analytic::Settings.view
        plan_ids = Partiduo::Analytic::Plan.all.to_a.map(&.pk!.as(Int64)).sort!
        return [] of UndistributedLineView if plan_ids.empty?
        result = [] of UndistributedLineView
        offset = 0
        loop do
          query = Partiduo::Api::Accounting::EntryQuery.new(date_from: date_from, date_to: date_to, offset: offset, limit: 200)
          entries = Partiduo::Api::Accounting.entries(actor, query)
          break if entries.empty?
          lines = entries.flat_map { |entry| entry.lines.select { |line| settings.analytic_account?(line.account_number) }.map { |line| {entry, line} } }
          totals = Partiduo::Analytic::Distributions.line_plan_totals(lines.map { |(_, line)| line.id })
          lines.each do |(entry, line)|
            sums = totals[line.id]? || {} of Int64 => BigDecimal
            missing = plan_ids.reject { |plan_id| sums[plan_id]? == line.amount }
            next if missing.empty?
            result << UndistributedLineView.new(
              entry_id: entry.id, line_id: line.id, position: line.position, date: entry.date,
              ledger_code: entry.ledger_code, internal_code: entry.internal_code, account_number: line.account_number,
              amount: line.amount, missing_plan_ids: missing,
            )
          end
          break if entries.size < 200
          offset += 200
        end
        result
      end

      # --- Opérations diverses analytiques ---------------------------------------------

      # Opérations diverses entre deux dates (bornes facultatives), par date.
      def self.misc_operations(actor : Actor, date_from : Time? = nil, date_to : Time? = nil) : Array(DistributionView)
        Guard.authorize!(actor, "analytic.report.read", module_code: MODULE_CODE)
        query = Partiduo::Analytic::Distribution.filter(kind: "misc")
        query = query.filter(date__gte: Partiduo::Analytic::Distributions.day(date_from)) if date_from
        query = query.filter(date__lte: Partiduo::Analytic::Distributions.day(date_to)) if date_to
        Partiduo::Analytic::Distributions.views(query.order(:date, :id).to_a)
      end

      def self.misc_operation(actor : Actor, id : Int64) : DistributionView
        Guard.authorize!(actor, "analytic.report.read", module_code: MODULE_CODE)
        Partiduo::Analytic::Distributions.views([find_misc(id)]).first
      end

      def self.check_misc_operation(actor : Actor, input : MiscOperationInput, id : Int64? = nil) : Result(Nil)
        Guard.authorize!(actor, "analytic.operation.write", module_code: MODULE_CODE)
        existing = id.try { |value| find_misc(value) }
        errors = Partiduo::Analytic::Distributions.misc_errors(actor, input, existing)
        errors.empty? ? Result(Nil).success(nil) : Result(Nil).failure(errors)
      end

      # Opération diverse analytique (`Anc_Group_Operation::save`) :
      # description, date d'une période ouverte, lignes équilibrées dans
      # chaque plan.
      def self.create_misc_operation(actor : Actor, input : MiscOperationInput) : Result(DistributionView)
        Guard.authorize!(actor, "analytic.operation.write", module_code: MODULE_CODE)
        Transaction.run do
          errors = Partiduo::Analytic::Distributions.misc_errors(actor, input)
          next Result(DistributionView).failure(errors) unless errors.empty?
          distribution = Partiduo::Analytic::Distributions.write_misc!(actor, input)
          Result(DistributionView).success(Partiduo::Analytic::Distributions.views([distribution]).first)
        end
      end

      def self.update_misc_operation(actor : Actor, id : Int64, input : MiscOperationInput) : Result(DistributionView)
        Guard.authorize!(actor, "analytic.operation.write", module_code: MODULE_CODE)
        Transaction.run do
          existing = find_misc(id)
          errors = Partiduo::Analytic::Distributions.misc_errors(actor, input, existing)
          if Partiduo::Analytic::Distributions.date_closed?(existing.date!)
            errors << FieldError.base("analytic.errors.distribution.closed_period")
          end
          next Result(DistributionView).failure(errors) unless errors.empty?
          distribution = Partiduo::Analytic::Distributions.write_misc!(actor, input, existing)
          Result(DistributionView).success(Partiduo::Analytic::Distributions.views([distribution]).first)
        end
      end

      def self.delete_misc_operation(actor : Actor, id : Int64) : Result(Nil)
        Guard.authorize!(actor, "analytic.operation.write", module_code: MODULE_CODE)
        Transaction.run do
          existing = find_misc(id)
          if Partiduo::Analytic::Distributions.date_closed?(existing.date!)
            next Result(Nil).failure(FieldError.base("analytic.errors.distribution.closed_period"))
          end
          existing.delete
          Result(Nil).success(nil)
        end
      end

      # --- Éditions --------------------------------------------------------------------

      # Balance simple d'un plan (`Anc_Balance_Simple`).
      def self.balance(actor : Actor, query : ReportQuery) : BalanceView
        Guard.authorize!(actor, "analytic.report.read", module_code: MODULE_CODE)
        plan = plan_view!(query.plan_id)
        rows, partial = report_rows(actor, query.plan_id, query.date_from, query.date_to, query.post_from, query.post_to)
        Partiduo::Analytic::Reports.balance(plan, query, rows, partial)
      end

      # Balance croisée double de deux plans (`Anc_Balance_Double`).
      def self.cross_balance(actor : Actor, query : CrossBalanceQuery) : CrossBalanceView
        Guard.authorize!(actor, "analytic.report.read", module_code: MODULE_CODE)
        plan = plan_view!(query.plan_id)
        other = plan_view!(query.other_plan_id)
        rows, partial = report_rows(actor, query.plan_id, query.date_from, query.date_to, query.post_from, query.post_to)
        others, other_partial = report_rows(actor, query.other_plan_id, query.date_from, query.date_to,
          query.other_post_from, query.other_post_to)
        Partiduo::Analytic::Reports.cross_balance(plan, other, query, rows, others, partial || other_partial)
      end

      # Balance par groupe (`Anc_Group::get_result`).
      def self.group_balance(actor : Actor, query : ReportQuery) : GroupBalanceView
        Guard.authorize!(actor, "analytic.report.read", module_code: MODULE_CODE)
        plan = plan_view!(query.plan_id)
        rows, partial = report_rows(actor, query.plan_id, query.date_from, query.date_to, query.post_from, query.post_to)
        Partiduo::Analytic::Reports.group_balance(plan, rows, partial)
      end

      # Historique des imputations (`Anc_Listing`), par date ; `offset` et
      # `limit` (10 000 au plus) découpent la liste en SQL, `count` et
      # `total` portent sur toute la sélection.
      def self.history(actor : Actor, query : ReportQuery, offset : Int32 = 0, limit : Int32 = 500) : HistoryView
        Guard.authorize!(actor, "analytic.report.read", module_code: MODULE_CODE)
        history_page(actor, query, offset, limit.clamp(0, 10_000))
      end

      # Grand livre analytique (`Anc_GrandLivre`).
      def self.ledger(actor : Actor, query : ReportQuery) : LedgerView
        Guard.authorize!(actor, "analytic.report.read", module_code: MODULE_CODE)
        plan = plan_view!(query.plan_id)
        rows, partial = report_rows(actor, query.plan_id, query.date_from, query.date_to, query.post_from, query.post_to)
        Partiduo::Analytic::Reports.ledger(plan, rows, partial)
      end

      # Tableau postes × comptes généraux ou fiches (`Anc_Table`,
      # `Anc_Acc_List`).
      def self.table(actor : Actor, query : TableQuery) : TableView
        Guard.authorize!(actor, "analytic.report.read", module_code: MODULE_CODE)
        plan = plan_view!(query.plan_id)
        rows, partial = report_rows(actor, query.plan_id, query.date_from, query.date_to, query.post_from, query.post_to)
        Partiduo::Analytic::Reports.table(plan, query.axis, rows, partial)
      end

      # --- Exports CSV ---------------------------------------------------------------

      def self.export_balance(actor : Actor, query : ReportQuery) : FileView
        Partiduo::Analytic::Exports.balance(balance(actor, query))
      end

      def self.export_cross_balance(actor : Actor, query : CrossBalanceQuery) : FileView
        Partiduo::Analytic::Exports.cross_balance(cross_balance(actor, query))
      end

      def self.export_group_balance(actor : Actor, query : ReportQuery) : FileView
        Partiduo::Analytic::Exports.group_balance(group_balance(actor, query))
      end

      def self.export_history(actor : Actor, query : ReportQuery) : FileView
        Guard.authorize!(actor, "analytic.report.read", module_code: MODULE_CODE)
        Partiduo::Analytic::Exports.history(history_page(actor, query, 0, nil))
      end

      def self.export_ledger(actor : Actor, query : ReportQuery) : FileView
        Partiduo::Analytic::Exports.ledger(ledger(actor, query))
      end

      def self.export_table(actor : Actor, query : TableQuery) : FileView
        Partiduo::Analytic::Exports.table(table(actor, query))
      end

      # --- Outils ----------------------------------------------------------------------

      private def self.post_with(actor : Actor, distributions : Array(InputDistributionInput), input_size : Int32,
                                 & : -> Result(Partiduo::Api::Accounting::EntryView)) : Result(Partiduo::Api::Accounting::EntryView)
        Guard.authorize!(actor, "analytic.operation.write", module_code: MODULE_CODE)
        Transaction.run do
          posted = yield
          next posted if posted.failure?
          entry = posted.value!
          errors, inputs, paths = Partiduo::Analytic::Distributions.resolve_inputs(entry, distributions, input_size)
          entry_lines = entry.lines
          entry_lines.each do |line|
            paths[line.id] ||= line.input_index.try { |index| "distributions[input=#{index}]" } ||
                               "distributions[position=#{line.position}]"
          end
          errors.concat(Partiduo::Analytic::Distributions.entry_errors(actor, entry, inputs, require_all: true, paths: paths))
          next Result(Partiduo::Api::Accounting::EntryView).failure(errors) unless errors.empty?
          Partiduo::Analytic::Distributions.write!(actor, entry, inputs)
          posted
        end
      end

      private def self.cancelled_error : FieldError
        FieldError.base("analytic.errors.distribution.cancelled_entry")
      end

      private def self.writable_entry(actor : Actor, entry_id : Int64) : Partiduo::Api::Accounting::EntryView
        entry = Partiduo::Api::Accounting.entry(actor, entry_id)
        unless actor.system || Partiduo::Api::Accounting.ledger_access(actor, entry.ledger_id).write?
          raise Forbidden.new("accounting.entry.post")
        end
        entry
      end

      # Autorise l'acteur s'il a l'une des permissions citées.
      private def self.authorize_any!(actor : Actor, *permissions : String) : Nil
        Guard.require_module!(MODULE_CODE)
        granted = permissions.find { |permission| actor.system || actor.can?(permission) }
        Guard.authorize!(actor, granted || permissions.first, module_code: MODULE_CODE)
      end

      # Page de l'historique (`limit` nil : toute la sélection, pour l'export).
      private def self.history_page(actor : Actor, query : ReportQuery, offset : Int32, limit : Int32?) : HistoryView
        plan = plan_view!(query.plan_id)
        selection = Partiduo::Analytic::Reports.selection(actor, query.plan_id, query.date_from, query.date_to,
          query.post_from, query.post_to)
        count, total = Partiduo::Analytic::Reports.summary(selection)
        rows = Partiduo::Analytic::Reports.rows(selection, offset, limit)
        HistoryView.new(plan, rows.map { |row| Partiduo::Analytic::Reports.operation(row) }, count, total, selection.partial)
      end

      private def self.report_rows(actor : Actor, plan_id : Int64, date_from : Time?, date_to : Time?,
                                   post_from : String?, post_to : String?)
        Partiduo::Analytic::Reports.rows(actor, plan_id, date_from, date_to, post_from, post_to)
      end

      private def self.ledger_exists(actor : Actor) : Int64 -> Bool
        ->(id : Int64) {
          begin
            Partiduo::Api::Accounting.ledger_access(Actor.system, id)
            true
          rescue NotFound
            false
          end
        }
      end

      private def self.plan_view!(id : Int64) : PlanView
        Partiduo::Analytic::Plans.plan_view(find_plan(id))
      end

      private def self.find_plan(id : Int64) : Partiduo::Analytic::Plan
        Partiduo::Analytic::Plan.filter(id: id).first || raise NotFound.new("analytic_plan", id)
      end

      private def self.find_group(id : Int64) : Partiduo::Analytic::Group
        Partiduo::Analytic::Group.filter(id: id).first || raise NotFound.new("analytic_group", id)
      end

      private def self.find_post(id : Int64) : Partiduo::Analytic::Post
        Partiduo::Analytic::Post.filter(id: id).first || raise NotFound.new("analytic_post", id)
      end

      private def self.find_key(id : Int64) : Partiduo::Analytic::Key
        Partiduo::Analytic::Key.filter(id: id).first || raise NotFound.new("analytic_key", id)
      end

      private def self.find_misc(id : Int64) : Partiduo::Analytic::Distribution
        Partiduo::Analytic::Distribution.filter(id: id, kind: "misc").first || raise NotFound.new("analytic_operation", id)
      end
    end
  end
end
