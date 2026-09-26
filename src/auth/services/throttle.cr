# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Auth
    # Limitation des attaques en ligne (ADR-001, CAPTCHA abandonné ;
    # délibération CNIL 2022-100) : c'est elle qui autorise le palier à
    # 50 bits de la politique de mot de passe.
    #
    # * Chaque échec (mot de passe, code TOTP, code de récupération) incrémente
    #   `failed_attempts` de l'utilisateur visé ; un succès le remet à zéro.
    # * À partir du 3ᵉ échec consécutif, *temporisation croissante* : 5 s,
    #   10 s, 20 s… (doublée à chaque échec, plafonnée à 15 min). Pendant ce
    #   délai, une tentative est refusée sans que le secret soit examiné.
    # * Au 10ᵉ échec, *blocage* : plus aucune connexion par mot de passe
    #   jusqu'au déblocage — par un administrateur (`unlock_user`), par un
    #   jeton de déblocage ou par la remise à zéro du mot de passe.
    #
    # La passkey n'est pas concernée : elle ne se devine pas.
    module Throttle
      FAILURE_SQL = <<-SQL
        UPDATE auth_user
           SET failed_attempts = failed_attempts + 1,
               last_failed_at = $1,
               locked_at = CASE WHEN failed_attempts + 1 >= $2 AND locked_at IS NULL
                                THEN $1 ELSE locked_at END
         WHERE id = $3
        RETURNING failed_attempts
        SQL

      # Délai imposé après `failures` échecs consécutifs.
      def self.delay_for(failures : Int32) : Time::Span
        return Time::Span.zero if failures < Config::THROTTLE_AFTER
        exponent = (failures - Config::THROTTLE_AFTER).clamp(0, 20)
        delay = Config::THROTTLE_BASE * (2 ** exponent)
        delay > Config::THROTTLE_MAXIMUM ? Config::THROTTLE_MAXIMUM : delay
      end

      # Temps restant avant la prochaine tentative admise, ou `nil`.
      def self.retry_after(user : User, now : Time = Time.utc) : Time::Span?
        failures = (user.failed_attempts || 0).to_i32
        last = user.last_failed_at
        return if last.nil? || failures < Config::THROTTLE_AFTER
        remaining = last + delay_for(failures) - now
        remaining > Time::Span.zero ? remaining : nil
      end

      # Enregistre un échec, de façon atomique (deux tentatives simultanées
      # comptent pour deux), et bloque le compte au 10ᵉ. Renvoie le nombre
      # d'échecs consécutifs.
      def self.record_failure(user : User, now : Time = Time.utc) : Int32
        count = Marten::DB::Connection.default.open do |db|
          db.scalar(FAILURE_SQL, now, Config::LOCK_AFTER, user.pk!.as(Int64)).as(Int32)
        end
        user.reload
        count
      end

      # Succès : le compteur repart de zéro.
      def self.record_success(user : User) : Nil
        return if (user.failed_attempts || 0).zero? && user.last_failed_at.nil?
        user.failed_attempts = 0
        user.last_failed_at = nil
        user.save!
      end

      # Déblocage : compteur et blocage levés.
      def self.unlock(user : User) : Nil
        user.failed_attempts = 0
        user.last_failed_at = nil
        user.locked_at = nil
        user.save!
      end
    end
  end
end
