# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Invoicing
    # Paramètres de la Facturation (ligne unique) : conditions de paiement,
    # pénalités, escompte, option de TVA sur les débits, coordonnées
    # bancaires, relances, expéditeur des courriels, comptes et journaux de
    # l'export au comptable (Facturation seule, ADR-006 D4).
    class Settings < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :payment_terms_days, :int, default: 30
      field :quote_validity_days, :int, default: 30
      # Taux annuel des pénalités de retard, en pourcentage ; vide : taux
      # légal (taux BCE majoré de 10 points, art. L441-10 du Code de commerce).
      field :late_penalty_rate, :decimal, max_digits: 7, decimal_places: 4, null: true, blank: true
      # Escompte pour paiement anticipé ; vide : pas d'escompte.
      field :early_discount_rate, :decimal, max_digits: 7, decimal_places: 4, null: true, blank: true
      field :early_discount_days, :int, null: true, blank: true
      field :vat_on_debits, :bool, default: false
      field :default_operation_category, :string, max_size: 16, default: "services"
      field :iban, :string, max_size: 34, blank: true, default: ""
      field :bic, :string, max_size: 11, blank: true, default: ""
      field :sender_email, :string, max_size: 254, blank: true, default: ""
      field :sender_name, :string, max_size: 128, blank: true, default: ""
      field :reminder1_days, :int, default: 7
      field :reminder2_days, :int, default: 30
      field :reminder3_days, :int, default: 60
      # Premier niveau de relance qui chiffre les pénalités (0 : jamais).
      field :penalty_from_level, :int, default: 2
      field :reminder_subject, :string, max_size: 255, blank: true, default: ""
      field :reminder_body, :text, blank: true, default: ""
      field :sales_journal_code, :string, max_size: 8, default: "VT"
      field :bank_journal_code, :string, max_size: 8, default: "BQ"
      field :customer_account, :string, max_size: 20, blank: true, default: ""
      field :sales_account, :string, max_size: 20, blank: true, default: ""
      field :vat_account, :string, max_size: 20, blank: true, default: ""
      field :bank_account, :string, max_size: 20, blank: true, default: ""

      with_timestamp_fields
    end
  end
end
