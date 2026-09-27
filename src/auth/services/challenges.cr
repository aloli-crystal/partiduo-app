# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Auth
    # Défis et jetons à usage unique. Le client reçoit une poignée (`handle`)
    # ou un jeton ; la base n'en garde que l'empreinte, et une consommation
    # marque la ligne utilisée dans la même instruction SQL (une poignée ne
    # sert qu'une fois, même sous des requêtes concurrentes).
    module Challenges
      record Issued, challenge : Challenge, handle : String

      # Purge des défis et jetons échus : tirée au sort une fois sur
      # `PURGE_ONE_IN` émissions (pas de tâche planifiée à tenir), pour que des
      # demandes anonymes répétées ne fassent pas grossir la table sans fin.
      PURGE_ONE_IN = 50

      def self.issue(purpose : String, user : User? = nil, value : String = "", data : String = "",
                     ttl : Time::Span = Config::CHALLENGE_TIMEOUT, now : Time = Time.utc) : Issued
        purge_expired(now) if Random.rand(PURGE_ONE_IN).zero?
        handle = Secrets.token
        challenge = Challenge.create!(
          purpose: purpose,
          handle_digest: Secrets.digest(handle),
          value: value,
          data: data,
          user: user,
          expires_at: now + ttl,
        )
        Issued.new(challenge, handle)
      end

      # Consomme la poignée : renvoie le défi s'il était valide, `nil` sinon.
      def self.consume(purpose : String, handle : String?, now : Time = Time.utc) : Challenge?
        return if handle.nil? || handle.empty?
        digest = Secrets.digest(handle)
        claimed = Challenge
          .filter(handle_digest: digest, purpose: purpose, used_at__isnull: true, expires_at__gt: now)
          .update(used_at: now)
        return unless claimed == 1
        Challenge.get(handle_digest: digest)
      end

      # Lit sans consommer (second facteur : plusieurs essais permis, dans la
      # limite de `Throttle`).
      def self.peek(purpose : String, handle : String?, now : Time = Time.utc) : Challenge?
        return if handle.nil? || handle.empty?
        Challenge.filter(handle_digest: Secrets.digest(handle), purpose: purpose,
          used_at__isnull: true, expires_at__gt: now).first
      end

      # Défis et jetons échus depuis plus d'un jour (le délai garde une trace
      # récente pour le diagnostic).
      def self.purge_expired(now : Time = Time.utc) : Nil
        Challenge.filter(expires_at__lt: now - 1.day).delete
        Token.filter(expires_at__lt: now - 1.day).delete
      end
    end

    # Jetons remis hors bande : invitation, remise à zéro, déblocage.
    module Tokens
      # Délai minimum entre deux jetons de même usage demandés *par
      # l'utilisateur* (remise à zéro, déblocage) : la boîte aux lettres ne
      # peut pas être inondée.
      REQUEST_INTERVAL = 2.minutes

      # Un jeton de cet usage, encore valable, a-t-il été émis il y a moins de
      # `REQUEST_INTERVAL` ?
      def self.recently_issued?(user : User, purpose : String, now : Time = Time.utc) : Bool
        Token.filter(user_id: user.pk, purpose: purpose, used_at__isnull: true, expires_at__gt: now,
          created_at__gt: now - REQUEST_INTERVAL).exists?
      end

      def self.issue(user : User, purpose : String, ttl : Time::Span, now : Time = Time.utc) : {Token, String}
        raise ArgumentError.new("jeton inconnu : #{purpose}") unless Token::PURPOSES.includes?(purpose)
        Challenges.purge_expired(now) if Random.rand(Challenges::PURGE_ONE_IN).zero?
        # Un nouveau jeton annule les précédents de même usage.
        Token.filter(user_id: user.pk, purpose: purpose, used_at__isnull: true).update(used_at: now)
        raw = Secrets.token
        {Token.create!(purpose: purpose, digest: Secrets.digest(raw), user: user, expires_at: now + ttl), raw}
      end

      def self.consume(purpose : String, raw : String?, now : Time = Time.utc) : User?
        return if raw.nil? || raw.empty?
        digest = Secrets.digest(raw)
        claimed = Token.filter(digest: digest, purpose: purpose, used_at__isnull: true, expires_at__gt: now)
          .update(used_at: now)
        return unless claimed == 1
        Token.get(digest: digest).try(&.user)
      end
    end
  end
end
