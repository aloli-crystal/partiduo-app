# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Core
    # Réémission de l'invitation d'administrateur (recours d'accès, ADR-008
    # D3), pour `manage instance admin-invite`. L'adresse doit désigner un
    # administrateur existant (profil administrateur), qui reçoit une
    # nouvelle invitation. Une adresse inconnue, un compte sans profil
    # administrateur ou un compte révoqué par la société sont refusés : la
    # plateforme ne crée, ne donne ni ne rend de droits que la société n'a
    # pas donnés (ADR-002 D3, D-CLI-005 amendée par D-AFN-003).
    module AdminInvitation
      record Issued, email : String, token : String, expires_at : Time, created : Bool, usable_admins : Int32

      # À appeler dans une transaction, avec l'inscription au journal
      # d'audit. Lève `InstanceAdmin::Failure` en cas de refus.
      def self.issue(email : String) : Issued
        actor = Partiduo::Api::Actor.system
        profiles = Partiduo::Api::Auth.ensure_default_profiles(actor)
        admin_ids = profiles.select(&.admin).map(&.id).to_set
        usable = Partiduo::Api::Auth.users(actor).count do |user|
          admin_ids.includes?(user.profile_id) && user.active && !user.revoked &&
            (user.has_password || user.passkey_count > 0)
        end

        user = Partiduo::Api::Auth.user_by_email(actor, email) ||
               raise refused("instance.admin_invitation.unknown", "unknown", email.strip)
        unless admin_ids.includes?(user.profile_id)
          raise refused("instance.admin_invitation.not_admin", "not_admin", user.email)
        end
        raise refused("instance.admin_invitation.revoked", "revoked", user.email) if user.revoked
        token = Partiduo::Api::Auth.issue_invitation(actor, user.id)
        Issued.new(user.email, token.token, token.expires_at, false, usable)
      end

      private def self.refused(reason : String, key : String, email : String) : Exception
        InstanceAdmin::Failure.new("refused", reason,
          I18n.t("core.instance_cli.errors.#{key}", email: email))
      end
    end
  end
end
