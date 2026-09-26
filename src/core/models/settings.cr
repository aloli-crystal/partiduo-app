# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Core
    # Identité de la société et configuration du dossier : *une seule ligne*
    # par instance (ADR-001 glossaire « Société », D2). Héritière de la table
    # `parameter` de NOALYSS (`MY_NAME`, `MY_TVA`, `MY_STREET`, `MY_NUMBER`,
    # `MY_CP`, `MY_COMMUNE`, `MY_TEL`, `MY_COUNTRY`…), réduite à l'identité et
    # à la politique d'authentification (ADR-002 D1) ; les options comptables
    # (`MY_STRICT`, `MY_ANALYTIC`…) arrivent avec les modules qui les lisent.
    #
    # L'unicité de la ligne est garantie en base (index unique sur une
    # expression constante, migration `0001`). Modèle interne : l'interface
    # passe par `Partiduo::Api::Core.settings` et `update_settings`.
    class Settings < Marten::Model
      field :id, :big_int, primary_key: true, auto: true

      # Identité
      field :company_name, :string, max_size: 255
      field :legal_form, :string, max_size: 64, blank: true, default: ""
      field :share_capital, :decimal, max_digits: 20, decimal_places: 4, blank: true, null: true
      field :rcs, :string, max_size: 128, blank: true, default: ""
      field :siren, :string, max_size: 9, blank: true, default: ""
      field :vat_number, :string, max_size: 32, blank: true, default: ""

      # Adresse
      field :street, :string, max_size: 255, blank: true, default: ""
      field :street_number, :string, max_size: 32, blank: true, default: ""
      field :postcode, :string, max_size: 16, blank: true, default: ""
      field :city, :string, max_size: 128, blank: true, default: ""
      field :country_code, :string, max_size: 2
      field :phone, :string, max_size: 32, blank: true, default: ""
      field :email, :string, max_size: 254, blank: true, default: ""

      # Dossier
      field :tax_regime, :string, max_size: 2
      field :default_locale, :string, max_size: 8
      field :domain, :string, max_size: 253

      # Politique d'authentification (ADR-002 D1, D2) : méthodes autorisées
      # (liste séparée par des virgules), niveau minimum exigé, durée de session.
      field :auth_methods, :string, max_size: 64
      field :auth_minimum_level, :int
      field :session_duration_minutes, :int

      field :created_at, :date_time, auto_now_add: true
      field :updated_at, :date_time, auto_now: true

      def auth_method_list : Array(String)
        auth_methods.to_s.split(',').map(&.strip).reject(&.empty?)
      end
    end
  end
end
