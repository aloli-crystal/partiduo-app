# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Auth
    # Profil de droits (ADR-002 D4, ADR-003 D4), héritier de `profile` et de
    # `profile_menu` : un profil porte des *permissions nommées* déclarées par
    # les manifestes du registre ; la visibilité des menus en découle.
    #
    # `admin` reprend le profil administrateur de NOALYSS : toutes les
    # permissions des pièces actives, et l'accès en écriture à tous les
    # journaux. `code` identifie les profils créés par défaut (`ADMIN`,
    # `ACCOUNTANT`) ; il est vide pour ceux de l'administrateur.
    class Profile < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :code, :string, max_size: 32, blank: true, default: ""
      field :name, :string, max_size: 100, unique: true
      field :description, :text, blank: true, default: ""
      field :admin, :bool, default: false
      field :created_at, :date_time, auto_now_add: true
      field :updated_at, :date_time, auto_now: true
    end

    # Permission cochée dans un profil (héritière d'une ligne de `profile_menu`).
    class ProfilePermission < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :profile, :many_to_one, to: Partiduo::Auth::Profile, on_delete: :cascade
      field :permission, :string, max_size: 128

      db_unique_constraint :auth_profile_permission_unique, field_names: [:profile, :permission]
    end
  end
end
