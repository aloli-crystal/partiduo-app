# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    # Types du contrat du module liberal (ADR-007 D6) ; fonctions dans
    # `liberal.cr`, référence : `doc/api/liberal.adoc`.
    module Liberal
      KINDS   = %w[receipt expense]
      METHODS = %w[transfer card cheque cash direct_debit other]

      # Rubriques de la 2035-A, dans l'ordre du formulaire. Les codes sont
      # fixes ; la ligne et la case de chaque rubrique, elles, sont des
      # données datées par millésime (`form_lines`).
      #
      # Recettes (lignes 1, 5 et 6) ; apports et emprunts, hors 2035.
      RECEIPT_HEADINGS = %w[receipts financial_income other_gains contribution loan_received]
      # Débours et honoraires rétrocédés : déduits des recettes (lignes 2, 3).
      RECEIPT_DEDUCTION_HEADINGS = %w[disbursements fees_retroceded]
      # Dépenses professionnelles (lignes 8 à 32).
      EXPENSE_LINE_HEADINGS = %w[
        purchases salaries staff_social_charges vat_paid cet other_taxes deductible_csg rent equipment_rental
        maintenance temporary_staff small_tools utilities fees insurance vehicle travel personal_social_mandatory
        personal_social_optional reception office legal_costs professional_dues other_management financial_costs
        other_losses
      ]
      # Prélèvements de l'exploitant et remboursement du capital d'un
      # emprunt : sorties de trésorerie hors 2035.
      EXCLUDED_EXPENSE_HEADINGS = %w[withdrawal loan_repayment]
      EXPENSE_HEADINGS          = RECEIPT_DEDUCTION_HEADINGS + EXPENSE_LINE_HEADINGS + EXCLUDED_EXPENSE_HEADINGS
      EXCLUDED_HEADINGS         = %w[contribution loan_received] + EXCLUDED_EXPENSE_HEADINGS
      HEADINGS                  = RECEIPT_HEADINGS + EXPENSE_HEADINGS

      # Catégories d'immobilisation (registre, 2035-B, comptes par défaut).
      ASSET_CATEGORIES = %w[intangible goodwill land building fittings equipment vehicle office furniture other]

      # Réintégrations et déductions diverses de l'année (2035-A, hors
      # livre-journal) : divers à réintégrer, divers à déduire, quote-part
      # de bénéfice ou de déficit de SCM ou SCP, frais d'établissement,
      # provisions.
      ADJUSTMENT_KINDS = %w[reintegration deduction scm_profit scm_loss establishment_costs provision]

      FORMS = %w[2035 2035-A 2035-B]

      # Sous-totaux de la 2035-A : poste calculé → rubriques qui le composent
      # (cases BH, BJ, BK et BM du formulaire).
      SUBTOTALS = {
        "works_total"           => %w[maintenance temporary_staff small_tools utilities fees insurance],
        "transport_total"       => %w[vehicle travel],
        "personal_social_total" => %w[personal_social_mandatory personal_social_optional],
        "management_total"      => %w[office legal_costs professional_dues other_management],
      }

      # Postes calculés de la 2035-A et de la 2035-B (totaux, résultat,
      # amortissements, plus-values), en plus des rubriques. Les sous-totaux
      # de la 2035-A (`SUBTOTALS`) ont leur propre case (DECISIONS D-VAL-007).
      COMPUTED_ITEMS = %w[
        net_receipts total_receipts works_total transport_total personal_social_total management_total total_expenses excess short_term_gains reintegrations scm_profit total_additions
        shortfall establishment_costs depreciation provision short_term_losses deductions scm_loss total_subtractions
        profit loss long_term_gains long_term_losses assets_cost assets_prior_depreciation assets_year_depreciation
        disposals_price
      ]

      # Postes admis dans la table de correspondance.
      ITEMS = (HEADINGS - EXCLUDED_HEADINGS) + COMPUTED_ITEMS

      enum ExportFormat
        Csv
        Pdf
      end

      record FileView, filename : String, content_type : String, content : Bytes

      # --- Paramètres ------------------------------------------------------------

      # Interface du dossier (D-LIB3-001), pour tous ses utilisateurs :
      # `simple` (recettes et dépenses, par défaut) ou `accounting`
      # (comptabilité, seulement si le module Comptabilité est actif).
      INTERFACE_SIMPLE     = "simple"
      INTERFACE_ACCOUNTING = "accounting"
      INTERFACES           = [INTERFACE_SIMPLE, INTERFACE_ACCOUNTING]

      # `profession` : profession exercée (identification de la 2035) ;
      # `default_nature_id` : nature d'une recette issue de la Facturation ;
      # `interface` : interface du dossier (`INTERFACES`), `nil` pour garder
      # celle qui est enregistrée.
      record SettingsInput,
        profession : String = "",
        activity_started_on : Time? = nil,
        default_nature_id : Int64? = nil,
        interface : String? = nil

      # `interface` : interface en vigueur — `accounting` seulement si elle
      # est choisie et que le module Comptabilité est actif ; sinon
      # `simple`, d'elle-même, sans rien réécrire.
      record SettingsView,
        profession : String,
        activity_started_on : Time?,
        default_nature_id : Int64?,
        interface : String = INTERFACE_SIMPLE do
        def accounting_interface? : Bool
          interface == INTERFACE_ACCOUNTING
        end
      end

      record NatureInput, code : String, label : String, kind : String, heading : String, enabled : Bool = true

      record NatureView, id : Int64, code : String, label : String, kind : String, heading : String, enabled : Bool do
        def heading_key : String
          "liberal.headings.#{heading}"
        end

        # Rubrique hors 2035 (apports, emprunts, prélèvements).
        def excluded? : Bool
          EXCLUDED_HEADINGS.includes?(heading)
        end
      end

      # Ligne de la table de correspondance : le poste `item` se reporte à la
      # ligne `line`, case `box`, du formulaire `form`, à partir du millésime
      # `millesime` (jusqu'au millésime suivant qui le redéfinit).
      record FormLineInput, millesime : Int32, item : String, form : String, line : String = "", box : String = ""

      record FormLineView, id : Int64, millesime : Int32, item : String, form : String, line : String, box : String

      # --- Livre-journal ---------------------------------------------------------

      # Recette encaissée ou dépense payée, toutes taxes comprises : date,
      # nature (donc rubrique), montant, mode de règlement, tiers (fiche du
      # socle ou nom), désignation, pièce, pièce jointe. `nondeductible_amount`
      # (dépense seulement) : part d'usage privé, réintégrée à la 2035-A.
      record LineInput,
        date : Time,
        nature_id : Int64,
        amount : BigDecimal,
        method : String,
        card_id : Int64? = nil,
        party_name : String = "",
        label : String = "",
        reference : String = "",
        attachment_id : Int64? = nil,
        nondeductible_amount : BigDecimal = BigDecimal.new(0)

      # Contre-passation datée d'une ligne ou d'une immobilisation.
      record ReverseInput, id : Int64, date : Time, label : String = ""

      # Ligne du livre-journal. `reversed_by_id` : contre-passation qui
      # l'annule ; `locked` : intangible — son exercice est figé (clôturé,
      # ou 2035 transmise le `transmitted_at`) ou sa période du socle est
      # close (DECISIONS D-LIB2-001) ; `modified_at` : dernière modification.
      record LineView,
        id : Int64,
        number : String,
        kind : String,
        date : Time,
        nature_id : Int64,
        nature_code : String,
        nature_label : String,
        heading : String,
        amount : BigDecimal,
        nondeductible_amount : BigDecimal,
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
        recorded_at : Time,
        transmitted_at : Time? = nil,
        modified_at : Time? = nil do
        def receipt? : Bool
          kind == "receipt"
        end

        # Se modifie : exercice ouvert, saisie directe (pas issue de la
        # Facturation), ni contre-passation ni contre-passée.
        def editable? : Bool
          !locked && origin == "manual" && reversal_of_id.nil? && reversed_by_id.nil?
        end

        # Se supprime : exercice ouvert, saisie directe, pas contre-passée
        # (une contre-passation se supprime).
        def deletable? : Bool
          !locked && origin == "manual" && reversed_by_id.nil?
        end

        # Se contre-passe : ni contre-passation ni déjà contre-passée.
        def reversible? : Bool
          reversal_of_id.nil? && reversed_by_id.nil?
        end

        def reversal? : Bool
          !reversal_of_id.nil?
        end

        # Montant signé de la trésorerie : + recette, - dépense.
        def cash_flow : BigDecimal
          receipt? ? amount : -amount
        end

        def method_key : String
          "liberal.methods.#{method}"
        end

        def heading_key : String
          "liberal.headings.#{heading}"
        end
      end

      # Nombre de lignes au plus d'une page : `limit` au-delà est ramené à ce
      # plafond ; `limit` ou `offset` négatif lève `ArgumentError`.
      MAX_LIMIT = 10_000

      record JournalQuery,
        from : Time? = nil,
        to : Time? = nil,
        kind : String? = nil,
        nature_id : Int64? = nil,
        heading : String? = nil,
        limit : Int32 = 1000,
        offset : Int32 = 0 do
        def bounded_limit : Int32
          raise ArgumentError.new("limit négatif") if limit < 0
          raise ArgumentError.new("offset négatif") if offset < 0
          Math.min(limit, MAX_LIMIT)
        end
      end

      # Totaux du livre-journal sur une requête : nombre de lignes, recettes,
      # dépenses (contre-passations comprises).
      record TotalsView, count : Int32, receipts : BigDecimal, expenses : BigDecimal do
        def balance : BigDecimal
          receipts - expenses
        end
      end

      # Total d'une rubrique sur une année : montant, part non déductible,
      # nombre de lignes.
      record HeadingTotalView, heading : String, kind : String, amount : BigDecimal,
        nondeductible_amount : BigDecimal, count : Int32

      # --- Immobilisations -------------------------------------------------------

      # Immobilisation acquise : désignation, catégorie, date d'acquisition,
      # mise en service (défaut : acquisition), base amortissable (prix payé,
      # toutes taxes comprises sauf TVA récupérable), durée d'amortissement
      # linéaire en années (0 : non amortissable), paiement.
      record AssetInput,
        label : String,
        category : String,
        acquired_on : Time,
        amount : BigDecimal,
        duration_years : Int32,
        method : String,
        service_on : Time? = nil,
        card_id : Int64? = nil,
        party_name : String = "",
        reference : String = "",
        attachment_id : Int64? = nil

      record DisposalInput, asset_id : Int64, date : Time, price : BigDecimal, method : String, reference : String = ""

      # Cession ; `locked` : son exercice est figé ou sa période close (elle
      # ne se supprime plus).
      record DisposalView, id : Int64, asset_id : Int64, date : Time, price : BigDecimal, method : String,
        reference : String, locked : Bool = false

      record AssetView,
        id : Int64,
        number : String,
        label : String,
        category : String,
        acquired_on : Time,
        service_on : Time,
        amount : BigDecimal,
        duration_years : Int32,
        method : String,
        card_id : Int64?,
        party_name : String,
        reference : String,
        attachment_id : Int64?,
        reversal_of_id : Int64?,
        reversed_by_id : Int64?,
        disposal : DisposalView?,
        locked : Bool,
        recorded_at : Time,
        modified_at : Time? = nil do
        # `locked` : intangible — exercice d'acquisition figé ou période
        # close, ou une année figée postérieure en dépend (elle compte dans
        # sa 2035, DECISIONS D-LIB2-004).

        # Se modifie : non intangible, ni contre-passation ni contre-passée,
        # sans cession (la supprimer d'abord).
        def editable? : Bool
          !locked && reversal_of_id.nil? && reversed_by_id.nil? && disposal.nil?
        end

        # Se supprime : non intangible, pas contre-passée, sans cession (une
        # contre-passation se supprime).
        def deletable? : Bool
          !locked && reversed_by_id.nil? && disposal.nil?
        end

        # Taux linéaire en %, `nil` si non amortissable.
        def rate : BigDecimal?
          duration_years > 0 ? (BigDecimal.new(100) / duration_years).round(2, mode: :ties_away) : nil
        end

        # Ni contre-passée ni contre-passation : l'immobilisation compte.
        def live? : Bool
          reversal_of_id.nil? && reversed_by_id.nil?
        end

        def category_key : String
          "liberal.asset_categories.#{category}"
        end
      end

      # Ligne du tableau des immobilisations et amortissements (2035-B) pour
      # une année : amortissements antérieurs, dotation de l'année, cumul et
      # valeur résiduelle à la fin de l'année (ou à la cession).
      record DepreciationRowView,
        asset_id : Int64,
        number : String,
        label : String,
        category : String,
        acquired_on : Time,
        service_on : Time,
        amount : BigDecimal,
        duration_years : Int32,
        rate : BigDecimal?,
        prior : BigDecimal,
        year_amount : BigDecimal,
        disposed_on : Time? do
        def cumulated : BigDecimal
          prior + year_amount
        end

        def net_value : BigDecimal
          amount - cumulated
        end
      end

      # Plus-value (positive) ou moins-value (négative) d'une cession, part
      # à court terme et à long terme.
      record DisposalResultView,
        asset_id : Int64,
        number : String,
        label : String,
        date : Time,
        price : BigDecimal,
        net_value : BigDecimal,
        depreciation : BigDecimal,
        short_term : BigDecimal,
        long_term : BigDecimal do
        def gain : BigDecimal
          price - net_value
        end
      end

      # --- Exercices ---------------------------------------------------------------

      # États d'un exercice (année civile de la 2035) : ouvert, clôturé au
      # socle, 2035 transmise (DECISIONS D-LIB2-001).
      YEAR_STATES = %w[open closed transmitted]

      # Exercice `year` : `state` (le premier des deux événements qui le
      # figent), date de clôture au socle, date de transmission de la 2035
      # et référence du dépôt, empreinte de la 2035 au figement.
      record YearView,
        year : Int32,
        state : String,
        closed_at : Time?,
        transmitted_at : Time?,
        reference : String,
        frozen_fingerprint : String do
        def open? : Bool
          state == "open"
        end

        # Clôturé ou 2035 transmise : lignes intangibles.
        def frozen? : Bool
          !open?
        end

        # Date du figement : clôture ou transmission, selon l'état.
        def frozen_at : Time?
          state == "transmitted" ? transmitted_at : closed_at
        end
      end

      # --- Réintégrations et déductions ------------------------------------------

      record AdjustmentInput, year : Int32, kind : String, label : String, amount : BigDecimal

      record AdjustmentView, id : Int64, year : Int32, kind : String, label : String, amount : BigDecimal,
        locked : Bool do
        def kind_key : String
          "liberal.adjustment_kinds.#{kind}"
        end
      end

      # --- 2035 ------------------------------------------------------------------

      # Poste reporté : formulaire, ligne et case de la table de
      # correspondance du millésime (`mapped` faux si le poste n'y figure
      # pas), montant en euros entiers.
      record TaxLineView, item : String, form : String, line : String, box : String, amount : BigDecimal,
        mapped : Bool do
        def item_key : String
          HEADINGS.includes?(item) ? "liberal.headings.#{item}" : "liberal.items.#{item}"
        end
      end

      # Contrôle de cohérence : `severity` `error` (bloque le dépôt) ou
      # `warning` ; `key` clé i18n à paramètres.
      record ControlView, key : String, params : Hash(String, String), severity : String do
        def error? : Bool
          severity == "error"
        end
      end

      # Identification du déclarant (société du socle, paramètres du module).
      record IdentityView,
        company_name : String,
        siren : String,
        street : String,
        street_number : String,
        postcode : String,
        city : String,
        profession : String,
        activity_started_on : Time?

      # 2035 préparée pour l'année civile `year` : identification, postes des
      # formulaires 2035-A et 2035-B (lignes de la table du millésime),
      # tableau des immobilisations, cessions, réintégrations et déductions,
      # contrôles de cohérence. `fingerprint` : empreinte SHA-256 des
      # montants et de l'identification, pour vérifier au dépôt
      # (`partiduo-teledec`) que la déclaration n'a pas changé depuis sa
      # validation. `exercise` : état de l'exercice — ouvert, la 2035 est
      # recalculée à chaque lecture ; figé, ses montants ne changent plus
      # (DECISIONS D-LIB2-005).
      record TaxReturnView,
        year : Int32,
        identity : IdentityView,
        lines : Array(TaxLineView),
        assets : Array(DepreciationRowView),
        disposals : Array(DisposalResultView),
        adjustments : Array(AdjustmentView),
        controls : Array(ControlView),
        fingerprint : String,
        exercise : YearView do
        # Aucun contrôle bloquant : la 2035 peut être transmise.
        def ready? : Bool
          controls.none?(&.error?)
        end

        def amount(item : String) : BigDecimal
          lines.find(&.item.==(item)).try(&.amount) || BigDecimal.new(0)
        end

        def form(form : String) : Array(TaxLineView)
          lines.select(&.form.==(form))
        end

        # Montants par formulaire et par case (postes non nuls et situés),
        # tels qu'un transmetteur EDI les attend.
        def boxes : Hash(String, Hash(String, BigDecimal))
          result = {} of String => Hash(String, BigDecimal)
          reported = lines.select { |line| line.mapped && line.box.presence && line.amount != 0 }
          reported.each do |line|
            (result[line.form] ||= {} of String => BigDecimal)[line.box] = line.amount
          end
          result
        end
      end
    end
  end
end
