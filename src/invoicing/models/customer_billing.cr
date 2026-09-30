# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Invoicing
    # Réglage client de la Facturation (migration `0006`) : rythme de
    # facturation des bons de livraison (`per_delivery`, défaut ; `monthly` :
    # facture récapitulative de fin de mois, art. 289-I-3 du CGI) et encours
    # maximum (vide : pas de plafond). Accessoire de la fiche du socle, qui
    # n'en sait rien : il disparaît avec elle. Une fiche sans ligne a les
    # valeurs par défaut.
    class CustomerBilling < Marten::Model
      db_table :invoicing_customer

      field :id, :big_int, primary_key: true, auto: true
      field :card_id, :big_int, unique: true
      field :billing_rhythm, :string, max_size: 16, default: "per_delivery"
      field :credit_limit, :decimal, max_digits: 20, decimal_places: 4, null: true, blank: true

      with_timestamp_fields
    end

    # Facture de fin de mois préparée pour un client, un mois (premier jour)
    # et une devise : jamais deux (contrainte d'unicité). `invoice_id` reste
    # après la suppression du brouillon : le mois n'est pas repris pour ce
    # client. `status` : `proposed` (brouillon à valider), `issued`, `sent`,
    # `failed` (émission ou envoi automatique refusé, motif dans `error`).
    class MonthlyInvoice < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :month, :date
      field :customer_id, :big_int
      field :currency_code, :string, max_size: 3
      field :invoice_id, :big_int, null: true, blank: true
      field :mode, :string, max_size: 16
      field :status, :string, max_size: 16, default: "proposed"
      field :error, :text, blank: true, default: ""
      field :created_by_id, :big_int, null: true, blank: true

      with_timestamp_fields
    end

    # Passage de fin de mois effectué (un par mois) : la tâche planifiée
    # rattrape le mois précédent tant qu'il n'est pas clos.
    class MonthClose < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :month, :date, unique: true
      field :trigger, :string, max_size: 16
      field :prepared, :int, default: 0
      field :created_at, :date_time, null: true, blank: true
    end
  end
end
