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
    # *Réservation atomique* (D-AUTH-012) : une tentative est comptée comme un
    # échec *avant* l'examen du secret, par une seule instruction SQL qui
    # vérifie en même temps blocage et temporisation (`reserve`). Des
    # requêtes simultanées ne peuvent donc pas examiner plus de secrets que la
    # temporisation n'en admet. Un secret juste rend la réservation :
    # `record_success` (le compteur repart de zéro) ou `release` (étape
    # intermédiaire — mot de passe juste, second facteur encore attendu —, le
    # compteur revient à sa valeur d'avant). Un secret faux la confirme :
    # `confirm_failure` (blocage au 10ᵉ).
    #
    # La passkey n'est pas concernée : elle ne se devine pas.
    module Throttle
      # Tentative admise (`granted`), ou refusée : compte bloqué (`locked`) ou
      # temporisation en cours (`wait`).
      record Reservation, granted : Bool, locked : Bool = false, wait : Time::Span? = nil,
        count : Int32 = 0, reserved_at : Time? = nil, previous_failed_at : Time? = nil

      # $1 : identifiant, $2 : maintenant, $3 : THROTTLE_AFTER,
      # $4 : THROTTLE_BASE (s), $5 : THROTTLE_MAXIMUM (s).
      RESERVE_SQL = <<-SQL
        WITH previous AS (
          SELECT id, last_failed_at FROM auth_user WHERE id = $1 FOR UPDATE
        )
        UPDATE auth_user AS target
           SET failed_attempts = target.failed_attempts + 1,
               last_failed_at = $2
          FROM previous
         WHERE target.id = previous.id
           AND target.locked_at IS NULL
           AND (target.failed_attempts < $3
                OR target.last_failed_at IS NULL
                OR target.last_failed_at
                   + make_interval(secs => LEAST($4 * power(2, LEAST(target.failed_attempts - $3, 20)), $5))
                   <= $2)
        RETURNING target.failed_attempts, previous.last_failed_at
        SQL

      # $1 : identifiant, $2 : maintenant, $3 : LOCK_AFTER.
      CONFIRM_SQL = <<-SQL
        UPDATE auth_user
           SET locked_at = CASE WHEN failed_attempts >= $3 AND locked_at IS NULL
                                THEN $2 ELSE locked_at END
         WHERE id = $1
        RETURNING failed_attempts
        SQL

      # $1 : identifiant, $2 : horodatage de la réservation, $3 : dernier
      # échec d'avant la réservation.
      RELEASE_SQL = <<-SQL
        UPDATE auth_user
           SET failed_attempts = GREATEST(failed_attempts - 1, 0),
               last_failed_at = CASE WHEN last_failed_at = $2 THEN $3 ELSE last_failed_at END
         WHERE id = $1 AND failed_attempts > 0
        SQL

      # Délai imposé après `failures` échecs consécutifs.
      def self.delay_for(failures : Int32) : Time::Span
        return Time::Span.zero if failures < Config::THROTTLE_AFTER
        exponent = (failures - Config::THROTTLE_AFTER).clamp(0, 20)
        delay = Config::THROTTLE_BASE * (2 ** exponent)
        delay > Config::THROTTLE_MAXIMUM ? Config::THROTTLE_MAXIMUM : delay
      end

      # Temps restant avant la prochaine tentative admise, ou `nil`
      # (indicatif : seule `reserve` fait foi).
      def self.retry_after(user : User, now : Time = Time.utc) : Time::Span?
        failures = (user.failed_attempts || 0).to_i32
        last = user.last_failed_at
        return if last.nil? || failures < Config::THROTTLE_AFTER
        remaining = last + delay_for(failures) - now
        remaining > Time::Span.zero ? remaining : nil
      end

      # Réserve une tentative avant l'examen du secret. Refus sans écriture si
      # le compte est bloqué ou si la temporisation court.
      def self.reserve(user : User, now : Time = Time.utc) : Reservation
        now = now.at_beginning_of_second + (now.nanosecond // 1000).microseconds # précision de PostgreSQL
        row = Marten::DB::Connection.default.open do |db|
          db.query_one?(RESERVE_SQL, user.pk!.as(Int64), now, Config::THROTTLE_AFTER,
            Config::THROTTLE_BASE.total_seconds.to_i, Config::THROTTLE_MAXIMUM.total_seconds.to_i,
            as: {Int32, Time?})
        end
        if row
          count, previous = row
          user.failed_attempts = count
          user.last_failed_at = now
          return Reservation.new(granted: true, count: count, reserved_at: now, previous_failed_at: previous)
        end
        user.reload
        return Reservation.new(granted: false, locked: true) if user.locked?
        Reservation.new(granted: false, wait: retry_after(user, now) || 1.second)
      end

      # Secret faux : la tentative réservée reste comptée ; blocage au
      # `LOCK_AFTER`-ième échec. Renvoie le nombre d'échecs consécutifs.
      def self.confirm_failure(user : User, now : Time = Time.utc) : Int32
        count = Marten::DB::Connection.default.open do |db|
          db.scalar(CONFIRM_SQL, user.pk!.as(Int64), now, Config::LOCK_AFTER).as(Int32)
        end
        user.reload
        count
      end

      # Secret juste d'une étape intermédiaire : la tentative réservée est
      # rendue, sans remettre le compteur à zéro (un mot de passe juste ne
      # doit pas rouvrir des essais de code TOTP).
      def self.release(user : User, reservation : Reservation) : Nil
        reserved_at = reservation.reserved_at
        return unless reservation.granted && reserved_at
        Marten::DB::Connection.default.open do |db|
          db.exec(RELEASE_SQL, user.pk!.as(Int64), reserved_at, reservation.previous_failed_at)
        end
        user.reload
      end

      # Succès : le compteur repart de zéro (mise à jour ciblée, qui n'écrase
      # pas le reste de la ligne).
      def self.record_success(user : User) : Nil
        User.filter(id: user.pk).update(failed_attempts: 0, last_failed_at: nil)
        user.failed_attempts = 0
        user.last_failed_at = nil
      end

      # Déblocage : compteur et blocage levés.
      def self.unlock(user : User) : Nil
        User.filter(id: user.pk).update(failed_attempts: 0, last_failed_at: nil, locked_at: nil)
        user.failed_attempts = 0
        user.last_failed_at = nil
        user.locked_at = nil
      end
    end
  end
end
