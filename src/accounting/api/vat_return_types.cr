# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    module Accounting
      # --- Déclarations de TVA (lot 4) ---------------------------------------------

      # Fichier d'une déclaration : XML Intervat (formulaires belges), CSV ou
      # PDF (tous).
      enum VatFileFormat
        Xml
        Csv
        Pdf
      end

      # Déclaration à calculer.
      #
      # * `form` : `be_periodic`, `be_client_listing`, `be_intra_listing`,
      #   `fr_ca3`, `fr_ca12` ;
      # * `periodicity` : `month`, `quarter` (déclarations périodiques, relevé
      #   intracommunautaire) ou `year` (listing des clients, CA12) ; `number`
      #   : mois (1-12) ou trimestre (1-4) de `year` ;
      # * `date_from`, `date_to` : bornes données (exercice décalé d'une CA12),
      #   sinon celles de la période ;
      # * `exigibility` : `rates` (selon l'exigibilité de chaque taux :
      #   encaissements ou débits), `operation`, `payment` ;
      # * `threshold` : chiffre d'affaires minimal d'un client du listing
      #   (250 € par défaut).
      record VatReturnInput,
        form : String,
        year : Int32,
        periodicity : String = "quarter",
        number : Int32 = 1,
        date_from : Time? = nil,
        date_to : Time? = nil,
        exigibility : String = "rates",
        threshold : BigDecimal? = nil

      # Correction d'une case : `amount` nil rend la case au montant calculé.
      record VatAdjustment, code : String, amount : BigDecimal?

      record VatReturnUpdateInput,
        adjustments : Array(VatAdjustment) = [] of VatAdjustment,
        client_listing_nihil : Bool? = nil,
        ask_restitution : Bool? = nil

      # Écriture de liquidation (`propose_form` de l'extension TVA) : journal
      # d'opérations diverses (défaut : le premier), date (défaut : fin de la
      # période), compte de la dette de TVA (défaut : compte par défaut
      # `vat`) et de la créance (défaut : `411` en Belgique, `44567` en
      # France). France seulement : écart d'arrondi à l'euro en charge
      # (défaut `658`) ou en produit (`758`), acomptes versés d'une CA12
      # (`44581`), remboursement demandé d'une CA3 (`44583`).
      record VatSettlementInput,
        ledger_id : Int64? = nil,
        date : Time? = nil,
        payable_account : String? = nil,
        receivable_account : String? = nil,
        rounding_expense_account : String? = nil,
        rounding_income_account : String? = nil,
        advance_account : String? = nil,
        refund_account : String? = nil

      # Case d'une déclaration : montant calculé depuis les écritures,
      # montant déclaré (corrigé ou non), total du formulaire.
      record VatBoxView,
        code : String,
        label_key : String,
        section_key : String,
        computed : BigDecimal,
        amount : BigDecimal,
        adjusted : Bool,
        total : Bool

      # Ligne d'un relevé : client, numéro de TVA, code intracommunautaire
      # (`L`, `S`, `T`), montant hors taxe, TVA.
      record VatListingLineView,
        card_id : Int64?,
        card_code : String?,
        name : String,
        vat_number : String,
        code : String,
        amount : BigDecimal,
        vat : BigDecimal

      record VatReturnView,
        id : Int64?,
        form : String,
        regime : String,
        year : Int32,
        periodicity : String,
        number : Int32,
        date_from : Time,
        date_to : Time,
        exigibility : String,
        status : String,
        threshold : BigDecimal?,
        client_listing_nihil : Bool,
        ask_restitution : Bool,
        boxes : Array(VatBoxView),
        lines : Array(VatListingLineView),
        settlement_entry_id : Int64?,
        closed_at : Time?,
        closed_by_id : Int64?,
        created_at : Time? do
        # Clé i18n du formulaire (`vat.forms.fr_ca3`).
        def name_key : String
          "vat.forms.#{form}"
        end

        def closed? : Bool
          status == "closed"
        end

        def box(code : String) : VatBoxView?
          boxes.find(&.code.==(code))
        end

        # Montant déclaré d'une case (0 si absente).
        def amount(code : String) : BigDecimal
          box(code).try(&.amount) || BigDecimal.new(0)
        end

        # Lignes de l'annexe 3310-A d'une CA3 ou d'une CA12 (ligne 14 taux
        # par taux) : `vat_number` porte le code du taux, `name` son libellé
        # et son pourcentage, `amount` la base, `vat` la taxe (D-R5-006).
        def annex_lines : Array(VatListingLineView)
          regime == "fr" ? lines.select(&.code.==(Partiduo::Vat::Fr::ANNEX_CODE)) : [] of VatListingLineView
        end
      end

      # Apport d'une règle à une case (`declaration_amount_detail`).
      record VatDetailView,
        box : String,
        position : Int32,
        source : String,
        vat_rate_code : String?,
        ledger_kind : String?,
        ledger_code : String?,
        accounts : String,
        excluded_accounts : String,
        sign : String,
        operation : String,
        amount : BigDecimal,
        lines : Int32

      # Règle de calcul d'une case (`parameter_chld`) : taux (tous si nil),
      # nature de journal (`purchase`, `sale`, `misc`, `financial`) ou
      # journal, préfixes de comptes retenus et exclus (séparés par des
      # virgules), source (`base`, `deductible`, `collected`, `balance`),
      # signe retenu (`all`, `positive`, `negative`), opération (`add`,
      # `subtract`).
      record VatBoxRuleInput,
        vat_rate_code : String? = nil,
        ledger_kind : String? = nil,
        ledger_code : String? = nil,
        accounts : String = "",
        excluded_accounts : String = "",
        source : String = "base",
        sign : String = "all",
        operation : String = "add"

      record VatBoxRuleView,
        regime : String,
        box : String,
        position : Int32,
        vat_rate_id : Int64?,
        vat_rate_code : String?,
        ledger_kind : String?,
        ledger_id : Int64?,
        ledger_code : String?,
        accounts : String,
        excluded_accounts : String,
        source : String,
        sign : String,
        operation : String,
        default : Bool

      # Case d'un formulaire (catalogue) : réglée par des règles, total,
      # corrigeable.
      record VatFormBoxView, code : String, label_key : String, section_key : String, ruled : Bool, total : Bool

      record VatFormView,
        form : String,
        regime : String,
        name_key : String,
        periodicities : Array(String),
        listing : Bool,
        settles : Bool,
        boxes : Array(VatFormBoxView)

      # Mandataire des fichiers Intervat (`tva_belge.representative`).
      record VatSettingsInput,
        representative_id : String = "",
        representative_id_type : String = "",
        representative_issued_by : String = "",
        representative_name : String = "",
        representative_street : String = "",
        representative_postcode : String = "",
        representative_city : String = "",
        representative_country_code : String = "",
        representative_email : String = "",
        representative_phone : String = ""

      record VatSettingsView,
        representative_id : String,
        representative_id_type : String,
        representative_issued_by : String,
        representative_name : String,
        representative_street : String,
        representative_postcode : String,
        representative_city : String,
        representative_country_code : String,
        representative_email : String,
        representative_phone : String do
        def representative? : Bool
          !representative_name.empty?
        end
      end
    end
  end
end
