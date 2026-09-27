# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    module Accounting
      # Type d'un compte, héritier de `pcm_type` (`Acc_Account::$type`) :
      # ACT, PAS, ACTINV, PASINV, PRO, PROINV, CHA, CHAINV, CON.
      enum AccountKind
        Asset
        Liability
        AssetContra
        LiabilityContra
        Income
        IncomeContra
        Expense
        ExpenseContra
        Context

        # Valeur stockée (`asset_contra`) ; libellé : `accounting.account_kinds.<code>`.
        def code : String
          to_s.underscore
        end

        def self.from_code(code : String) : self
          parse(code)
        end
      end

      # Type d'un journal, héritier de `jrn_type` : ACH, VEN, FIN, ODS.
      enum LedgerKind
        Purchase
        Sale
        Financial
        Misc

        # Valeur stockée (`purchase`) ; libellé : `accounting.ledger_kinds.<code>`.
        def code : String
          to_s.underscore
        end

        def self.from_code(code : String) : self
          parse(code)
        end
      end

      # Droit d'un acteur sur un journal (`user_sec_jrn` : `W`, `R`, `X`),
      # tel que le calcule le socle (`Partiduo::Api::Auth.ledger_access`).
      enum LedgerAccess
        None
        Read
        Write

        def self.from_code(code : String) : self
          case code
          when "W" then Write
          when "R" then Read
          else          None
          end
        end

        def readable? : Bool
          !none?
        end

        def writable? : Bool
          write?
        end
      end

      # Usages des comptes par défaut, héritiers de `parm_code` (CUSTOMER,
      # SUPPLIER, BANQUE, CAISSE, VENTE, VIREMENT_INTERNE, COMPTE_COURANT,
      # COMPTE_TVA, DNA, TVA_DNA, TVA_DED_IMPOT, DEP_PRIV). Libellé :
      # `accounting.default_accounts.<code>`.
      DEFAULT_ACCOUNT_CODES = %w[
        customer supplier bank cash sales internal_transfer current_account
        vat non_deductible non_deductible_vat vat_deductible_tax private_expense
      ]

      # --- Plan comptable ------------------------------------------------------

      record AccountView,
        id : Int64,
        number : String,
        label : String,
        parent_id : Int64?,
        parent_number : String?,
        kind : AccountKind,
        direct_use : Bool

      # Ligne de l'arbre du plan comptable : le compte, sa profondeur (0 pour la
      # racine demandée) et son nombre d'enfants directs.
      record ChartLineView, account : AccountView, depth : Int32, children_count : Int32 do
        def leaf? : Bool
          children_count.zero?
        end
      end

      # Saisie d'un compte. Le numéro est normalisé comme
      # `comptaproc.format_account` (majuscules, accents et ponctuation
      # retirés). `parent` : numéro du compte parent ; `nil` = le plus long
      # préfixe existant du numéro (`account_parent`). `kind` : `nil` = celui du
      # parent (`find_pcm_type`), `Context` pour une racine.
      record AccountInput,
        number : String,
        label : String,
        parent : String? = nil,
        kind : AccountKind? = nil,
        direct_use : Bool = true

      record DefaultAccountView, code : String, account : AccountView

      # --- Journaux --------------------------------------------------------------

      record LedgerView,
        id : Int64,
        code : String,
        name : String,
        kind : LedgerKind,
        description : String,
        enabled : Bool,
        default_account : AccountView?,
        receipt_prefix : String,
        receipt_padding : Int32,
        last_receipt_number : Int64,
        currency_code : String,
        access : LedgerAccess,
        bank_card_id : Int64? = nil,
        bank_card_code : String? = nil do
        # Numéro de la prochaine pièce (`Acc_Ledger::guess_pj`), sans le réserver.
        def next_receipt : String
          Partiduo::Accounting::Receipts.format(receipt_prefix, receipt_padding, last_receipt_number + 1)
        end
      end

      # Saisie d'un journal. `code` : `nil` ou vide = attribué comme NOALYSS
      # (initiale du type puis rang en base 36 : `A01`, `V02`…).
      # `default_account` : numéro du compte par défaut d'un journal d'achats,
      # de ventes ou d'opérations diverses ; ignoré pour un journal financier.
      # `bank_card` : quick code de la fiche Banque (catégorie de nature
      # `bank`) d'un journal financier, obligatoire pour lui (`jrn_def_bank`,
      # D-ACC-010) ; le compte du journal est celui de la fiche.
      # `next_receipt_number` : repositionne la numérotation des pièces
      # (`jrn_def_pj_seq`) ; `nil` = inchangée. `currency_code` : `nil` = la
      # devise de tenue du dossier (`Partiduo::Api::Core.base_currency`).
      record LedgerInput,
        name : String,
        kind : LedgerKind,
        code : String? = nil,
        description : String = "",
        enabled : Bool = true,
        default_account : String? = nil,
        receipt_prefix : String = "",
        receipt_padding : Int32 = 0,
        next_receipt_number : Int64? = nil,
        currency_code : String? = nil,
        bank_card : String? = nil

      # Comptes de TVA d'un taux du socle (`tva_rate.tva_poste`) : compte de
      # TVA déductible (achats) et de TVA collectée (ventes).
      record VatRateAccountsView, vat_rate_id : Int64, vat_rate_code : String,
        deductible_account : AccountView?, collected_account : AccountView?

      # Saisie des comptes de TVA d'un taux, par numéro ; les deux sont
      # obligatoires pour un taux autoliquidé.
      record VatRateAccountsInput, vat_rate_id : Int64, deductible_account : String? = nil,
        collected_account : String? = nil

      # --- Fiches et catégories ------------------------------------------------

      record CardAccountView, card_id : Int64, account : AccountView

      record CardCategoryAccountView, category_id : Int64, base_account : AccountView?, create_account : Bool

      # Compte de base d'une catégorie de fiches (`fd_class_base`) et création
      # automatique d'un compte par fiche (`fd_create_account`).
      record CardCategoryAccountInput, category_id : Int64, base_account : String? = nil, create_account : Bool = false

      # Rattachement d'une fiche du socle à un compte (`comptaproc.account_insert`).
      # `account` donné : ce compte, créé s'il n'existe pas (libellé : le nom de
      # la fiche ; parent : le compte de base de sa catégorie, sinon le plus
      # long préfixe). `account` absent : compte calculé sous le compte de base
      # si la catégorie crée un compte par fiche, sinon le compte de base.
      record AssignCardAccountInput, card_id : Int64, account : String? = nil

      # --- Données initiales ---------------------------------------------------

      record InitialDataView, accounts : Int32, default_accounts : Int32, card_categories : Int32, ledgers : Int32
    end
  end
end
