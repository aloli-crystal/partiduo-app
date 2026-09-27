# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Accounting
    # Comptes de TVA d'un taux du socle, héritiers de `tva_rate.tva_poste`
    # (« compte déductible,compte collecté ») : la Comptabilité y ventile la
    # TVA des achats et des ventes (D-ACC-009). `vat_rate_id` : identifiant du
    # taux ; clé étrangère vers `vat_rate`, en cascade, posée par la migration
    # accounting 0002, côté Comptabilité seulement.
    class VatRateAccount < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :vat_rate_id, :big_int, unique: true
      field :deductible_account, :many_to_one, to: Partiduo::Accounting::Account, null: true, blank: true,
        related: :deductible_vat_rates
      field :collected_account, :many_to_one, to: Partiduo::Accounting::Account, null: true, blank: true,
        related: :collected_vat_rates
    end
  end
end
