# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Accounting
    # Compte du plan comptable, héritier de `tmp_pcmn` : numéro alphanumérique
    # normalisé (`pcm_val`), libellé (`pcm_lib`), parent (`pcm_val_parent`,
    # désormais une vraie relation), type (`pcm_type`) et utilisation directe
    # (`pcm_direct_use`). Modèle interne : l'interface passe par
    # `Partiduo::Api::Accounting`.
    class Account < Marten::Model
      KINDS = %w[asset liability asset_contra liability_contra income income_contra expense expense_contra context]

      field :id, :big_int, primary_key: true, auto: true
      field :number, :string, max_size: 40, unique: true
      field :label, :string, max_size: 255
      field :parent, :many_to_one, to: Partiduo::Accounting::Account, null: true, blank: true, related: :children
      field :kind, :string, max_size: 20
      field :direct_use, :bool, default: true
      field :created_at, :date_time, auto_now_add: true
      field :updated_at, :date_time, auto_now: true
    end
  end
end
