# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Accounting
    # Compte des écritures du module liberal (ADR-007 D6), par nature
    # (`RENT`), par rubrique de la 2035-A (`rent`) ou par catégorie
    # d'immobilisation (`asset_vehicle`), et `disposal` pour le prix de
    # cession. La Comptabilité ne connaît de ce module que ces clés, reçues
    # dans la charge utile de ses événements (ADR-006 D3).
    class LiberalAccount < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :key, :string, max_size: 40, unique: true
      field :account, :many_to_one, to: Partiduo::Accounting::Account
    end
  end
end
