# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Cards
    # Catégorie de fiche, héritière de `fiche_def` (et de son modèle
    # `fiche_def_ref`, réduit à `kind`) : clients, fournisseurs, articles,
    # banques… Elle définit les attributs propres de ses fiches
    # (`CategoryAttribute`, successeur de `jnt_fic_attr` + `attr_def`), stockés
    # dans `Card#extra` (ADR-001 D3).
    #
    # `code` : identifiant stable (`CUSTOMER`, `SUPPLIER`…), par lequel les
    # modules rattachent leurs paramètres à une catégorie — la Comptabilité y
    # rattache le compte de base (`fd_class_base`) et la création automatique
    # de compte (`fd_create_account`) : le socle ne cite pas les comptes.
    class Category < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :code, :string, max_size: 32, unique: true
      field :name, :string, max_size: 100
      field :kind, :string, max_size: 16
      field :description, :text, blank: true, default: ""

      with_timestamp_fields
    end

    # Attribut propre d'une catégorie (`attr_def` rattaché par
    # `jnt_fic_attr`) : clé dans `Card#extra`, libellé, type, obligation,
    # ordre d'affichage (`jnt_order`).
    #
    # Types : `text` (longueur maximale `max_length`), `number` (décimal exact
    # à `decimals` décimales, stocké en chaîne), `date` (`AAAA-MM-JJ`),
    # `boolean`, `card` (identifiant d'une autre fiche, successeur du type
    # `card` d'origine qui stockait un quick code).
    class CategoryAttribute < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :category, :many_to_one, to: Partiduo::Cards::Category, related: :attributes, on_delete: :cascade
      field :key, :string, max_size: 40
      field :label, :string, max_size: 100
      field :value_type, :string, max_size: 16
      field :required, :bool, default: false
      field :max_length, :int, null: true, blank: true
      field :decimals, :int, null: true, blank: true
      field :position, :int, default: 0

      with_timestamp_fields

      db_unique_constraint :cards_category_attribute_unique, field_names: [:category, :key]
    end
  end
end
