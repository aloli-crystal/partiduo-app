# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Cards
    # Fiche, héritière de `fiche` + `fiche_detail` (EAV) : tiers (client,
    # fournisseur, banque, salarié, contact) ou article et service.
    #
    # Colonnes typées pour les attributs universels (ADR-001 D3) et pour les
    # champs de facturation française qui appartiennent au cœur (ADR-004 D5 :
    # SIREN, SIRET, identifiant de routage de l'annuaire) ; `extra` (jsonb,
    # index GIN) pour les attributs propres à la catégorie, validés selon sa
    # définition. Le rattachement à un compte comptable (`account_id` de
    # l'ADR-001 D3) relève de la Comptabilité (ADR-006 D3).
    #
    # Champs d'article (`unit_code`, prix, taux de TVA par défaut) : fiches
    # de catégorie `item` seulement.
    class Card < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :category, :many_to_one, to: Partiduo::Cards::Category, related: :cards
      # Quick code (`j_qcode`, attribut 23) : unique, en majuscules.
      field :code, :string, max_size: 64, unique: true
      field :name, :string, max_size: 255
      field :description, :text, blank: true, default: ""
      field :enabled, :bool, default: true

      # Tiers
      field :vat_number, :string, max_size: 32, blank: true, default: ""
      field :siren, :string, max_size: 9, blank: true, default: ""
      field :siret, :string, max_size: 14, blank: true, default: ""
      field :routing_id, :string, max_size: 100, blank: true, default: ""
      field :iban, :string, max_size: 34, blank: true, default: ""
      field :bic, :string, max_size: 11, blank: true, default: ""
      field :email, :string, max_size: 254, blank: true, default: ""
      field :phone, :string, max_size: 32, blank: true, default: ""
      field :contact_name, :string, max_size: 128, blank: true, default: ""
      # Nature d'un client (ADR-004 D9) : `individual`, `business`, `public` ;
      # vide : pas encore précisée (migration cards `0002`).
      field :customer_nature, :string, max_size: 16, blank: true, default: ""
      # Copie PDF d'une facture transmise par la plateforme agréée (ADR-004
      # D9) : `false` la refuse pour ce client.
      field :pdf_copy, :bool, default: true

      # Articles et services
      field :unit_code, :string, max_size: 3, blank: true, default: ""
      field :sale_price, :decimal, max_digits: 20, decimal_places: 4, null: true, blank: true
      field :purchase_price, :decimal, max_digits: 20, decimal_places: 4, null: true, blank: true
      field :vat_rate, :many_to_one, to: Partiduo::Vat::Rate, null: true, blank: true, related: :cards

      field :extra, :json

      with_timestamp_fields
    end

    # Adresse d'une fiche : principale (`main`, une au plus) ou de livraison
    # (`delivery`, plusieurs ; la première par `position` est l'adresse par
    # défaut — ADR-004 D5).
    class Address < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :card, :many_to_one, to: Partiduo::Cards::Card, related: :addresses, on_delete: :cascade
      field :kind, :string, max_size: 16
      field :position, :int, default: 0
      field :label, :string, max_size: 100, blank: true, default: ""
      field :line1, :string, max_size: 255, blank: true, default: ""
      field :line2, :string, max_size: 255, blank: true, default: ""
      field :postcode, :string, max_size: 16, blank: true, default: ""
      field :city, :string, max_size: 128, blank: true, default: ""
      field :country_code, :string, max_size: 2
    end
  end
end
