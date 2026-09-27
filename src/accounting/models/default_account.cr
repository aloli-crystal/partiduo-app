# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Accounting
    # Compte par défaut d'un usage (clients, fournisseurs, banque…), héritier
    # de `parm_code`.
    class DefaultAccount < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :code, :string, max_size: 32, unique: true
      field :account, :many_to_one, to: Partiduo::Accounting::Account
    end
  end
end
