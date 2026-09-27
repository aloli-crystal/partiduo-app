# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    module Accounting
      # --- Éditions (lot 3) : requêtes et objets de vue ---------------------------
      #
      # Montants en devise de tenue. Dates : `Time` à minuit UTC. Toutes les
      # éditions ne lisent que les journaux visibles de l'acteur
      # (`get_ledger_sql` de NOALYSS). Période par défaut : de début de
      # l'exercice qui contient `date_to` jusqu'à `date_to` (défaut : la date
      # du jour de l'instance).

      # Format d'un fichier exporté.
      enum ExportFormat
        Csv
        Pdf
      end

      # Fichier produit par une édition (CSV, PDF, FEC).
      record FileView, filename : String, content_type : String, content : Bytes

      # Solde présenté en deux colonnes : `debit` si le solde signé
      # (débit − crédit) est positif, `credit` sinon (`solde_deb` /
      # `solde_cred` de `Acc_Balance`).
      record SplitBalance, debit : BigDecimal, credit : BigDecimal do
        def self.of(signed : BigDecimal) : SplitBalance
          zero = BigDecimal.new(0)
          signed >= 0 ? new(signed, zero) : new(zero, -signed)
        end

        def signed : BigDecimal
          debit - credit
        end
      end

      # --- Balance générale (`Acc_Balance`) ------------------------------------

      # * `ledger_ids` / `ledger_kinds` : restreint aux journaux donnés
      #   (`filter_cat`) ; `nil` = tous les journaux visibles ;
      # * `account_from` / `account_to` : bornes sur le numéro (comparaison
      #   de texte, comme `j_poste::text >= …`) ;
      # * `nonzero_only` : masque les comptes soldés (`unsold`).
      record TrialBalanceQuery,
        date_from : Time? = nil,
        date_to : Time? = nil,
        ledger_ids : Array(Int64)? = nil,
        ledger_kinds : Array(LedgerKind)? = nil,
        account_from : String? = nil,
        account_to : String? = nil,
        nonzero_only : Bool = false

      # Ligne de balance : solde d'ouverture (lignes de l'exercice
      # antérieures à `date_from`), mouvements de la période, solde final,
      # nombre de lignes de la période.
      record TrialBalanceRowView,
        number : String,
        label : String,
        kind : AccountKind?,
        opening : SplitBalance,
        debit : BigDecimal,
        credit : BigDecimal,
        closing : SplitBalance,
        lines : Int32

      # Synthèse par classe (`summary_add` : classes 1 à 5, 6 et 7), soldes
      # signés débit − crédit ; `result` = produits − charges.
      record ClassSummaryView, balance_sheet : BigDecimal, expenses : BigDecimal, income : BigDecimal do
        def result : BigDecimal
          -(expenses + income)
        end
      end

      record TrialBalanceView,
        date_from : Time,
        date_to : Time,
        rows : Array(TrialBalanceRowView),
        classes : Array(TrialBalanceRowView),
        total : TrialBalanceRowView,
        summary : ClassSummaryView do
        # Écart débit − crédit des mouvements (zéro si les écritures sont
        # équilibrées ; `Totaux delta` de NOALYSS).
        def delta : BigDecimal
          total.debit - total.credit
        end
      end

      # --- Balance des tiers (`balance_card.inc.php`) --------------------------

      # `kind` : nature des fiches (`customer`, `supplier`, `employee`…) ;
      # `nil` = clients et fournisseurs. `account` : lignes des comptes commençant par ce
      # numéro seulement (`411`).
      record AuxiliaryBalanceQuery,
        date_from : Time? = nil,
        date_to : Time? = nil,
        kind : String? = nil,
        account : String? = nil,
        ledger_ids : Array(Int64)? = nil,
        nonzero_only : Bool = false

      record AuxiliaryBalanceRowView,
        card_id : Int64,
        card_code : String,
        card_name : String,
        card_kind : String,
        account_number : String?,
        opening : SplitBalance,
        debit : BigDecimal,
        credit : BigDecimal,
        closing : SplitBalance,
        lines : Int32

      record AuxiliaryBalanceView,
        date_from : Time,
        date_to : Time,
        rows : Array(AuxiliaryBalanceRowView),
        total : AuxiliaryBalanceRowView

      # --- Balance âgée (`Balance_Age`) ----------------------------------------

      # Au jour `as_of` (défaut : aujourd'hui) : seules comptent les lignes
      # datées au plus tard ce jour-là. `kind` : `customer`, `supplier` ;
      # `nil` = les deux. `card` : une seule fiche (quick code).
      record AgedBalanceQuery,
        as_of : Time? = nil,
        kind : String? = nil,
        card : String? = nil,
        ledger_ids : Array(Int64)? = nil

      # Élément ouvert : ligne non lettrée, ou reliquat d'un lettrage partiel
      # (`entry_id` nul, `matching_code` donné) daté de sa plus ancienne
      # échéance. `days` : jours de retard à `as_of` (négatif ou nul = non
      # échu). Montant signé débit − crédit.
      record OpenItemView,
        line_id : Int64?,
        entry_id : Int64?,
        date : Time,
        due_date : Time?,
        ledger_code : String?,
        receipt : String?,
        label : String,
        matching_code : String?,
        days : Int32,
        amount : BigDecimal

      record AgedBalanceRowView,
        card_id : Int64,
        card_code : String,
        card_name : String,
        card_kind : String,
        remaining : BigDecimal,
        overdue : BigDecimal,
        ageing : AgeingView,
        items : Array(OpenItemView)

      record AgedBalanceView,
        as_of : Time,
        rows : Array(AgedBalanceRowView),
        remaining : BigDecimal,
        overdue : BigDecimal,
        ageing : AgeingView

      # --- Grand livre (`impress_gl_comptes`, `impress_poste`) -----------------

      # Par compte (défaut) ou, avec `by_card`, par fiche de tiers (grand
      # livre auxiliaire, `kind` en filtre, défaut : clients et
      # fournisseurs). `card` : une seule fiche.
      # `account_from` / `account_to` : bornes sur le numéro de compte.
      record GeneralLedgerQuery,
        date_from : Time? = nil,
        date_to : Time? = nil,
        account_from : String? = nil,
        account_to : String? = nil,
        ledger_ids : Array(Int64)? = nil,
        by_card : Bool = false,
        kind : String? = nil,
        card : String? = nil

      # Mouvement : `balance` = solde progressif signé du compte ou du tiers.
      record GeneralLedgerLineView,
        line_id : Int64,
        entry_id : Int64,
        date : Time,
        ledger_code : String,
        receipt : String?,
        internal_code : String,
        label : String,
        account_number : String,
        card_code : String?,
        debit : BigDecimal,
        credit : BigDecimal,
        balance : BigDecimal,
        matching_code : String?

      # Section d'un compte (`key` = numéro) ou d'une fiche (`key` = quick
      # code) : solde d'ouverture et de clôture signés.
      record GeneralLedgerSectionView,
        key : String,
        label : String,
        opening_balance : BigDecimal,
        lines : Array(GeneralLedgerLineView),
        total_debit : BigDecimal,
        total_credit : BigDecimal,
        closing_balance : BigDecimal

      record GeneralLedgerView,
        date_from : Time,
        date_to : Time,
        by_card : Bool,
        sections : Array(GeneralLedgerSectionView),
        total_debit : BigDecimal,
        total_credit : BigDecimal

      # --- Journaux (`impress_jrn`, `Print_Ledger`) ----------------------------

      # `ledger_ids` : `nil` = tous les journaux visibles.
      record JournalQuery,
        date_from : Time? = nil,
        date_to : Time? = nil,
        ledger_ids : Array(Int64)? = nil

      record JournalLineView,
        account_number : String,
        account_label : String,
        card_code : String?,
        label : String,
        debit : BigDecimal,
        credit : BigDecimal

      record JournalEntryView,
        entry_id : Int64,
        date : Time,
        receipt : String?,
        internal_code : String,
        label : String,
        reversal_of_id : Int64?,
        lines : Array(JournalLineView),
        debit : BigDecimal,
        credit : BigDecimal

      # Totaux d'un mois (`AAAA-MM`) ou d'un compte (journal centralisateur).
      record JournalTotalView, key : String, label : String, entries : Int32, debit : BigDecimal, credit : BigDecimal

      record LedgerJournalView,
        ledger_id : Int64,
        ledger_code : String,
        ledger_name : String,
        ledger_kind : LedgerKind,
        entries : Array(JournalEntryView),
        months : Array(JournalTotalView),
        accounts : Array(JournalTotalView),
        total_debit : BigDecimal,
        total_credit : BigDecimal

      record JournalView,
        date_from : Time,
        date_to : Time,
        ledgers : Array(LedgerJournalView),
        entries : Int32,
        total_debit : BigDecimal,
        total_credit : BigDecimal

      # --- Bilan et compte de résultat (`Acc_Bilan`, `Impress`) ----------------

      enum StatementKind
        BalanceSheet
        IncomeStatement

        def code : String
          to_s.underscore
        end
      end

      # `regime` : `fr` ou `be` ; `nil` = régime de l'instance.
      # `compare` : colonne de l'exercice précédent (mêmes dates, un an
      # plus tôt).
      record FinancialStatementQuery,
        kind : StatementKind,
        date_from : Time? = nil,
        date_to : Time? = nil,
        regime : String? = nil,
        compare : Bool = true

      # Rubrique : `style` `heading` (titre, sans montant), `line`,
      # `subtotal` ou `total`. Libellé : `label_key` (i18n). `gross` et
      # `less` (amortissements et dépréciations) pour l'actif ; `net` pour
      # toutes les rubriques chiffrées.
      record FinancialStatementLineView,
        code : String,
        label_key : String,
        style : String,
        level : Int32,
        gross : BigDecimal?,
        less : BigDecimal?,
        net : BigDecimal?,
        previous : BigDecimal?

      # Compte dont le solde n'est repris par aucune rubrique, ou compte dont
      # le solde est à contre-sens de son type (`Acc_Bilan::verify`).
      record StatementAccountView, number : String, label : String, kind : AccountKind?, balance : BigDecimal

      # `difference` : actif − passif pour un bilan, zéro pour un compte de
      # résultat ; `result` : résultat de la période (produits − charges).
      # Un bilan part toujours du début de l'exercice de `date_to`
      # (`date_from` est alors ce jour-là). `partial` : l'état ne porte que
      # sur les journaux visibles de l'acteur, qui ne les voit pas tous.
      record FinancialStatementView,
        kind : StatementKind,
        regime : String,
        date_from : Time,
        date_to : Time,
        previous_from : Time?,
        previous_to : Time?,
        lines : Array(FinancialStatementLineView),
        difference : BigDecimal,
        result : BigDecimal,
        unmapped : Array(StatementAccountView),
        anomalies : Array(StatementAccountView),
        partial : Bool = false do
        def line(code : String) : FinancialStatementLineView?
          lines.find(&.code.==(code))
        end
      end

      # --- Rapports personnalisés (`formulaire`, `form_definition`) ------------

      # Ligne : libellé et formule (`[70%]-[60%]`, voir
      # `doc/api/accounting-reports.adoc`).
      record ReportLineInput, label : String, formula : String

      record ReportDefinitionInput, name : String, lines : Array(ReportLineInput)

      record ReportLineView, position : Int32, label : String, formula : String

      record ReportDefinitionView, id : Int64, name : String, lines : Array(ReportLineView)

      record ReportResultLineView, position : Int32, label : String, formula : String, amount : BigDecimal

      record ReportResultView,
        id : Int64,
        name : String,
        date_from : Time,
        date_to : Time,
        lines : Array(ReportResultLineView)

      # --- FEC (article A47 A-1 du LPF) ----------------------------------------

      enum FecSeparator
        Pipe
        Tab

        def char : Char
          pipe? ? '|' : '\t'
        end
      end

      enum FecEncoding
        Iso885915
        Utf8
      end

      # Un exercice (`fiscal_year_id`) ou des dates comprises dans un même
      # exercice ; défaut : l'exercice qui contient la date du jour.
      record FecQuery,
        fiscal_year_id : Int64? = nil,
        date_from : Time? = nil,
        date_to : Time? = nil,
        separator : FecSeparator = FecSeparator::Pipe,
        encoding : FecEncoding = FecEncoding::Iso885915
    end
  end
end
