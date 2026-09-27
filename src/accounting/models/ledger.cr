# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Accounting
    # Journal, héritier de `jrn_def` : type (`jrn_def_type` ACH, VEN, FIN,
    # ODS), code (`jrn_def_code`), nom, description, activation
    # (`jrn_enable`), compte par défaut, fiche Banque d'un journal financier
    # (`jrn_def_bank`, un `f_id` : `bank_card_id`, clé étrangère vers
    # `cards_card` posée par la migration accounting 0002), numérotation des pièces (`jrn_def_pj_pref`,
    # `jrn_def_pj_padding` et la séquence `s_jrn_pj<id>`, remplacée par le
    # compteur `last_receipt_number`, verrouillé à l'usage), devise.
    class Ledger < Marten::Model
      KINDS = %w[purchase sale financial misc]

      field :id, :big_int, primary_key: true, auto: true
      field :code, :string, max_size: 10, unique: true
      field :name, :string, max_size: 100, unique: true
      field :kind, :string, max_size: 16
      field :description, :text, blank: true, default: ""
      field :enabled, :bool, default: true
      field :default_account, :many_to_one, to: Partiduo::Accounting::Account, null: true, blank: true
      field :receipt_prefix, :string, max_size: 20, blank: true, default: ""
      field :receipt_padding, :int, default: 0
      field :last_receipt_number, :big_int, default: 0
      field :currency_code, :string, max_size: 3, default: "EUR"
      field :bank_card_id, :big_int, null: true, blank: true
      field :created_at, :date_time, auto_now_add: true
      field :updated_at, :date_time, auto_now: true
    end
  end
end
