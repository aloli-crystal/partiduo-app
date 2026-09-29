# SPDX-License-Identifier: AGPL-3.0-or-later

require "json"

module Partiduo
  module Auth
    # Authentification fédérée, autorisation locale (ADR-002 D3).
    #
    # Un fournisseur d'identité *atteste qui est la personne* ; il ne donne
    # jamais le droit d'entrer. L'identité attestée (`provider` + `subject`)
    # doit correspondre à un utilisateur *déjà créé* sur l'instance : pas
    # d'auto-provisionnement, et les droits sont ceux du compte local.
    #
    # Interface pluggable : un type de fournisseur (`saml`, intégré ; `oidc`,
    # à brancher) est une sous-classe d'`Adapter` enregistrée par
    # `Federation.register`. Une extension peut ainsi apporter OIDC sans
    # toucher au cœur :
    #
    # ```
    # class MyOidc < Partiduo::Auth::Federation::Adapter
    #   def kind : String
    #     "oidc"
    #   end
    #
    #   def validate_settings(settings)
    #     # ...
    #   end
    #
    #   def begin_login(provider, settings)
    #     # ...
    #   end
    #
    #   def complete_login(provider, settings, payload, request_id)
    #     # ...
    #   end
    # end
    #
    # Partiduo::Auth::Federation.register(MyOidc.new)
    # ```
    module Federation
      # Identité attestée par le fournisseur.
      record Identity, subject : String, email : String? = nil,
        attributes : Hash(String, Array(String)) = {} of String => Array(String)

      # Début d'une connexion : où envoyer le navigateur, et l'identifiant de
      # requête à retrouver dans la réponse (anti-rejeu, `InResponseTo`).
      record Start, redirect_url : String, request_id : String

      # Paramètre d'un type de fournisseur, pour les écrans : obligatoire,
      # secret (jamais réaffiché, gardé s'il est laissé vide), sur plusieurs
      # lignes (certificat). Libellé : `auth.provider_settings.<clé>`.
      record SettingField, key : String, required : Bool = false, secret : Bool = false, multiline : Bool = false

      # Échec d'une connexion fédérée ; `key` est une clé i18n.
      class Error < Exception
        getter key : String

        def initialize(@key : String, message : String? = nil)
          super(message || key)
        end
      end

      abstract class Adapter
        abstract def kind : String

        # Paramètres du type, dans l'ordre d'affichage (vide : saisie libre
        # par le contrat seulement).
        def settings_schema : Array(SettingField)
          [] of SettingField
        end

        # Clés i18n des paramètres manquants ou invalides (`settings.<clé>`).
        abstract def validate_settings(settings : Hash(String, String)) : Array(Partiduo::Api::FieldError)

        abstract def begin_login(provider : IdentityProvider, settings : Hash(String, String)) : Start

        # Vérifie la réponse du fournisseur et renvoie l'identité attestée ;
        # lève `Error` sinon. `request_id` : celui de `begin_login`.
        abstract def complete_login(provider : IdentityProvider, settings : Hash(String, String),
                                    payload : Hash(String, String), request_id : String) : Identity
      end

      @@adapters = {} of String => Adapter

      def self.register(adapter : Adapter) : Nil
        @@adapters[adapter.kind] = adapter
      end

      def self.adapter(kind : String) : Adapter?
        @@adapters[kind]?
      end

      def self.kinds : Array(String)
        @@adapters.keys
      end

      def self.settings_of(provider : IdentityProvider) : Hash(String, String)
        parsed = JSON.parse(provider.settings.presence || "{}")
        parsed.as_h.transform_values { |value| value.as_s? || value.to_json }
      rescue JSON::ParseException | TypeCastError
        {} of String => String
      end
    end
  end
end
