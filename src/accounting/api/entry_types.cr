# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    module Accounting
      # --- Saisie ----------------------------------------------------------------

      # Sens d'une ligne (`j_debit`).
      enum Side
        Debit
        Credit

        # Valeur stockée (`debit`) ; libellé : `accounting.sides.<code>`.
        def code : String
          to_s.underscore
        end

        def opposite : Side
          debit? ? Credit : Debit
        end

        def self.from_code(code : String) : self
          parse(code)
        end
      end

      # Ligne saisie d'une écriture (`poste<i>` ou `qc_<i>`, `amount<i>`,
      # `ck<i>`, `ld<i>` du formulaire d'opérations diverses). `account` :
      # numéro du compte ; vide si `card` (quick code) est donné, le compte
      # étant alors celui de la fiche. Montant strictement positif, dans la
      # devise de l'écriture, en `BigDecimal`.
      record EntryLineInput,
        account : String,
        side : Side,
        amount : BigDecimal,
        card : String? = nil,
        label : String = ""

      # Requête de contrôle de l'équilibre seul (retour instantané de la saisie).
      record CheckEntryInput, lines : Array(EntryLineInput)

      # Écriture saisie ligne à ligne, dans n'importe quel journal (opérations
      # diverses, reprise, écritures produites par un autre module) : héritière
      # de `Acc_Ledger::save`.
      #
      # * `receipt` : numéro de pièce ; `nil` ou vide = le suivant du journal
      #   (`guess_pj`, réservé à l'enregistrement) ;
      # * `currency_code` : `nil` = devise du journal ; `currency_rate` : `nil`
      #   = cours du socle à la date (`Partiduo::Api::Core.rate_on`), 1 pour la
      #   devise de tenue ; les montants saisis sont dans la devise de
      #   l'écriture, convertis en devise de tenue (montant ÷ cours) ;
      # * `source` : référence libre de l'émetteur (`invoice:42`, `fec:…`),
      #   pour relire l'écriture depuis un abonné d'événement.
      record EntryInput,
        ledger_id : Int64,
        date : Time,
        lines : Array(EntryLineInput),
        label : String = "",
        receipt : String? = nil,
        due_date : Time? = nil,
        currency_code : String? = nil,
        currency_rate : BigDecimal? = nil,
        attachment_id : Int64? = nil,
        source : String = ""

      # Ligne d'une facture d'achat ou de vente (`e_march<i>`,
      # `e_march<i>_price`, `e_quant<i>`, `e_march<i>_tva_id`,
      # `e_march<i>_tva_amount`, `e_march<i>_label`).
      #
      # * `item` : quick code de la fiche article ou service ; son compte est
      #   imputé, sauf si `account` est donné ; à défaut des deux, le compte
      #   par défaut du journal ;
      # * `amount` : montant hors taxe de la ligne ; si `unit_price` est
      #   donné, il vaut `quantity × unit_price` et `amount` est ignoré ;
      #   négatif pour un avoir (le sens de la ligne s'inverse, comme
      #   `Acc_Operation::insert_jrnx`) ;
      # * `vat_rate` : code du taux de TVA ; `vat_amount` : TVA saisie, sinon
      #   calculée (arrondie au centime) ;
      # * montants dans la devise de l'écriture.
      record DocumentLineInput,
        amount : BigDecimal = BigDecimal.new(0),
        item : String? = nil,
        account : String? = nil,
        vat_rate : String? = nil,
        vat_amount : BigDecimal? = nil,
        label : String = "",
        quantity : BigDecimal? = nil,
        unit_price : BigDecimal? = nil

      # Facture ou avoir d'achat (`Acc_Ledger_Purchase::insert`) ou de vente
      # (`Acc_Ledger_Sale::insert`) : `third_party` est le quick code du
      # fournisseur ou du client, `due_date` l'échéance (`e_ech`).
      record DocumentInput,
        ledger_id : Int64,
        date : Time,
        third_party : String,
        lines : Array(DocumentLineInput),
        label : String = "",
        receipt : String? = nil,
        due_date : Time? = nil,
        currency_code : String? = nil,
        currency_rate : BigDecimal? = nil,
        attachment_id : Int64? = nil,
        source : String = ""

      # Ligne d'un extrait financier (`e_other<i>`, `e_other<i>_amount`,
      # `e_other<i>_comment`, `e_concerned<i>`) : contrepartie par fiche
      # (quick code) ou par compte ; montant *signé* — positif pour une
      # entrée en banque (la banque est débitée), négatif pour une sortie.
      # `match_line_ids` : lignes d'écritures à lettrer avec la ligne de
      # contrepartie (facture payée : `jrn_rapt` et lettrage), du même compte.
      # `date` : date propre de la ligne (`chdate = 2`), sinon celle de
      # l'extrait.
      record PaymentLineInput,
        amount : BigDecimal,
        card : String? = nil,
        account : String? = nil,
        label : String = "",
        date : Time? = nil,
        match_line_ids : Array(Int64) = [] of Int64

      # Extrait d'un journal financier (`Acc_Ledger_Fin::insert`) : *une
      # écriture par ligne*, chacune avec sa pièce. `receipt` donné : pièce de
      # l'extrait, suffixée du rang de la ligne s'il y en a plusieurs.
      record FinancialInput,
        ledger_id : Int64,
        date : Time,
        lines : Array(PaymentLineInput),
        receipt : String? = nil,
        currency_code : String? = nil,
        currency_rate : BigDecimal? = nil,
        attachment_id : Int64? = nil,
        source : String = ""

      # Annulation par extourne (`Acc_Ledger::reverse`) : écriture inverse à
      # `date` (celle de l'écriture si `nil`), dans une période ouverte ;
      # `label` : libellé de l'extourne (celui de l'écriture si vide).
      record CancelEntryInput, entry_id : Int64, date : Time? = nil, label : String = ""

      # --- Vues ------------------------------------------------------------------

      # Totaux d'une écriture contrôlée.
      record EntryCheckView, total_debit : BigDecimal, total_credit : BigDecimal, difference : BigDecimal do
        def balanced? : Bool
          difference.zero?
        end
      end

      # Ligne calculée par une requête de contrôle, avant enregistrement.
      record DraftLineView,
        account_number : String,
        account_label : String,
        card_code : String?,
        side : Side,
        amount : BigDecimal,
        currency_amount : BigDecimal?,
        label : String,
        vat_rate_code : String?,
        vat_role : String?

      # Écriture telle qu'elle serait enregistrée : lignes (TVA ventilée) et
      # totaux en devise de tenue ; hors taxe, TVA et toutes taxes d'une
      # facture.
      record EntryDraftView,
        lines : Array(DraftLineView),
        total_debit : BigDecimal,
        total_credit : BigDecimal,
        total_excluding_vat : BigDecimal,
        total_vat : BigDecimal,
        total_including_vat : BigDecimal,
        period_id : Int64?,
        receipt : String do
        def balanced? : Bool
          total_debit == total_credit
        end
      end

      record EntryLineView,
        id : Int64,
        position : Int32,
        account_id : Int64,
        account_number : String,
        account_label : String,
        card_id : Int64?,
        card_code : String?,
        side : Side,
        amount : BigDecimal,
        currency_amount : BigDecimal?,
        label : String,
        vat_rate_id : Int64?,
        vat_rate_code : String?,
        vat_role : String?,
        quantity : BigDecimal?,
        matching_id : Int64?,
        matching_code : String? do
        def debit : BigDecimal
          side.debit? ? amount : BigDecimal.new(0)
        end

        def credit : BigDecimal
          side.credit? ? amount : BigDecimal.new(0)
        end
      end

      record EntryView,
        id : Int64,
        ledger_id : Int64,
        ledger_code : String,
        ledger_kind : LedgerKind,
        period_id : Int64,
        date : Time,
        due_date : Time?,
        label : String,
        receipt : String?,
        internal_code : String,
        amount : BigDecimal,
        currency_code : String,
        currency_rate : BigDecimal,
        reversal_of_id : Int64?,
        reversed_by_id : Int64?,
        attachment_id : Int64?,
        source : String,
        created_by_id : Int64?,
        created_at : Time,
        lines : Array(EntryLineView) do
        # Écriture annulée par une extourne.
        def cancelled? : Bool
          !reversed_by_id.nil?
        end

        # Extourne d'une autre écriture (`jr_optype = 'EXT'`).
        def reversal? : Bool
          !reversal_of_id.nil?
        end

        def total_debit : BigDecimal
          lines.sum(BigDecimal.new(0), &.debit)
        end

        def total_credit : BigDecimal
          lines.sum(BigDecimal.new(0), &.credit)
        end
      end

      # --- Recherche -------------------------------------------------------------

      # Critères de recherche (`Acc_Ledger_Search`) : journal ou type de
      # journal, dates, période, compte (numéro exact, ou préfixe avec
      # `account_prefix`), fiche (quick code), pièce, libellé ou code interne
      # (contient, sans casse), montant d'en-tête, écritures annulées ou non.
      record EntryQuery,
        ledger_id : Int64? = nil,
        ledger_kind : LedgerKind? = nil,
        date_from : Time? = nil,
        date_to : Time? = nil,
        period_id : Int64? = nil,
        account : String? = nil,
        account_prefix : Bool = false,
        card : String? = nil,
        receipt : String? = nil,
        text : String? = nil,
        amount_min : BigDecimal? = nil,
        amount_max : BigDecimal? = nil,
        source : String? = nil,
        include_cancelled : Bool = true,
        offset : Int32 = 0,
        limit : Int32 = 50

      # --- Lettrage --------------------------------------------------------------

      record MatchingLineView,
        line_id : Int64,
        entry_id : Int64,
        ledger_code : String,
        ledger_kind : LedgerKind,
        date : Time,
        receipt : String?,
        label : String,
        side : Side,
        amount : BigDecimal

      # Lettrage : code affiché (lettres tirées de l'identifiant : `A`, `B`…,
      # `AA`), compte, lignes ; `difference` = débit − crédit (nul pour un
      # lettrage équilibré, sinon lettrage partiel).
      record MatchingView,
        id : Int64,
        code : String,
        account_id : Int64,
        account_number : String,
        lines : Array(MatchingLineView),
        difference : BigDecimal,
        created_at : Time do
        def balanced? : Bool
          difference.zero?
        end
      end

      # --- Consultation d'un compte ou d'un tiers (ADR-005 D9) -----------------

      # Sélection par compte (numéro) ou par fiche (quick code : ses lignes,
      # quel que soit le compte) ; mouvements de `date_from` à `date_to` ;
      # `unmatched_only` : lignes non lettrées (ou d'un lettrage partiel)
      # seulement ; `as_of` : date de référence de l'échu et de la balance
      # âgée (aujourd'hui par défaut).
      record StatementQuery,
        account : String? = nil,
        card : String? = nil,
        date_from : Time? = nil,
        date_to : Time? = nil,
        unmatched_only : Bool = false,
        as_of : Time? = nil

      # Mouvement : `balance` = solde progressif (débit − crédit) ;
      # `overdue` : échéance dépassée à la date de référence sur une ligne
      # non lettrée.
      record StatementLineView,
        line_id : Int64,
        entry_id : Int64,
        date : Time,
        ledger_code : String,
        receipt : String?,
        label : String,
        due_date : Time?,
        overdue : Bool,
        debit : BigDecimal,
        credit : BigDecimal,
        balance : BigDecimal,
        matching_id : Int64?,
        matching_code : String?

      # Balance âgée des éléments ouverts (non échu, 1 à 30 jours, 31 à 60,
      # plus de 60), montants signés débit − crédit.
      record AgeingView,
        not_due : BigDecimal,
        days_1_30 : BigDecimal,
        days_31_60 : BigDecimal,
        over_60 : BigDecimal do
        def total : BigDecimal
          not_due + days_1_30 + days_31_60 + over_60
        end
      end

      # Synthèse et mouvements d'un compte ou d'un tiers. Montants signés
      # débit − crédit : positif = solde débiteur (un client doit), négatif =
      # solde créditeur (on doit au fournisseur).
      #
      # * `opening_balance` : solde avant `date_from` ;
      # * `balance` : solde à `date_to` ;
      # * `remaining` : reste dû (éléments non lettrés, et reliquat des
      #   lettrages partiels) ;
      # * `overdue` : part échue du reste dû.
      record AccountStatementView,
        account : AccountView?,
        card_id : Int64?,
        card_code : String?,
        card_name : String?,
        opening_balance : BigDecimal,
        total_debit : BigDecimal,
        total_credit : BigDecimal,
        balance : BigDecimal,
        remaining : BigDecimal,
        overdue : BigDecimal,
        ageing : AgeingView,
        lines : Array(StatementLineView)

      # Reste dû et échu cumulés des fiches d'une nature (`customer`,
      # `supplier`), calculés par PostgreSQL avec les règles du relevé
      # (`account_statement`) ; `worst_*` : la fiche dont l'échu est le plus
      # fort en valeur absolue (`nil` si rien n'est échu).
      record PartyBalancesView,
        kind : String,
        cards : Int32,
        remaining : BigDecimal,
        overdue : BigDecimal,
        worst_card_code : String?,
        worst_card_name : String?,
        worst_overdue : BigDecimal
    end
  end
end
