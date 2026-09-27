# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Accounting
    # Compte d'une fiche du socle (attribut 5 « poste comptable » de
    # `fiche_detail`). `card_id` : identifiant de la fiche. La clé étrangère
    # vers `cards_card`, en cascade, est posée par la migration accounting 0001,
    # côté Comptabilité seulement (D-ACC-001) : effacer la fiche efface ce
    # rattachement ; le socle ne connaît pas cette table (ADR-006 D3).
    class CardAccount < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :card_id, :big_int, unique: true
      field :account, :many_to_one, to: Partiduo::Accounting::Account
    end

    # Compte de base d'une catégorie de fiches (`fiche_def.fd_class_base`) et
    # création automatique d'un compte par fiche (`fd_create_account`).
    # `category_id` : identifiant de la catégorie du socle ; clé étrangère vers
    # `cards_category`, en cascade, posée par la migration accounting 0001,
    # côté Comptabilité seulement (D-ACC-001).
    class CardCategoryAccount < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :category_id, :big_int, unique: true
      field :base_account, :many_to_one, to: Partiduo::Accounting::Account, null: true, blank: true
      field :create_account, :bool, default: false
    end
  end
end
