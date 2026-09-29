# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Stock
    # Dépôt (`stock_repository`) : nom unique, adresse, ville, pays,
    # téléphone. Modèle interne : l'interface passe par
    # `Partiduo::Api::Stock`.
    class Repository < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :name, :string, max_size: 100, unique: true
      field :address, :text, blank: true, default: ""
      field :city, :string, max_size: 100, blank: true, default: ""
      field :country_code, :string, max_size: 2, blank: true, default: ""
      field :phone, :string, max_size: 40, blank: true, default: ""

      with_timestamp_fields
    end

    # Droit d'un profil sur un dépôt (`profile_sec_repository`) : `R`
    # lecture, `W` écriture. Profil et dépôt cités par identifiant (clés
    # étrangères en cascade posées par la migration `0002`).
    class RepositoryAccess < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :profile_id, :big_int
      field :repository_id, :big_int
      field :access, :string, max_size: 1

      with_timestamp_fields
    end

    # Paramètres du module (ligne unique, colonne `singleton`, D-ANA-017) :
    # dépôt des mouvements issus de la Facturation et de la Comptabilité.
    class Setting < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :singleton, :bool, default: true
      field :default_repository, :many_to_one, to: Partiduo::Stock::Repository, null: true, blank: true,
        on_delete: :set_null

      with_timestamp_fields
    end

    # Article suivi en stock : fiche de nature `item` (socle) et son code
    # stock (`ATTR_DEF_STOCK`), commun à plusieurs fiches au besoin. La fiche
    # est citée par identifiant (clé étrangère posée par la migration).
    class Item < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :card_id, :big_int, unique: true
      field :stock_code, :string, max_size: 40

      with_timestamp_fields
    end

    # Opération manuelle (`stock_change`) : mouvements saisis ou inventaire.
    # Supprimer l'opération supprime ses mouvements.
    class Change < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :kind, :string, max_size: 12, default: "change"
      field :repository, :many_to_one, to: Partiduo::Stock::Repository, related: :changes, on_delete: :protect
      field :date, :date
      field :comment, :text, blank: true, default: ""
      field :created_by_id, :big_int, null: true, blank: true

      with_timestamp_fields
    end

    # Mouvement de stock (`stock_goods`) : dépôt, fiche et code stock figé,
    # sens, quantité strictement positive, date, coût unitaire d'une entrée
    # (valorisation, D-STK-005), référence de l'origine (`source` :
    # `invoice:<id>`, `credit_note:<id>`, `delivery_note:<id>`,
    # `entry:<id>`, vide pour une opération manuelle, qui porte `change`).
    class Movement < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :repository, :many_to_one, to: Partiduo::Stock::Repository, related: :movements, on_delete: :protect
      field :change, :many_to_one, to: Partiduo::Stock::Change, related: :movements, null: true, blank: true,
        on_delete: :cascade
      field :card_id, :big_int
      field :stock_code, :string, max_size: 40
      field :direction, :string, max_size: 3
      field :quantity, :decimal, max_digits: 20, decimal_places: 4
      field :unit_cost, :decimal, max_digits: 20, decimal_places: 4, null: true, blank: true
      field :date, :date
      field :comment, :text, blank: true, default: ""
      field :source, :string, max_size: 40, blank: true, default: ""
      field :created_by_id, :big_int, null: true, blank: true

      with_timestamp_fields
    end
  end
end
