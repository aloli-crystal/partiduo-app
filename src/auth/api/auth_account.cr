# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    # Sécurité du compte (ADR-002 D6, D7) : ouverte à tout utilisateur
    # authentifié, y compris dans une session d'un niveau insuffisant — c'est
    # par là qu'il s'élève. Les opérations qui *affaiblissent* le compte
    # (retrait d'une passkey, désactivation du TOTP, nouveaux codes de
    # récupération) exigent une session de niveau 2 au moins.
    module Auth
      SENSITIVE_LEVEL = 2

      def self.security_overview(actor : Actor) : SecurityView
        user = current_user(actor)
        policy = Partiduo::Auth::Policy.current
        passkeys = Partiduo::Auth::Passkey.filter(user_id: user.pk).order(:created_at).map { |passkey| passkey_view(passkey) }
        methods = [] of String
        methods << "password" if user.usable_password?
        methods << "totp" if user.totp_enabled?
        methods << "passkey" unless passkeys.empty?
        methods << "federated" if Partiduo::Auth::FederatedIdentity.filter(user_id: user.pk).exists?
        SecurityView.new(
          user_id: user.pk!.as(Int64),
          achievable_level: Partiduo::Auth::Levels.achievable(user, policy),
          session_level: actor.level,
          required_level: Partiduo::Auth::Levels.required(user, policy),
          methods: methods,
          missing: Partiduo::Auth::Levels.missing(user, policy),
          passkeys: passkeys,
          recovery_codes_remaining: Partiduo::Auth::RecoveryCodes.remaining(user),
          suggest_passkey: Partiduo::Auth::Levels.suggest_passkey?(user, policy),
          has_password: user.usable_password?,
        )
      end

      # Refuse l'invitation à enrôler une passkey ; elle sera rappelée.
      def self.dismiss_passkey_prompt(actor : Actor) : Result(Nil)
        user = current_user(actor)
        user.passkey_prompt_dismissed_at = Time.utc
        user.save!
        Result(Nil).success(nil)
      end

      # --- Mot de passe ------------------------------------------------------

      # Définit ou change le mot de passe. Le mot de passe actuel est exigé si
      # le compte en a un, sauf dans une session d'enrôlement (invitation).
      def self.change_password(actor : Actor, input : ChangePasswordInput) : Result(Nil)
        user = current_user(actor)
        return Result(Nil).failure(FieldError.base("auth.errors.login.method_disabled")) unless Partiduo::Auth::Policy.current.allows?("password")
        if user.usable_password? && actor.level > Partiduo::Auth::Levels::ENROLLMENT
          current = input.current_password || ""
          unless Partiduo::Auth::Passwords.verify(user, current)
            Partiduo::Auth::Throttle.record_failure(user)
            return Result(Nil).failure(FieldError.new("current_password", "auth.errors.password.current_invalid"))
          end
        end
        errors = Partiduo::Auth::Passwords.errors(input.new_password, "new_password",
          Partiduo::Auth::Passwords.personal_words(user.email.to_s, user.first_name.to_s, user.last_name.to_s))
        return Result(Nil).failure(errors) unless errors.empty?
        store_password(user, input.new_password)
        Partiduo::Auth::Audit.record("password.change", "SUCCESS", user: user)
        Result(Nil).success(nil)
      end

      # --- TOTP ----------------------------------------------------------------

      # Enrôlement, étape 1 : nouveau secret, en attente de confirmation.
      def self.begin_totp_enrollment(actor : Actor) : TotpEnrollmentView
        user = current_user(actor)
        secret = TOTP.generate_secret_base32
        user.totp_pending_secret = secret
        user.save!
        uri = Partiduo::Auth::Totp.provisioning_uri(user, secret)
        qr = Partiduo::Auth::QrCode.encode(uri)
        TotpEnrollmentView.new(
          secret_base32: secret.delete('='),
          provisioning_uri: uri,
          qr_code: QrCodeView.new(qr.size, qr.modules),
          issuer: Partiduo::Auth::Config::ISSUER,
          account: user.email.to_s,
          algorithm: Partiduo::Auth::Totp::ALGORITHM,
          digits: Partiduo::Auth::Totp::DIGITS,
          period: Partiduo::Auth::Totp::PERIOD,
        )
      end

      # Enrôlement, étape 2 : un code de l'application confirme le secret. Le
      # compteur accepté devient `last_otp_counter` (le même code ne servira
      # pas à la connexion). Premiers codes de récupération le cas échéant.
      def self.confirm_totp_enrollment(actor : Actor, code : String) : Result(RecoveryCodesView)
        user = current_user(actor)
        counter = Partiduo::Auth::Totp.verify_pending(user, code)
        return Result(RecoveryCodesView).failure(FieldError.new("code", "auth.errors.login.invalid_code")) if counter.nil?
        Transaction.run do
          user.totp_secret = user.totp_pending_secret
          user.totp_pending_secret = nil
          user.totp_enabled_at = Time.utc
          user.last_otp_counter = counter.to_i64
          user.save!
          codes = Partiduo::Auth::RecoveryCodes.ensure(user)
          Partiduo::Auth::Audit.record("totp.enable", "SUCCESS", user: user)
          Result(RecoveryCodesView).success(RecoveryCodesView.new(codes))
        end
      end

      def self.disable_totp(actor : Actor, code : String) : Result(Nil)
        user = current_user(actor)
        require_level!(actor)
        unless Partiduo::Auth::Totp.verify!(user, code)
          Partiduo::Auth::Throttle.record_failure(user)
          return Result(Nil).failure(FieldError.new("code", "auth.errors.login.invalid_code"))
        end
        user.totp_secret = nil
        user.totp_enabled_at = nil
        user.last_otp_counter = nil
        user.save!
        Partiduo::Auth::Audit.record("totp.disable", "SUCCESS", user: user)
        Result(Nil).success(nil)
      end

      # --- Codes de récupération --------------------------------------------

      def self.regenerate_recovery_codes(actor : Actor) : Result(RecoveryCodesView)
        user = current_user(actor)
        require_level!(actor)
        Transaction.run do
          codes = Partiduo::Auth::RecoveryCodes.generate(user)
          Partiduo::Auth::Audit.record("recovery_codes.generate", "SUCCESS", user: user)
          Result(RecoveryCodesView).success(RecoveryCodesView.new(codes))
        end
      end

      # --- Passkeys ------------------------------------------------------------

      def self.begin_passkey_registration(actor : Actor) : RegistrationOptionsView
        user = current_user(actor)
        raise Forbidden.new unless Partiduo::Auth::Policy.current.allows?("passkey")
        issued = Partiduo::Auth::Passkeys.begin_registration(user)
        RegistrationOptionsView.new(
          challenge_id: issued.handle,
          challenge: issued.challenge.value.to_s,
          rp_id: Partiduo::Auth::Config.rp_id,
          rp_name: Partiduo::Auth::Config::ISSUER,
          user_handle: Partiduo::Auth::Secrets.base64url(Partiduo::Auth::Passkeys.user_handle(user)),
          user_name: user.email.to_s,
          user_display_name: user.full_name.presence || user.email.to_s,
          algorithms: Partiduo::Auth::Passkeys.algorithms,
          resident_key: "required",
          user_verification: "required",
          attestation: "none",
          timeout_ms: Partiduo::Auth::Passkeys::TIMEOUT_MS,
          exclude_credentials: Partiduo::Auth::Passkey.filter(user_id: user.pk).map(&.credential_id.to_s),
        )
      end

      # Enregistre la passkey. On n'enrôle jamais une passkey seule
      # (ADR-002 D7) : des codes de récupération sont générés si l'utilisateur
      # n'en a plus, et renvoyés pour un affichage unique.
      def self.finish_passkey_registration(actor : Actor, input : PasskeyRegistrationInput) : Result(PasskeyEnrollmentView)
        user = current_user(actor)
        return Result(PasskeyEnrollmentView).failure(FieldError.base("auth.errors.login.method_disabled")) unless Partiduo::Auth::Policy.current.allows?("passkey")
        passkey = begin
          Partiduo::Auth::Passkeys.finish_registration(user, input.challenge_id, input.attestation_object,
            input.client_data_json, input.transports, input.name)
        rescue ex : Partiduo::Auth::Passkeys::Error
          Partiduo::Auth::Audit.record("passkey.register", "FAIL", user: user, detail: ex.message.to_s)
          return Result(PasskeyEnrollmentView).failure(FieldError.base(ex.key))
        end
        codes = Partiduo::Auth::RecoveryCodes.ensure(user)
        Partiduo::Auth::Audit.record("passkey.register", "SUCCESS", user: user, detail: passkey.name.to_s)
        Result(PasskeyEnrollmentView).success(PasskeyEnrollmentView.new(passkey_view(passkey), codes))
      end

      def self.rename_passkey(actor : Actor, passkey_id : Int64, name : String) : Result(PasskeyView)
        user = current_user(actor)
        passkey = Partiduo::Auth::Passkey.filter(id: passkey_id, user_id: user.pk).first || raise NotFound.new("passkey", passkey_id)
        passkey.name = name.strip[0, 100]
        passkey.save!
        Result(PasskeyView).success(passkey_view(passkey))
      end

      def self.remove_passkey(actor : Actor, passkey_id : Int64) : Result(Nil)
        user = current_user(actor)
        require_level!(actor)
        passkey = Partiduo::Auth::Passkey.filter(id: passkey_id, user_id: user.pk).first || raise NotFound.new("passkey", passkey_id)
        passkey.delete
        Partiduo::Auth::Audit.record("passkey.remove", "SUCCESS", user: user, detail: passkey.name.to_s)
        Result(Nil).success(nil)
      end

      # --- Droits de l'acteur --------------------------------------------------

      # Droit de l'acteur sur un journal (`W`, `R`, `X`), héritier de
      # `get_ledger_access` : le module Comptabilité l'appelle avant de lire
      # ou d'écrire dans un journal.
      def self.ledger_access(actor : Actor, ledger_id : Int64) : String
        Guard.authorize!(actor, nil, module_code: "AUTH")
        return "W" if actor.system
        user = current_user(actor)
        return "X" if actor.level < Partiduo::Auth::Levels.required(user) # session d'un niveau insuffisant
        Partiduo::Auth::Ledgers.access(user, ledger_id)
      end

      # Inscrit une action dans le journal d'audit nominatif (ADR-002 D4) : un
      # module y consigne ce qu'il juge utile (« qui a passé cette écriture »).
      def self.audit(actor : Actor, action : String, module_code : String, detail : String = "") : Nil
        Guard.authorize!(actor, nil, module_code: "AUTH")
        Partiduo::Auth::Audit.record_for(actor, action, "AUDIT", module_code: module_code, detail: detail)
      end

      # --- Aides internes -----------------------------------------------------

      private def self.current_user(actor : Actor) : Partiduo::Auth::User
        Guard.authorize!(actor, nil, module_code: "AUTH")
        user_id = actor.user_id || raise Forbidden.new
        user = Partiduo::Auth::User.get(id: user_id) || raise Forbidden.new
        raise Forbidden.new unless user.can_sign_in?
        user
      end

      private def self.require_level!(actor : Actor, level : Int32 = SENSITIVE_LEVEL) : Nil
        raise ElevationRequired.new(level) if actor.level < level
      end

      private def self.passkey_view(passkey : Partiduo::Auth::Passkey) : PasskeyView
        PasskeyView.new(
          id: passkey.pk!.as(Int64),
          name: passkey.name.to_s,
          created_at: passkey.created_at,
          last_used_at: passkey.last_used_at,
          backup_eligible: passkey.backup_eligible == true,
          backup_state: passkey.backup_state == true,
          transports: passkey.transports.to_s.split(',').reject(&.empty?),
        )
      end
    end
  end
end
