# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Vat
    # Déclaration de TVA ou relevé (lot 4), successeur des tables
    # `tva_belge.declaration_amount`, `tva_belge.assujetti` et
    # `tva_belge.intracomm` de l'extension TVA de NOALYSS, étendu aux
    # déclarations françaises (CA3, CA12).
    #
    # * `form` : `be_periodic` (déclaration périodique), `be_client_listing`
    #   (listing annuel des clients assujettis), `be_intra_listing` (relevé
    #   intracommunautaire), `fr_ca3`, `fr_ca12` ;
    # * `periodicity` (`month`, `quarter`, `year`), `period_number` et `year`
    #   (`periodicity`, `periode_dec`, `exercice`) ; `date_from`, `date_to` :
    #   bornes calculées ou saisies ;
    # * `exigibility` : `rates` (selon le taux : `sale_on_payment`,
    #   `purchase_on_payment`), `operation` (date de l'opération) ou
    #   `payment` (date du paiement), comme `Tax_Summary::tva_type` ;
    # * `status` : `draft` puis `closed` ; une déclaration close est figée
    #   par PostgreSQL (migration vat 0002), seule l'écriture de liquidation
    #   (`settlement_entry_id`, écriture de la Comptabilité) peut s'y
    #   rattacher une fois.
    #
    # Modèle interne : écrit par `Partiduo::Api::Accounting` (`create_vat_return`
    # et suivants), les déclarations relevant du module Comptabilité
    # (ADR-006 D1).
    class Return < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :regime, :string, max_size: 2
      field :form, :string, max_size: 20
      field :year, :int
      field :periodicity, :string, max_size: 8
      field :period_number, :int, default: 1
      field :date_from, :date
      field :date_to, :date
      field :exigibility, :string, max_size: 10, default: "rates"
      field :status, :string, max_size: 8, default: "draft"
      # Relevé des clients : chiffre d'affaires minimal par client.
      field :threshold, :decimal, max_digits: 20, decimal_places: 4, null: true, blank: true
      # `ClientListingNihil` et `Ask Restitution` de la déclaration belge.
      field :client_listing_nihil, :bool, default: false
      field :ask_restitution, :bool, default: false
      # Écriture de liquidation (`accounting_entry`, module Comptabilité).
      field :settlement_entry_id, :big_int, null: true, blank: true
      field :closed_at, :date_time, null: true, blank: true
      field :closed_by_id, :big_int, null: true, blank: true
      field :created_by_id, :big_int, null: true, blank: true

      with_timestamp_fields
    end

    # Case d'une déclaration (`d00`… de `declaration_amount`) : montant
    # calculé depuis les écritures (`computed`) et montant déclaré
    # (`amount`), égal au calculé sauf correction saisie (`adjusted`).
    class ReturnBox < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :vat_return, :many_to_one, to: Partiduo::Vat::Return, related: :boxes, on_delete: :cascade
      field :code, :string, max_size: 12
      field :computed, :decimal, max_digits: 20, decimal_places: 4
      field :amount, :decimal, max_digits: 20, decimal_places: 4
      field :adjusted, :bool, default: false
    end

    # Ligne d'un relevé (`assujetti_chld`, `intracomm_chld`) : client, numéro
    # de TVA, code (`L`, `S`, `T` du relevé intracommunautaire), montant
    # hors taxe et TVA.
    class ReturnLine < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :vat_return, :many_to_one, to: Partiduo::Vat::Return, related: :lines, on_delete: :cascade
      field :position, :int, default: 0
      # Fiche du socle (`cards_card`) ; clé étrangère posée par la migration.
      field :card_id, :big_int, null: true, blank: true
      field :name, :string, max_size: 255, blank: true, default: ""
      field :vat_number, :string, max_size: 20, blank: true, default: ""
      field :code, :string, max_size: 1, blank: true, default: ""
      field :amount, :decimal, max_digits: 20, decimal_places: 4
      field :vat, :decimal, max_digits: 20, decimal_places: 4
    end

    # Règle de calcul d'une case, successeur de `tva_belge.parameter_chld` :
    # taux (`tva_id`, tous si vide), nature ou journal (`filter_ledger`,
    # `ledger_id`), comptes (`pcm_val`, préfixes séparés par des virgules,
    # et comptes exclus), source (`base` : hors taxe ; `deductible`,
    # `collected` : TVA ; `balance` : solde des comptes d'un journal
    # d'opérations diverses ou financier), signe retenu (`p_side`) et
    # opération (`p_operation` : `add`, `subtract`).
    class BoxRule < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :regime, :string, max_size: 2
      field :box, :string, max_size: 12
      field :position, :int, default: 0
      # Taux (`vat_rate`) ; clé étrangère en cascade posée par la migration.
      field :vat_rate_id, :big_int, null: true, blank: true
      field :ledger_kind, :string, max_size: 10, null: true, blank: true
      # Journal de la Comptabilité (`accounting_ledger`) ; contrôlé par le
      # contrat, sans clé étrangère (le socle ne dépend pas du module).
      field :ledger_id, :big_int, null: true, blank: true
      field :accounts, :string, max_size: 255, blank: true, default: ""
      field :excluded_accounts, :string, max_size: 255, blank: true, default: ""
      field :source, :string, max_size: 12
      field :sign, :string, max_size: 8, default: "all"
      field :operation, :string, max_size: 8, default: "add"

      with_timestamp_fields
    end

    # Paramètres des déclarations (ligne unique) : mandataire des fichiers
    # Intervat (`tva_belge.representative`). Le déclarant est la société du
    # socle (`Core::Settings`).
    class Setting < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :representative_id, :string, max_size: 30, blank: true, default: ""
      field :representative_id_type, :string, max_size: 10, blank: true, default: ""
      field :representative_issued_by, :string, max_size: 2, blank: true, default: ""
      field :representative_name, :string, max_size: 255, blank: true, default: ""
      field :representative_street, :string, max_size: 255, blank: true, default: ""
      field :representative_postcode, :string, max_size: 20, blank: true, default: ""
      field :representative_city, :string, max_size: 100, blank: true, default: ""
      field :representative_country_code, :string, max_size: 2, blank: true, default: ""
      field :representative_email, :string, max_size: 255, blank: true, default: ""
      field :representative_phone, :string, max_size: 50, blank: true, default: ""

      with_timestamp_fields
    end
  end
end
