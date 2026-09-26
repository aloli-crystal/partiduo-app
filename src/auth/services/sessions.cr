# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Auth
    # Sessions : ouvertes par une authentification réussie, vérifiées à
    # chaque requête (l'interface garde le jeton dans un cookie et demande
    # l'acteur au contrat). Une révocation d'utilisateur, une date de fin
    # dépassée ou une désactivation coupent *immédiatement* toutes ses
    # sessions (ADR-002 D4).
    module Sessions
      record Opened, session : Session, token : String

      def self.open(user : User, level : Int32, method : String, ip : String = "",
                    user_agent : String = "", now : Time = Time.utc) : Opened
        token = Secrets.token
        session = Session.create!(
          user: user,
          token_digest: Secrets.digest(token),
          level: level,
          method: method,
          ip: ip[0, 64],
          user_agent: user_agent[0, 255],
          last_seen_at: now,
          expires_at: now + Policy.current.session_minutes.minutes,
        )
        user.last_login_at = now
        user.save!
        Opened.new(session, token)
      end

      # Session valide pour ce jeton, ou `nil` : inconnue, révoquée, expirée,
      # inactive depuis trop longtemps, ou utilisateur qui ne peut plus entrer.
      def self.find(token : String?, now : Time = Time.utc, touch : Bool = true) : Session?
        return if token.nil? || token.empty?
        session = Session.filter(token_digest: Secrets.digest(token)).first
        return if session.nil? || !session.revoked_at.nil?
        return if session.expires_at!.<(now) || session.last_seen_at! + Config::IDLE_TIMEOUT < now
        user = session.user
        return if user.nil? || !user.can_sign_in?(now)
        if touch && session.last_seen_at! + 1.minute < now
          session.last_seen_at = now
          session.save!
        end
        session
      end

      def self.revoke(session : Session, now : Time = Time.utc) : Nil
        return unless session.revoked_at.nil?
        session.revoked_at = now
        session.save!
      end

      def self.revoke_all(user : User, now : Time = Time.utc) : Int64
        Session.filter(user_id: user.pk, revoked_at__isnull: true).update(revoked_at: now).to_i64
      end

      # Acteur du contrat pour une session. Session d'un niveau inférieur à
      # celui qu'exige l'utilisateur : authentifié, mais *sans aucune
      # permission* — seules les opérations ouvertes à tout utilisateur
      # authentifié (sécurité du compte, enrôlement) lui restent permises.
      def self.actor(session : Session) : Partiduo::Api::Actor
        user = session.user!
        permissions = if (session.level || 0).to_i32 >= Levels.required(user)
                        Permissions.of_user(user)
                      else
                        Set(String).new
                      end
        Partiduo::Api::Actor.user(user.pk!.as(Int64), permissions, (session.level || 0).to_i32)
      end
    end
  end
end
