# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    # Préférences de l'utilisateur (DECISIONS D-AUTH-016) : réglages
    # personnels, enregistrés avec son compte, qui le suivent d'un appareil à
    # l'autre. Chacun ne lit et ne change que les siens (acteur authentifié,
    # même sous le niveau exigé, comme la sécurité du compte) ; aucune
    # permission, aucun effet sur les droits.
    module Auth
      def self.preferences(actor : Actor) : PreferencesView
        preferences_view(current_user(actor))
      end

      def self.update_preferences(actor : Actor, input : PreferencesInput) : Result(PreferencesView)
        user = current_user(actor)
        if interface = input.interface
          unless INTERFACES.includes?(interface)
            return Result(PreferencesView).failure(FieldError.new("interface", "auth.errors.preferences.interface_invalid"))
          end
          # Mise à jour ciblée : ne réécrit ni le compteur d'échecs ni la sécurité.
          Partiduo::Auth::User.filter(id: user.pk).update(interface: interface)
          user.interface = interface
        end
        Result(PreferencesView).success(preferences_view(user))
      end

      # Préférence choisie, sinon défaut du rôle : comptabilité pour le
      # comptable, présentation simplifiée pour un utilisateur de la société.
      private def self.preferences_view(user : Partiduo::Auth::User) : PreferencesView
        chosen = user.interface.presence
        default = user.accountant? ? INTERFACE_FULL : INTERFACE_SIMPLE
        PreferencesView.new(interface: chosen || default, interface_chosen: !chosen.nil?)
      end
    end
  end
end
