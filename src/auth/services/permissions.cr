# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Auth
    # Droits effectifs d'un utilisateur, construits depuis son profil et le
    # registre `Partiduo::Modules` (ADR-003 D4).
    #
    # Interface avec le registre (voir DECISIONS) : le profil stocke des *noms*
    # de permission ; seules comptent celles que déclare une pièce active
    # (`Partiduo::Modules.active_permissions`). Un profil garde ainsi les
    # permissions d'un module désactivé, qui reprennent effet à sa réactivation.
    module Permissions
      # Permissions *administratives* : jamais accordées au rôle `comptable`
      # (ADR-002 D4 — ni administration des utilisateurs, ni configuration de
      # la société). Toutes celles de `AUTH`, et celles de `CORE` qui se
      # terminent par `.manage`.
      def self.administrative?(name : String) : Bool
        name.starts_with?("auth.") || (name.starts_with?("core.") && name.ends_with?(".manage"))
      end

      # Permissions cochées dans le profil (toutes les permissions actives pour
      # un profil administrateur).
      def self.of_profile(profile : Profile) : Set(String)
        active = Partiduo::Modules.active_permissions.to_set
        return active if profile.admin
        ProfilePermission.filter(profile_id: profile.pk).map(&.permission.to_s)
          .select { |name| active.includes?(name) }.to_set
      end

      # Droits de l'utilisateur, hors niveau de session.
      def self.of_user(user : User) : Set(String)
        profile = user.profile
        return Set(String).new if profile.nil?
        permissions = of_profile(profile)
        permissions.reject! { |name| administrative?(name) } if user.accountant?
        permissions
      end

      # Le profil ouvre-t-il l'accès à tous les journaux (profil administrateur,
      # hors rôle `comptable`) ?
      def self.all_ledgers?(user : User) : Bool
        profile = user.profile
        !profile.nil? && profile.admin == true && !user.accountant?
      end
    end
  end
end
