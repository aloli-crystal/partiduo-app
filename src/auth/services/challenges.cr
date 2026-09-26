# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Auth
    # Défis et jetons à usage unique. Le client reçoit une poignée (`handle`)
    # ou un jeton ; la base n'en garde que l'empreinte, et une consommation
    # marque la ligne utilisée dans la même instruction SQL (une poignée ne
    # sert qu'une fois, même sous des requêtes concurrentes).
    module Challenges
      record Issued, challenge : Challenge, handle : String

      def self.issue(purpose : String, user : User? = nil, value : String = "", data : String = "",
                     ttl : Time::Span = Config::CHALLENGE_TIMEOUT, now : Time = Time.utc) : Issued
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

      def self.purge_expired(now : Time = Time.utc) : Nil
        Challenge.filter(expires_at__lt: now - 1.day).delete
      end
    end

    # Jetons remis hors bande : invitation, remise à zéro, déblocage.
    module Tokens
      def self.issue(user : User, purpose : String, ttl : Time::Span, now : Time = Time.utc) : {Token, String}
        raise ArgumentError.new("jeton inconnu : #{purpose}") unless Token::PURPOSES.includes?(purpose)
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
