# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Auth
    # Utilisateur de l'instance (ADR-002 D1), héritier d'`ac_users` et de
    # `user_active_security`. Modèle interne : l'interface passe par
    # `Partiduo::Api::Auth`.
    #
    # * `role` : `member` (utilisateur de la société) ou `accountant` (rôle
    #   `comptable`, ADR-002 D4 : niveau 3, droits administratifs exclus,
    #   compte nominatif, date de fin, révocation) ;
    # * `ledger_security` : héritier de `user_active_security.us_ledger` —
    #   faux, l'utilisateur écrit dans tous les journaux ; vrai, seuls ceux de
    #   `LedgerAccess` (héritier de `user_sec_jrn`) lui sont ouverts ;
    # * limitation des tentatives : `failed_attempts`, `last_failed_at`,
    #   `locked_at` (voir `Throttle`) ;
    # * TOTP : `totp_secret` (base32), `last_otp_counter` (anti-rejeu, repassé
    #   en `after:`), `totp_pending_secret` pendant l'enrôlement.
    class User < MartenAuth::User
      ROLES = %w[member accountant]

      field :first_name, :string, max_size: 100, blank: true, default: ""
      field :last_name, :string, max_size: 100, blank: true, default: ""
      field :locale, :string, max_size: 8, default: "fr"
      field :role, :string, max_size: 16, default: "member"
      field :profile, :many_to_one, to: Partiduo::Auth::Profile, null: true, blank: true, on_delete: :protect
      field :is_active, :bool, default: true
      field :access_ends_on, :date, null: true, blank: true
      field :revoked_at, :date_time, null: true, blank: true
      field :ledger_security, :bool, default: false

      field :failed_attempts, :int, default: 0
      field :last_failed_at, :date_time, null: true, blank: true
      field :locked_at, :date_time, null: true, blank: true

      field :totp_secret, :string, max_size: 64, null: true, blank: true
      field :totp_pending_secret, :string, max_size: 64, null: true, blank: true
      field :totp_enabled_at, :date_time, null: true, blank: true
      field :last_otp_counter, :big_int, null: true, blank: true

      field :passkey_prompt_dismissed_at, :date_time, null: true, blank: true
      field :last_login_at, :date_time, null: true, blank: true
      field :password_changed_at, :date_time, null: true, blank: true

      def accountant? : Bool
        role == "accountant"
      end

      def full_name : String
        "#{first_name} #{last_name}".strip
      end

      # Libellé nominatif conservé dans le journal d'audit.
      def audit_label : String
        name = full_name
        name.empty? ? email.to_s : "#{name} <#{email}>"
      end

      def usable_password? : Bool
        hash = password
        !hash.nil? && !hash.empty? && !hash.starts_with?('!')
      end

      def totp_enabled? : Bool
        !totp_secret.nil? && !totp_enabled_at.nil?
      end

      def revoked? : Bool
        !revoked_at.nil?
      end

      def locked? : Bool
        !locked_at.nil?
      end

      # Date de fin d'accès dépassée (ADR-002 D4) : l'accès vaut jusqu'au jour
      # inclus.
      def access_expired?(now : Time = Time.utc) : Bool
        if ends = access_ends_on
          return now.at_beginning_of_day > ends
        end
        false
      end

      # Peut ouvrir une session : actif, non révoqué, dans sa période d'accès.
      def can_sign_in?(now : Time = Time.utc) : Bool
        is_active == true && !revoked? && !access_expired?(now)
      end
    end
  end
end
