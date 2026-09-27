# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    # Types du contrat du module Analytique (lot 5). Les montants sont des
    # `BigDecimal` en devise de tenue ; le sens est celui de la Comptabilité
    # (`Partiduo::Api::Accounting::Side`).
    module Analytic
      alias Side = Partiduo::Api::Accounting::Side

      # --- Plans, groupes, postes ------------------------------------------------

      # Plan (axe) : `name` mis en majuscules, espaces retirés
      # (`plan_analytic_ins_upd`).
      record PlanInput, name : String, description : String = ""

      record PlanView, id : Int64, name : String, description : String, posts_count : Int32, groups_count : Int32

      # Groupe d'un plan : `code` de 10 caractères au plus, mis en majuscules,
      # espaces retirés.
      record GroupInput, plan_id : Int64, code : String, description : String = ""

      record GroupView, id : Int64, plan_id : Int64, code : String, description : String, posts_count : Int32

      # Poste : `code` mis en majuscules, espaces et caractères `' < >`
      # retirés (`Anc_Account_Table::check`), unique dans son plan ;
      # `group_id` : groupe du même plan.
      record PostInput,
        plan_id : Int64,
        code : String,
        description : String = "",
        group_id : Int64? = nil,
        active : Bool = true

      record PostView,
        id : Int64,
        plan_id : Int64,
        plan_name : String,
        code : String,
        description : String,
        group_id : Int64?,
        group_code : String?,
        active : Bool,
        operations_count : Int64

      # Référence courte à un poste (lignes de ventilation, de clé, éditions).
      record PostRef, id : Int64, plan_id : Int64, code : String, description : String

      # --- Paramètres ----------------------------------------------------------------

      # `MY_ANALYTIC` (`op` facultatif / `ob` obligatoire) et `MY_ANC_FILTER` :
      # préfixes de comptes séparés par des virgules (chiffres seulement) ;
      # vide = tous les comptes.
      record SettingsInput, mandatory : Bool, account_filter : String

      record SettingsView, mandatory : Bool, account_filter : String, prefixes : Array(String) do
        # Le compte est-il ventilé (`match_analytic`) ?
        def analytic_account?(number : String) : Bool
          prefixes.empty? || prefixes.any? { |prefix| number.starts_with?(prefix) }
        end
      end

      # --- Clés de répartition ----------------------------------------------------

      # Ligne d'une clé : pourcentage (> 0) et au plus un poste par plan.
      record KeyRowInput, percent : BigDecimal, post_ids : Array(Int64)

      # Clé : lignes totalisant 100 %, journaux où elle est proposée
      # (`key_distribution_ledger`).
      record KeyInput,
        name : String,
        rows : Array(KeyRowInput),
        description : String = "",
        ledger_ids : Array(Int64) = [] of Int64

      record KeyRowView, id : Int64, position : Int32, percent : BigDecimal, posts : Array(PostRef)

      record KeyView,
        id : Int64,
        name : String,
        description : String,
        rows : Array(KeyRowView),
        ledger_ids : Array(Int64) do
        def total_percent : BigDecimal
          rows.sum(BigDecimal.new(0), &.percent)
        end

        # Clé applicable : lignes à 100 % en tout, chacune avec un poste au
        # moins. Une clé devient incomplète quand la suppression d'un poste
        # ou d'un plan lui retire des lignes (D-ANA-013).
        def complete? : Bool
          !rows.empty? && total_percent == BigDecimal.new(100) && rows.none?(&.posts.empty?)
        end
      end

      # --- Ventilations ----------------------------------------------------------------

      # Ligne de ventilation : montant (> 0, quatre décimales au plus) et au
      # plus un poste par plan (`hplan`, `val` du formulaire).
      record DistributionRowInput, amount : BigDecimal, post_ids : Array(Int64)

      # Ventilation d'une ligne d'écriture, désignée par son identifiant
      # (`EntryLineView#id`). `rows` vide : la ventilation est retirée.
      record LineDistributionInput, line_id : Int64, rows : Array(DistributionRowInput)

      # Ventilation d'une ligne d'une écriture à enregistrer, désignée par le
      # rang de sa ligne *saisie* (`EntryInput.lines[i]`,
      # `DocumentInput.lines[i]`) : le cœur retrouve la ligne d'écriture
      # produite (`EntryLineView#input_index`), l'interface ne reproduit pas
      # la construction de l'écriture (D-ANA-012). Au choix :
      #
      # * `rows` : lignes de ventilation explicites ;
      # * `key_id` : clé de répartition appliquée au montant de la ligne
      #   d'écriture (en devise de tenue) ;
      # * `post_ids` : ligne entière, un poste par plan.
      #
      # Tout vide : aucune ventilation. Une ligne saisie qui ne produit pas de
      # ligne d'écriture (article de montant nul) est ignorée, sauf lignes
      # explicites (erreur `line_unknown`).
      record InputDistributionInput,
        input_index : Int32,
        rows : Array(DistributionRowInput) = [] of DistributionRowInput,
        key_id : Int64? = nil,
        post_ids : Array(Int64) = [] of Int64

      # Ligne d'une opération diverse analytique (`Anc_Group_Operation`) :
      # montant, sens, fiche facultative (quick code), un poste par plan.
      record MiscRowInput, amount : BigDecimal, side : Side, post_ids : Array(Int64), card : String? = nil

      record MiscOperationInput, date : Time, description : String, rows : Array(MiscRowInput)

      record DistributionRowView,
        position : Int32,
        amount : BigDecimal,
        side : Side,
        posts : Array(PostRef),
        card_id : Int64?,
        card_code : String?

      # Imputation : ventilation d'une ligne (`kind` `entry`) ou opération
      # diverse (`misc`). Pour une ventilation, écriture, journal, pièce,
      # compte et montant de la ligne sont ceux de l'écriture.
      record DistributionView,
        id : Int64,
        kind : String,
        entry_id : Int64?,
        entry_line_id : Int64?,
        ledger_code : String,
        internal_code : String,
        receipt : String,
        account_number : String,
        account_label : String,
        line_amount : BigDecimal?,
        date : Time,
        description : String,
        rows : Array(DistributionRowView) do
        def misc? : Bool
          kind == "misc"
        end

        # Total ventilé dans un plan.
        def total_for(plan_id : Int64) : BigDecimal
          rows.select { |row| row.posts.any?(&.plan_id.==(plan_id)) }.sum(BigDecimal.new(0), &.amount)
        end
      end

      # Ligne d'écriture d'un compte ventilé dont la ventilation est absente ou
      # incomplète dans au moins un plan (contrôle du mode obligatoire).
      record UndistributedLineView,
        entry_id : Int64,
        line_id : Int64,
        position : Int32,
        date : Time,
        ledger_code : String,
        internal_code : String,
        account_number : String,
        amount : BigDecimal,
        missing_plan_ids : Array(Int64)

      # --- Éditions --------------------------------------------------------------------

      # Débit, crédit et solde d'un poste (`Anc_Balance_Simple`) : `balance`
      # est la valeur absolue de débit − crédit, `side` son sens (`nil` si nul).
      record Amounts, debit : BigDecimal, credit : BigDecimal do
        def self.zero : Amounts
          new(BigDecimal.new(0), BigDecimal.new(0))
        end

        def signed : BigDecimal
          debit - credit
        end

        def balance : BigDecimal
          signed.abs
        end

        def side : Side?
          return if signed.zero?
          signed > 0 ? Side::Debit : Side::Credit
        end

        def +(other : Amounts) : Amounts
          Amounts.new(debit + other.debit, credit + other.credit)
        end
      end

      # Critères communs : plan, dates (bornes incluses, `nil` = sans borne)
      # et intervalle de postes par code (`from_poste`, `to_poste`).
      record ReportQuery,
        plan_id : Int64,
        date_from : Time? = nil,
        date_to : Time? = nil,
        post_from : String? = nil,
        post_to : String? = nil

      # Balance simple.
      record BalanceRowView,
        post : PostRef,
        group_code : String?,
        group_description : String?,
        amounts : Amounts

      # `partial` : des imputations de journaux que l'acteur ne voit pas ont
      # été écartées.
      record BalanceView,
        plan : PlanView,
        date_from : Time?,
        date_to : Time?,
        rows : Array(BalanceRowView),
        total : Amounts,
        partial : Bool

      # Balance croisée double (`Anc_Balance_Double`) : deux plans, les lignes
      # de ventilation qui portent un poste dans chacun.
      record CrossBalanceQuery,
        plan_id : Int64,
        other_plan_id : Int64,
        date_from : Time? = nil,
        date_to : Time? = nil,
        post_from : String? = nil,
        post_to : String? = nil,
        other_post_from : String? = nil,
        other_post_to : String? = nil

      record CrossBalanceRowView, post : PostRef, other_post : PostRef, amounts : Amounts

      # `subtotals` : total de chaque poste du premier plan (`show_sum`).
      record CrossBalanceView,
        plan : PlanView,
        other_plan : PlanView,
        rows : Array(CrossBalanceRowView),
        subtotals : Array(BalanceRowView),
        total : Amounts,
        partial : Bool

      # Balance par groupe (`Anc_Group::get_result`) : postes rangés par
      # groupe ; `group_code` `nil` pour les postes sans groupe.
      record GroupBalanceSectionView,
        group_code : String?,
        group_description : String?,
        rows : Array(BalanceRowView),
        total : Amounts

      record GroupBalanceView, plan : PlanView, sections : Array(GroupBalanceSectionView), total : Amounts, partial : Bool

      # Opération analytique d'une édition (historique, grand livre).
      record OperationView,
        id : Int64,
        distribution_id : Int64,
        kind : String,
        date : Time,
        entry_id : Int64?,
        ledger_code : String,
        internal_code : String,
        receipt : String,
        account_number : String,
        card_code : String?,
        description : String,
        post : PostRef,
        side : Side,
        amount : BigDecimal do
        def debit : BigDecimal
          side.debit? ? amount : BigDecimal.new(0)
        end

        def credit : BigDecimal
          side.credit? ? amount : BigDecimal.new(0)
        end
      end

      # Historique (`Anc_Listing`) : opérations du plan, par date ; `total`
      # porte sur toutes les opérations retenues, `count` aussi.
      record HistoryView,
        plan : PlanView,
        operations : Array(OperationView),
        count : Int32,
        total : Amounts,
        partial : Bool

      # Grand livre analytique (`Anc_GrandLivre`) : une section par poste,
      # solde progressif (débit − crédit) sur chaque opération.
      record LedgerLineView, operation : OperationView, running : BigDecimal

      record LedgerSectionView, post : PostRef, lines : Array(LedgerLineView), total : Amounts

      record LedgerView, plan : PlanView, sections : Array(LedgerSectionView), total : Amounts, partial : Bool

      # Tableau croisé postes × comptes généraux ou fiches (`Anc_Table`,
      # `Anc_Acc_List`) : montants signés crédit − débit, lignes et
      # colonnes nulles écartées.
      enum TableAxis
        Account
        Card
      end

      record TableQuery,
        plan_id : Int64,
        axis : TableAxis = TableAxis::Account,
        date_from : Time? = nil,
        date_to : Time? = nil,
        post_from : String? = nil,
        post_to : String? = nil

      # `key` : numéro de compte ou quick code ; `label` : libellé du compte
      # ou nom de la fiche ; `amounts` : montant par identifiant de poste.
      record TableRowView, key : String, label : String, amounts : Hash(Int64, BigDecimal), total : BigDecimal

      record TableView,
        plan : PlanView,
        axis : TableAxis,
        posts : Array(PostRef),
        rows : Array(TableRowView),
        column_totals : Hash(Int64, BigDecimal),
        total : BigDecimal,
        partial : Bool

      # Fichier produit par une édition (CSV).
      record FileView, filename : String, content_type : String, content : Bytes
    end
  end
end
