# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    # Types du contrat du module micro-entreprise (ADR-007 D1) ; fonctions
    # dans `micro.cr`, référence : `doc/api/micro.adoc`.
    module Micro
      # Catégories de recettes de la déclaration URSSAF et de la 2042-C-PRO.
      RECEIPT_CATEGORIES = %w[sale_bic service_bic bnc]
      # Catégories d'achats : marchandises revendues, autres.
      PURCHASE_CATEGORIES = %w[goods other]
      KINDS               = %w[receipt purchase]
      METHODS             = %w[transfer card cheque cash direct_debit other]
      PERIODICITIES       = %w[monthly quarterly]

      # Codes de paramètres datés admis (valeurs : `src/micro/data/parameters.yml`).
      PARAMETER_CODES = (
        RECEIPT_CATEGORIES.flat_map { |category| %w[social cfp flat_tax].map { |rate| "rate.#{rate}.#{category}" } } +
        %w[vat vat_tolerance micro].flat_map { |kind| %w[goods services].map { |scope| "threshold.#{kind}.#{scope}" } } +
        ["alert.ratio"] +
        RECEIPT_CATEGORIES.flat_map { |category| ["box.#{category}", "box.flat_tax.#{category}"] }
      )

      enum ExportFormat
        Csv
        Pdf
      end

      record FileView, filename : String, content_type : String, content : Bytes

      # --- Paramètres ------------------------------------------------------------

      # `activity_started_on` : début d'activité (première échéance URSSAF,
      # prorata du seuil du régime micro la première année) ;
      # `default_nature_id` : nature d'une recette issue de la Facturation
      # quand l'article n'en a pas.
      record SettingsInput,
        periodicity : String = "quarterly",
        flat_tax : Bool = false,
        activity_started_on : Time? = nil,
        default_nature_id : Int64? = nil

      record SettingsView,
        periodicity : String,
        flat_tax : Bool,
        activity_started_on : Time?,
        default_nature_id : Int64?,
        vat_liable_since : Time?,
        real_regime_since : Time?

      record NatureInput, code : String, label : String, kind : String, category : String, enabled : Bool = true

      record NatureView, id : Int64, code : String, label : String, kind : String, category : String, enabled : Bool do
        def category_key : String
          "micro.categories.#{category}"
        end
      end

      # Paramètre daté : `value` numérique (taux en %, seuil en euros) ou
      # `text` (case de formulaire).
      record ParameterInput, code : String, valid_from : Time, value : BigDecimal? = nil, text : String = ""

      record ParameterView, id : Int64, code : String, valid_from : Time, value : BigDecimal?, text : String

      record ItemNatureView, item_card_id : Int64, nature_id : Int64

      # --- Registres -------------------------------------------------------------

      # Recette encaissée (livre des recettes) : date d'encaissement, nature,
      # montant encaissé (TVA comprise, `vat_amount` s'il y en a), mode de
      # règlement, client (fiche du socle ou nom), désignation, référence de
      # la pièce justificative, pièce jointe du socle.
      record ReceiptInput,
        date : Time,
        nature_id : Int64,
        amount : BigDecimal,
        method : String,
        card_id : Int64? = nil,
        party_name : String = "",
        label : String = "",
        reference : String = "",
        attachment_id : Int64? = nil,
        vat_amount : BigDecimal = BigDecimal.new(0)

      # Achat payé (registre des achats) : mêmes champs, fournisseur ;
      # `vat_amount` : TVA déductible comprise (après la bascule vers la TVA).
      record PurchaseInput,
        date : Time,
        nature_id : Int64,
        amount : BigDecimal,
        method : String,
        card_id : Int64? = nil,
        party_name : String = "",
        label : String = "",
        reference : String = "",
        attachment_id : Int64? = nil,
        vat_amount : BigDecimal = BigDecimal.new(0)

      # Contre-passation datée d'une ligne (jamais de modification).
      record ReverseInput, id : Int64, date : Time, label : String = ""

      # Ligne d'un registre. `reversed_by_id` : contre-passation qui l'annule ;
      # `locked` : sa période est close.
      record LineView,
        id : Int64,
        register : String,
        number : String,
        date : Time,
        nature_id : Int64,
        nature_code : String,
        nature_label : String,
        category : String,
        amount : BigDecimal,
        vat_amount : BigDecimal,
        method : String,
        card_id : Int64?,
        party_name : String,
        label : String,
        reference : String,
        attachment_id : Int64?,
        origin : String,
        source : String,
        reversal_of_id : Int64?,
        reversed_by_id : Int64?,
        locked : Bool,
        recorded_at : Time do
        # Chiffre d'affaires de la ligne : encaissé hors TVA.
        def net_amount : BigDecimal
          amount - vat_amount
        end

        def reversal? : Bool
          !reversal_of_id.nil?
        end

        def method_key : String
          "micro.methods.#{method}"
        end
      end

      # Nombre de lignes au plus d'une page de registre : `limit` au-delà
      # est ramené à ce plafond ; `limit` ou `offset` négatif est refusé
      # (`ArgumentError`). Les totaux se lisent par `receipt_totals` et
      # `purchase_totals`, sans charger les lignes.
      MAX_LIMIT = 10_000

      record RegisterQuery,
        from : Time? = nil,
        to : Time? = nil,
        nature_id : Int64? = nil,
        category : String? = nil,
        limit : Int32 = 1000,
        offset : Int32 = 0 do
        # Page bornée : `limit` plafonné à `MAX_LIMIT`.
        def bounded_limit : Int32
          raise ArgumentError.new("limit négatif") if limit < 0
          raise ArgumentError.new("offset négatif") if offset < 0
          Math.min(limit, MAX_LIMIT)
        end
      end

      # Total d'un registre par nature (récapitulatif annuel) : montant payé
      # ou encaissé, TVA comprise, nombre de lignes (contre-passations
      # comprises).
      record NatureTotalView, nature_id : Int64, nature_code : String, nature_label : String, category : String,
        amount : BigDecimal, vat_amount : BigDecimal = BigDecimal.new(0), count : Int32 = 0 do
        # Hors TVA : chiffre d'affaires (recettes) ou dépensé hors taxe (achats).
        def net_amount : BigDecimal
          amount - vat_amount
        end
      end

      # Totaux d'un registre sur une requête (sans pagination) : nombre de
      # lignes, montant, TVA comprise.
      record TotalsView, count : Int32, amount : BigDecimal, vat_amount : BigDecimal do
        def net_amount : BigDecimal
          amount - vat_amount
        end
      end

      # --- URSSAF ----------------------------------------------------------------

      # Cotisation estimée d'une catégorie : chiffre d'affaires, taux
      # (en %, `nil` s'il manque un paramètre) et montants arrondis au centime.
      record ContributionView,
        category : String,
        turnover : BigDecimal,
        social_rate : BigDecimal?,
        social : BigDecimal,
        cfp_rate : BigDecimal?,
        cfp : BigDecimal,
        flat_tax_rate : BigDecimal?,
        flat_tax : BigDecimal do
        def total : BigDecimal
          social + cfp + flat_tax
        end
      end

      # Période de déclaration : bornes, échéance (dernier jour du mois qui
      # suit), chiffre d'affaires par catégorie, cotisations estimées. `status` :
      # `open` (période en cours), `due` (à déclarer avant l'échéance), `late`,
      # `declared`. `missing_rates` : paramètres absents à la date.
      record DeclarationView,
        starts_on : Time,
        ends_on : Time,
        due_on : Time,
        contributions : Array(ContributionView),
        status : String,
        declared_on : Time?,
        reference : String,
        missing_rates : Array(String) do
        def turnover : BigDecimal
          contributions.sum(BigDecimal.new(0), &.turnover)
        end

        def total : BigDecimal
          contributions.sum(BigDecimal.new(0), &.total)
        end

        def turnover_of(category : String) : BigDecimal
          contributions.find(&.category.==(category)).try(&.turnover) || BigDecimal.new(0)
        end
      end

      record DeclarationInput, starts_on : Time, declared_on : Time, reference : String = ""

      # Élément de « À traiter » : `kind` `declaration` ou `threshold` ; `key`
      # clé i18n à paramètres ; `tone` `primary` ou `gap`.
      record TodoView, kind : String, key : String, params : Hash(String, String), due_on : Time?, tone : String

      # --- 2042-C-PRO --------------------------------------------------------------

      record TaxBoxView, category : String, box : String, amount : BigDecimal

      # Montants annuels à reporter, en euros entiers, par catégorie.
      record TaxReturnView, year : Int32, flat_tax : Bool, boxes : Array(TaxBoxView)

      # --- Seuils ----------------------------------------------------------------

      # Seuil suivi : `kind` `vat` (franchise en base) ou `micro` ; `scope`
      # `goods` (comparé au chiffre d'affaires total) ou `services` (comparé
      # aux prestations). `status` : `ok`, `approaching`, `exceeded`,
      # `tolerance_exceeded` (TVA : seuil majoré franchi), `not_applicable`
      # (bascule faite) ou `unknown` (seuil non paramétré).
      record ThresholdView,
        kind : String,
        scope : String,
        turnover : BigDecimal,
        limit : BigDecimal?,
        tolerance : BigDecimal?,
        ratio : BigDecimal?,
        status : String

      record AlertView, key : String, params : Hash(String, String)

      record ThresholdsView,
        year : Int32,
        goods_turnover : BigDecimal,
        services_turnover : BigDecimal,
        thresholds : Array(ThresholdView),
        alerts : Array(AlertView) do
        def total_turnover : BigDecimal
          goods_turnover + services_turnover
        end
      end

      # --- Bascules ----------------------------------------------------------------

      record SwitchItemView, card_id : Int64, code : String, name : String, rate_code : String

      # Bascule vers la TVA proposée : articles en franchise (293 B) et taux
      # proposé (le taux normal le plus élevé actif).
      record VatSwitchPlanView, items : Array(SwitchItemView), suggested_rate_id : Int64?

      record VatSwitchInput, effective_on : Time, rate_id : Int64
    end
  end
end
