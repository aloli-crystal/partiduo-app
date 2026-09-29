# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    # Types du contrat du module Stock (lot 6). Quantités et coûts en
    # `BigDecimal` (quatre décimales au plus, refusées au-delà, convention
    # C1) ; coûts et valeurs en devise de tenue. Référence :
    # `doc/api/stock.adoc`.
    module Stock
      # Sens d'un mouvement : `in` (entrée, `sg_type = 'd'` d'origine) ou
      # `out` (sortie, `sg_type = 'c'`).
      DIRECTIONS = %w[in out]
      # Nature d'une opération manuelle : `change` (mouvements saisis,
      # `stock_change`) ou `inventory` (inventaire compté, écarts calculés).
      CHANGE_KINDS = %w[change inventory]

      # --- Dépôts ----------------------------------------------------------------

      # Dépôt (`stock_repository`) : nom unique (100 caractères au plus),
      # adresse, ville, pays (code ISO à deux lettres ou vide), téléphone.
      record RepositoryInput,
        name : String,
        address : String = "",
        city : String = "",
        country_code : String = "",
        phone : String = ""

      record RepositoryView,
        id : Int64,
        name : String,
        address : String,
        city : String,
        country_code : String,
        phone : String,
        default : Bool,
        movements_count : Int64

      # --- Paramètres ------------------------------------------------------------

      # Dépôt où la Facturation et la Comptabilité inscrivent leurs mouvements
      # (le dépôt choisi dans la saisie d'origine). `nil` : aucun mouvement
      # automatique.
      record SettingsInput, default_repository_id : Int64?

      record SettingsView, default_repository_id : Int64?, default_repository_name : String?

      # --- Droits par dépôt (D-R5-015) ---------------------------------------------

      # Droit d'un profil sur un dépôt : `R` lecture, `W` écriture, vide :
      # aucun. Un profil sans aucun droit enregistré n'est pas restreint.
      record RepositoryRightInput, repository_id : Int64, access : String

      record RepositoryRightView, repository_id : Int64, repository_name : String, access : String

      # Droits d'un profil : `restricted` faux, ses utilisateurs voient tous
      # les dépôts (droits globaux du Stock).
      record ProfileRightsView, profile_id : Int64, restricted : Bool, rights : Array(RepositoryRightView)

      # Profil d'utilisateurs, pour le choix du profil dont on règle les droits.
      record ProfileRef, id : Int64, name : String, restricted : Bool

      # --- Articles suivis -------------------------------------------------------

      # Article suivi en stock (attribut « code stock » d'une fiche,
      # `ATTR_DEF_STOCK`) : fiche de nature `item` ; `stock_code` : code
      # commun à plusieurs fiches (40 caractères au plus, mis en majuscules),
      # quick code de la fiche si vide.
      record ItemInput, card_id : Int64, stock_code : String = ""

      record ItemView, card_id : Int64, card_code : String, card_name : String, stock_code : String

      # --- Opérations manuelles et inventaires -------------------------------------

      # Ligne d'une opération manuelle (`Stock_Goods::record_save`) :
      # quantité *signée* (positive = entrée, négative = sortie, non nulle) ;
      # `unit_cost` : coût unitaire d'une entrée (valorisation), facultatif.
      record ChangeLineInput, card_id : Int64, quantity : BigDecimal, unit_cost : BigDecimal? = nil

      # Opération manuelle : dépôt, date, motif, lignes.
      record ChangeInput,
        repository_id : Int64,
        date : Time,
        lines : Array(ChangeLineInput),
        comment : String = ""

      # Ligne d'inventaire : quantité *comptée* de l'article dans le dépôt
      # (positive ou nulle) ; l'écart avec la quantité théorique devient un
      # mouvement.
      record InventoryLineInput, card_id : Int64, counted : BigDecimal, unit_cost : BigDecimal? = nil

      record InventoryInput,
        repository_id : Int64,
        date : Time,
        lines : Array(InventoryLineInput),
        comment : String = ""

      # Quantité théorique proposée pour un inventaire (`take_last_inventory`).
      record InventoryLineView, card_id : Int64, card_code : String, card_name : String, stock_code : String,
        quantity : BigDecimal

      record MovementView,
        id : Int64,
        repository_id : Int64,
        repository_name : String,
        card_id : Int64,
        card_code : String,
        card_name : String,
        stock_code : String,
        direction : String,
        quantity : BigDecimal,
        unit_cost : BigDecimal?,
        date : Time,
        comment : String,
        source : String,
        change_id : Int64?,
        created_by_id : Int64?,
        created_at : Time do
        def in? : Bool
          direction == "in"
        end

        def out? : Bool
          direction == "out"
        end

        # Quantité signée : positive pour une entrée.
        def signed_quantity : BigDecimal
          in? ? quantity : -quantity
        end

        def direction_key : String
          "stock.directions.#{direction}"
        end
      end

      record ChangeView,
        id : Int64,
        kind : String,
        repository_id : Int64,
        repository_name : String,
        date : Time,
        comment : String,
        created_by_id : Int64?,
        created_at : Time,
        movements : Array(MovementView) do
        def kind_key : String
          "stock.change_kinds.#{kind}"
        end
      end

      record ChangeQuery,
        repository_id : Int64? = nil,
        date_from : Time? = nil,
        date_to : Time? = nil,
        kind : String? = nil

      # --- Historique ------------------------------------------------------------

      # Critères de l'historique (`Stock::create_query_histo`) ; `source` :
      # préfixe de la référence (`invoice:`, `entry:`…).
      record MovementQuery,
        repository_id : Int64? = nil,
        card_id : Int64? = nil,
        stock_code : String? = nil,
        direction : String? = nil,
        date_from : Time? = nil,
        date_to : Time? = nil,
        source : String? = nil,
        limit : Int32 = 100,
        offset : Int32 = 0

      # --- État des stocks et valorisation ----------------------------------------

      # État (`Stock::summary`) entre deux dates : pour chaque dépôt et chaque
      # code stock, quantité à l'ouverture (avant `date_from`), entrées,
      # sorties, quantité à la clôture.
      record StateQuery, date_from : Time, date_to : Time, repository_id : Int64? = nil

      record StateRowView,
        repository_id : Int64,
        repository_name : String,
        stock_code : String,
        card_names : Array(String),
        opening : BigDecimal,
        quantity_in : BigDecimal,
        quantity_out : BigDecimal do
        def closing : BigDecimal
          opening + quantity_in - quantity_out
        end
      end

      record StateView, date_from : Time, date_to : Time, rows : Array(StateRowView)

      # Valorisation au coût moyen pondéré (D-STK-005) : quantité en stock à
      # la date, coût unitaire moyen des entrées valorisées du code stock
      # jusqu'à cette date (`nil` s'il n'y en a aucune), valeur arrondie au
      # centime.
      record ValuationRowView,
        repository_id : Int64,
        repository_name : String,
        stock_code : String,
        card_names : Array(String),
        quantity : BigDecimal,
        unit_cost : BigDecimal?,
        value : BigDecimal?

      record ValuationView, date : Time, rows : Array(ValuationRowView) do
        def total : BigDecimal
          rows.sum(BigDecimal.new(0)) { |row| row.value || BigDecimal.new(0) }
        end
      end

      record FileView, filename : String, content_type : String, content : Bytes
    end
  end
end
