# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Accounting
    # Compte de contrepartie des écritures de la micro-entreprise (ADR-007
    # D2), par nature (`SALE`) ou par catégorie (`sale_bic`, `goods`, `vat`…).
    # La Comptabilité ne connaît de ce module que ces clés, reçues dans la
    # charge utile de ses événements (ADR-006 D3).
    class MicroAccount < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :key, :string, max_size: 26, unique: true
      field :account, :many_to_one, to: Partiduo::Accounting::Account
    end
  end
end
