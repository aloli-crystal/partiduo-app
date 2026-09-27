# SPDX-License-Identifier: AGPL-3.0-or-later

require "./account"
require "./ledger"

module Partiduo
  module Accounting
    # Lettrage (`jnt_letter`) : lignes d'un même compte rapprochées. Une ligne
    # appartient à un lettrage au plus (`entry_line.matching_id`).
    class Matching < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :account, :many_to_one, to: Partiduo::Accounting::Account, related: :matchings
      field :created_by_id, :big_int, null: true, blank: true

      with_timestamp_fields
    end

    # Écriture (en-tête), héritière de `jrn` : journal (`jr_def_id`), date
    # (`jr_date`), période (`jr_tech_per`, *calculée par la base* à partir de
    # la date, comme `jrn_check_periode`), échéance (`jr_ech`), libellé
    # (`jr_comment`), pièce (`jr_pj_number`), code interne (`jr_internal`),
    # montant (`jr_montant` = total du débit), devise et cours (`currency_id`,
    # `currency_rate`), extourne (`jr_optype = 'EXT'` et `jrn_rapt`).
    #
    # Modèle interne : on n'écrit une écriture que par
    # `Partiduo::Api::Accounting.post_entry` et ses variantes ; l'équilibre et
    # la période ouverte sont en outre vérifiés par PostgreSQL (migration
    # accounting 0003).
    class Entry < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :ledger, :many_to_one, to: Partiduo::Accounting::Ledger, related: :entries
      # Période du socle (`core_period`) ; clé étrangère posée par la migration.
      field :period_id, :big_int
      field :date, :date
      field :due_date, :date, null: true, blank: true
      field :label, :text, blank: true, default: ""
      field :receipt, :string, max_size: 40, null: true, blank: true
      field :internal_code, :string, max_size: 20, null: true, blank: true, unique: true
      field :amount, :decimal, max_digits: 20, decimal_places: 4
      field :currency_code, :string, max_size: 3
      field :currency_rate, :decimal, max_digits: 20, decimal_places: 8
      field :reversal_of, :many_to_one, to: Partiduo::Accounting::Entry, null: true, blank: true, related: :reversals
      # Pièce jointe du socle (`core_attachment`) ; clé étrangère posée par la migration.
      field :attachment_id, :big_int, null: true, blank: true
      field :source, :string, max_size: 100, blank: true, default: ""
      # Écriture extournée : posé par la base à l'insertion de l'extourne,
      # jamais retiré (migration accounting 0004).
      field :reversed, :bool, default: false
      field :created_by_id, :big_int, null: true, blank: true

      with_timestamp_fields
    end

    # Événement du journal du socle écarté de l'historique à comptabiliser
    # (`Api::Accounting.dismiss_invoicing_event`, D-2F-010).
    class BillingDismissal < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      # Entrée de `modules_event_log` ; clé étrangère posée par la migration.
      field :event_id, :big_int, unique: true
      field :reason, :text, blank: true, default: ""
      field :created_by_id, :big_int, null: true, blank: true
      field :created_at, :date_time, auto_now_add: true
    end

    # Ligne d'écriture, héritière de `jrnx` : compte (`j_poste`), sens
    # (`j_debit`, ici `debit` / `credit`), montant en devise de tenue
    # (`j_montant numeric(20,4)`), fiche (`f_id`, `j_qcode`), libellé
    # (`j_text`), montant en devise (`operation_currency.oc_amount`), taux de
    # TVA et rôle de la ligne (`quant_purchase` / `quant_sold` : base ou TVA),
    # quantité, lettrage (`letter_deb` / `letter_cred`).
    class EntryLine < Marten::Model
      SIDES     = %w[debit credit]
      VAT_ROLES = %w[base tax]

      field :id, :big_int, primary_key: true, auto: true
      field :entry, :many_to_one, to: Partiduo::Accounting::Entry, related: :lines
      field :position, :int, default: 0
      field :account, :many_to_one, to: Partiduo::Accounting::Account, related: :entry_lines
      # Fiche du socle (`cards_card`) ; clé étrangère posée par la migration.
      field :card_id, :big_int, null: true, blank: true
      field :side, :string, max_size: 6
      field :amount, :decimal, max_digits: 20, decimal_places: 4
      field :currency_amount, :decimal, max_digits: 20, decimal_places: 4, null: true, blank: true
      field :label, :text, blank: true, default: ""
      # Taux de TVA du socle (`vat_rate`) ; clé étrangère posée par la migration.
      field :vat_rate_id, :big_int, null: true, blank: true
      field :vat_role, :string, max_size: 8, null: true, blank: true
      field :quantity, :decimal, max_digits: 20, decimal_places: 4, null: true, blank: true
      field :matching, :many_to_one, to: Partiduo::Accounting::Matching, null: true, blank: true, related: :lines

      def debit? : Bool
        side == "debit"
      end
    end
  end
end
