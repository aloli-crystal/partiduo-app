# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    # Connexion, session et élévation (ADR-002 D2, D3, D6).
    #
    # Les commandes de connexion sont appelées avec `Actor.anonymous`. Elles ne
    # s'exécutent pas dans `Transaction.run` : un échec doit rester enregistré
    # (compteur d'échecs, journal d'audit) alors que `Transaction.run`
    # annulerait tout (voir DECISIONS).
    module Auth
      PENDING_PURPOSE   = "login.second_factor"
      FEDERATED_PURPOSE = "login.federated"

      # --- Mot de passe (+ second facteur) -----------------------------------

      # Étape 1 : adresse et mot de passe. Temporisation croissante après
      # trois échecs, blocage au dixième (`Partiduo::Auth::Throttle`). Si
      # l'utilisateur a un TOTP ou une passkey active, le mot de passe ne
      # suffit pas : `second_factor_required` (ADR-002 D6).
      def self.login_password(actor : Actor, input : PasswordLoginInput) : Result(LoginView)
        Guard.require_module!("AUTH")
        policy = Partiduo::Auth::Policy.current
        context = input.context
        email = normalize_email(input.email)
        return login_failure("auth.errors.login.method_disabled") unless policy.allows?("password")

        user = Partiduo::Auth::User.filter(email: email).first
        if user.nil?
          Partiduo::Auth::Passwords.verify(nil, input.password)
          Partiduo::Auth::Audit.record("login.password", "FAIL", label: email, ip: context.ip, detail: "unknown")
          return login_failure("auth.errors.login.invalid_credentials")
        end

        if refusal = throttled(user, "login.password", context)
          return refusal
        end

        unless Partiduo::Auth::Passwords.verify(user, input.password)
          return failed_attempt(user, "login.password", "auth.errors.login.invalid_credentials", context)
        end

        unless user.can_sign_in?
          Partiduo::Auth::Audit.record("login.password", "FAIL", user: user, ip: context.ip, detail: "access_denied")
          return login_failure("auth.errors.login.access_denied")
        end

        if second_factor_needed?(user)
          factors = second_factors(user)
          if factors.empty?
            Partiduo::Auth::Audit.record("login.password", "FAIL", user: user, ip: context.ip, detail: "passkey_only")
            return login_failure("auth.errors.login.passkey_required")
          end
          pending = Partiduo::Auth::Challenges.issue(PENDING_PURPOSE, user: user, ttl: Partiduo::Auth::Config::PENDING_LIFETIME)
          return Result(LoginView).success(LoginView.new(
            status: "second_factor_required",
            user_id: user.pk!.as(Int64),
            pending_token: pending.handle,
            second_factors: factors,
            required_level: Partiduo::Auth::Levels.required(user, policy),
          ))
        end

        authenticated(user, Partiduo::Auth::Levels::PASSWORD, "password", "login.password", context, policy)
      end

      # Étape 2 : code TOTP ou code de récupération. Les échecs comptent comme
      # ceux du mot de passe.
      def self.login_second_factor(actor : Actor, input : SecondFactorInput) : Result(LoginView)
        Guard.require_module!("AUTH")
        context = input.context
        pending = Partiduo::Auth::Challenges.peek(PENDING_PURPOSE, input.pending_token)
        user = pending.try(&.user)
        return login_failure("auth.errors.login.expired") if pending.nil? || user.nil?

        if refusal = throttled(user, "login.second_factor", context)
          return refusal
        end

        method, accepted = case input.kind
                           when "totp"          then {"totp", Partiduo::Auth::Totp.verify!(user, input.code)}
                           when "recovery_code" then {"recovery_code", Partiduo::Auth::RecoveryCodes.consume!(user, input.code)}
                           else                      {"", false}
                           end
        return failed_attempt(user, "login.second_factor", "auth.errors.login.invalid_code", context, "code") unless accepted

        claimed = Partiduo::Auth::Challenges.consume(PENDING_PURPOSE, input.pending_token)
        return login_failure("auth.errors.login.expired") if claimed.nil?
        return login_failure("auth.errors.login.access_denied") unless user.can_sign_in?

        authenticated(user, Partiduo::Auth::Levels::TWO_FACTOR, method, "login.second_factor", context)
      end

      # --- Passkey ------------------------------------------------------------

      def self.begin_passkey_login(actor : Actor) : AuthenticationOptionsView
        Guard.require_module!("AUTH")
        issued = Partiduo::Auth::Passkeys.begin_authentication
        AuthenticationOptionsView.new(
          challenge_id: issued.handle,
          challenge: issued.challenge.value.to_s,
          rp_id: Partiduo::Auth::Config.rp_id,
          user_verification: "required",
          timeout_ms: Partiduo::Auth::Passkeys::TIMEOUT_MS,
          allow_credentials: [] of String,
        )
      end

      # Connexion par passkey : niveau 3 d'emblée, sans mot de passe ni TOTP.
      def self.login_passkey(actor : Actor, input : PasskeyAssertionInput) : Result(LoginView)
        Guard.require_module!("AUTH")
        policy = Partiduo::Auth::Policy.current
        return login_failure("auth.errors.login.method_disabled") unless policy.allows?("passkey")

        verified = begin
          verify_assertion(input)
        rescue ex : Partiduo::Auth::Passkeys::Error
          Partiduo::Auth::Audit.record("login.passkey", "FAIL", label: "passkey", ip: input.context.ip, detail: ex.message.to_s)
          return login_failure(ex.key)
        end
        user = verified.user
        unless user.can_sign_in?
          Partiduo::Auth::Audit.record("login.passkey", "FAIL", user: user, ip: input.context.ip, detail: "access_denied")
          return login_failure("auth.errors.login.access_denied")
        end
        authenticated(user, Partiduo::Auth::Levels::PASSKEY, "passkey", "login.passkey", input.context, policy)
      end

      # --- Identité fédérée (SAML ; OIDC pluggable) ---------------------------

      # Fournisseurs actifs, pour l'écran de connexion.
      def self.login_providers(actor : Actor) : Array(IdentityProviderView)
        Guard.require_module!("AUTH")
        return [] of IdentityProviderView unless Partiduo::Auth::Policy.current.allows?("federated")
        Partiduo::Auth::IdentityProvider.filter(active: true).order(:name).map { |provider| provider_view(provider) }
      end

      # Début d'une connexion fédérée : URL du fournisseur et identifiant de
      # requête, que l'interface conserve (cookie) et repasse à `login_federated`.
      def self.begin_federated_login(actor : Actor, provider_code : String) : FederatedStartView
        Guard.require_module!("AUTH")
        provider = active_provider(provider_code)
        adapter = Partiduo::Auth::Federation.adapter(provider.kind.to_s) || raise NotFound.new("identity_provider", provider_code)
        start = adapter.begin_login(provider, Partiduo::Auth::Federation.settings_of(provider))
        issued = Partiduo::Auth::Challenges.issue(FEDERATED_PURPOSE, value: start.request_id, data: provider.code.to_s)
        FederatedStartView.new(start.redirect_url, issued.handle)
      end

      # Retour du fournisseur. L'identité attestée doit correspondre à un
      # utilisateur *déjà créé* (ADR-002 D3) ; ses droits sont locaux.
      def self.login_federated(actor : Actor, provider_code : String, request_id : String,
                               payload : Hash(String, String), context : LoginContext = LoginContext.new) : Result(LoginView)
        Guard.require_module!("AUTH")
        policy = Partiduo::Auth::Policy.current
        return login_failure("auth.errors.login.method_disabled") unless policy.allows?("federated")
        provider = active_provider(provider_code)
        adapter = Partiduo::Auth::Federation.adapter(provider.kind.to_s)
        return login_failure("auth.errors.federated.unsupported") if adapter.nil?

        request = Partiduo::Auth::Challenges.consume(FEDERATED_PURPOSE, request_id)
        if request.nil? || request.data != provider.code
          Partiduo::Auth::Audit.record("login.federated", "FAIL", label: provider_code, ip: context.ip, detail: "request")
          return login_failure("auth.errors.login.expired")
        end

        identity = begin
          adapter.complete_login(provider, Partiduo::Auth::Federation.settings_of(provider), payload, request.value.to_s)
        rescue ex : Partiduo::Auth::Federation::Error
          Partiduo::Auth::Audit.record("login.federated", "FAIL", label: provider_code, ip: context.ip, detail: ex.message.to_s)
          return login_failure(ex.key)
        end

        link = Partiduo::Auth::FederatedIdentity.filter(provider: provider.code, subject: identity.subject).first
        user = link.try(&.user)
        if link.nil? || user.nil?
          Partiduo::Auth::Audit.record("login.federated", "FAIL", label: "#{provider_code}:#{identity.subject}",
            ip: context.ip, detail: "unknown_identity")
          return login_failure("auth.errors.federated.unknown_identity")
        end
        unless user.can_sign_in?
          Partiduo::Auth::Audit.record("login.federated", "FAIL", user: user, ip: context.ip, detail: "access_denied")
          return login_failure("auth.errors.login.access_denied")
        end
        link.last_used_at = Time.utc
        link.save!
        level = (provider.level || Partiduo::Auth::Levels::TWO_FACTOR).to_i32.clamp(1, 3)
        authenticated(user, level, "federated", "login.federated", context, policy)
      end

      # --- Invitation, remise à zéro, déblocage ------------------------------

      # Accepte une invitation : session d'enrôlement (niveau 0, aucun droit)
      # pour enrôler une passkey — proposée en premier — ou définir un mot de
      # passe (ADR-002 D6). Sert aussi à rouvrir l'accès d'un utilisateur
      # bloqué (ADR-002 D7).
      def self.accept_invitation(actor : Actor, token : String, context : LoginContext = LoginContext.new) : Result(LoginView)
        Guard.require_module!("AUTH")
        user = Partiduo::Auth::Tokens.consume("invitation", token)
        return login_failure("auth.errors.token.invalid") if user.nil?
        return login_failure("auth.errors.login.access_denied") unless user.can_sign_in?
        authenticated(user, Partiduo::Auth::Levels::ENROLLMENT, "invitation", "login.invitation", context)
      end

      # Jeton de remise à zéro du mot de passe, à envoyer par courriel par
      # l'interface. `nil` si l'adresse est inconnue — l'interface affiche la
      # même réponse dans les deux cas.
      def self.request_password_reset(actor : Actor, email : String) : TokenView?
        Guard.require_module!("AUTH")
        user = Partiduo::Auth::User.filter(email: normalize_email(email)).first
        return if user.nil? || !user.can_sign_in?
        token_view(user, "password_reset", Partiduo::Auth::Config::RESET_TTL)
      end

      # Nouveau mot de passe par jeton ; lève aussi un blocage (le jeton prouve
      # la maîtrise de l'adresse). Ne touche ni au TOTP ni aux passkeys : si une
      # passkey est active, la connexion par mot de passe exigera toujours le
      # second facteur.
      def self.reset_password(actor : Actor, token : String, new_password : String) : Result(Nil)
        Guard.require_module!("AUTH")
        digest = Partiduo::Auth::Secrets.digest(token)
        record = Partiduo::Auth::Token.filter(digest: digest, purpose: "password_reset", used_at__isnull: true,
          expires_at__gt: Time.utc).first
        return Result(Nil).failure(FieldError.base("auth.errors.token.invalid")) if record.nil?
        user = record.user!
        errors = Partiduo::Auth::Passwords.errors(new_password, "new_password",
          Partiduo::Auth::Passwords.personal_words(user.email.to_s, user.first_name.to_s, user.last_name.to_s))
        return Result(Nil).failure(errors) unless errors.empty?
        return Result(Nil).failure(FieldError.base("auth.errors.token.invalid")) if Partiduo::Auth::Tokens.consume("password_reset", token).nil?

        store_password(user, new_password)
        Partiduo::Auth::Throttle.unlock(user)
        Partiduo::Auth::Sessions.revoke_all(user)
        Partiduo::Auth::Audit.record("password.reset", "SUCCESS", user: user)
        Result(Nil).success(nil)
      end

      # Jeton de déblocage (à envoyer par courriel), pour un compte bloqué.
      def self.request_unlock(actor : Actor, email : String) : TokenView?
        Guard.require_module!("AUTH")
        user = Partiduo::Auth::User.filter(email: normalize_email(email)).first
        return if user.nil? || !user.locked?
        token_view(user, "unlock", Partiduo::Auth::Config::UNLOCK_TTL)
      end

      def self.unlock_with_token(actor : Actor, token : String) : Result(Nil)
        Guard.require_module!("AUTH")
        user = Partiduo::Auth::Tokens.consume("unlock", token)
        return Result(Nil).failure(FieldError.base("auth.errors.token.invalid")) if user.nil?
        Partiduo::Auth::Throttle.unlock(user)
        Partiduo::Auth::Audit.record("account.unlock", "SUCCESS", user: user, detail: "token")
        Result(Nil).success(nil)
      end

      # --- Session ------------------------------------------------------------

      # Acteur du contrat pour un jeton de session : point d'entrée de
      # l'interface à chaque requête. Jeton invalide, expiré ou révoqué :
      # `Actor.anonymous`.
      def self.actor(session_token : String?) : Actor
        session = Partiduo::Auth::Sessions.find(session_token)
        session ? Partiduo::Auth::Sessions.actor(session) : Actor.anonymous
      end

      # Session courante, ou `nil`.
      def self.session(session_token : String?) : SessionView?
        session = Partiduo::Auth::Sessions.find(session_token, touch: false)
        session ? session_view(session) : nil
      end

      def self.logout(actor : Actor, session_token : String) : Nil
        Guard.require_module!("AUTH")
        if session = Partiduo::Auth::Sessions.find(session_token, touch: false)
          Partiduo::Auth::Sessions.revoke(session)
          Partiduo::Auth::Audit.record("logout", "AUDIT", user: session.user)
        end
      end

      # Élévation de la session courante par une passkey de l'utilisateur
      # (niveau 3) — parcours d'élévation, ADR-002 D6.
      def self.elevate_with_passkey(actor : Actor, session_token : String, input : PasskeyAssertionInput) : Result(SessionView)
        Guard.require_module!("AUTH")
        session = Partiduo::Auth::Sessions.find(session_token)
        return Result(SessionView).failure(FieldError.base("auth.errors.login.expired")) if session.nil?
        user = session.user!
        begin
          verify_assertion(input, user)
        rescue ex : Partiduo::Auth::Passkeys::Error
          Partiduo::Auth::Audit.record("session.elevate", "FAIL", user: user, ip: input.context.ip, detail: ex.message.to_s)
          return Result(SessionView).failure(FieldError.base(ex.key))
        end
        raise_level(session, Partiduo::Auth::Levels::PASSKEY, "passkey")
        Result(SessionView).success(session_view(session))
      end

      # Élévation de la session courante par un code TOTP (niveau 2).
      def self.elevate_with_totp(actor : Actor, session_token : String, code : String) : Result(SessionView)
        Guard.require_module!("AUTH")
        session = Partiduo::Auth::Sessions.find(session_token)
        return Result(SessionView).failure(FieldError.base("auth.errors.login.expired")) if session.nil?
        user = session.user!
        if wait = Partiduo::Auth::Throttle.retry_after(user)
          return Result(SessionView).failure(FieldError.base("auth.errors.login.throttled", {"seconds" => wait.total_seconds.ceil.to_i.to_s}))
        end
        return Result(SessionView).failure(FieldError.base("auth.errors.login.locked")) if user.locked?
        unless Partiduo::Auth::Totp.verify!(user, code)
          Partiduo::Auth::Throttle.record_failure(user)
          Partiduo::Auth::Audit.record("session.elevate", "FAIL", user: user, detail: "totp")
          return Result(SessionView).failure(FieldError.new("code", "auth.errors.login.invalid_code"))
        end
        Partiduo::Auth::Throttle.record_success(user)
        raise_level(session, Partiduo::Auth::Levels::TWO_FACTOR, "totp")
        Result(SessionView).success(session_view(session))
      end

      # --- Règles de mot de passe ---------------------------------------------

      def self.password_policy(actor : Actor) : PasswordPolicyView
        Guard.require_module!("AUTH")
        policy = Partiduo::Auth::Config.password_policy
        PasswordPolicyView.new(
          minimum_length: policy.minimum_length,
          maximum_bytes: policy.maximum_bytesize,
          require_uppercase: policy.require_uppercase?,
          require_lowercase: policy.require_lowercase?,
          require_digit: policy.require_digit?,
          require_special: policy.require_special?,
          entropy_bits: policy.entropy,
        )
      end

      # Requête de contrôle : même règle que les commandes qui enregistrent un
      # mot de passe, pour un retour instantané de l'interface.
      def self.check_password(actor : Actor, password : String, email : String = "",
                              first_name : String = "", last_name : String = "") : Result(Nil)
        Guard.require_module!("AUTH")
        errors = Partiduo::Auth::Passwords.errors(password, "password",
          Partiduo::Auth::Passwords.personal_words(email, first_name, last_name))
        errors.empty? ? Result(Nil).success(nil) : Result(Nil).failure(errors)
      end

      # --- Aides internes -----------------------------------------------------

      private def self.normalize_email(email : String) : String
        email.strip.downcase
      end

      private def self.login_failure(key : String, params : Hash(String, String) = {} of String => String) : Result(LoginView)
        Result(LoginView).failure(FieldError.base(key, params))
      end

      # Refus sans examen du secret : compte bloqué, ou temporisation en cours.
      private def self.throttled(user : Partiduo::Auth::User, action : String, context : LoginContext) : Result(LoginView)?
        if user.locked?
          Partiduo::Auth::Audit.record(action, "FAIL", user: user, ip: context.ip, detail: "locked")
          return login_failure("auth.errors.login.locked")
        end
        if wait = Partiduo::Auth::Throttle.retry_after(user)
          Partiduo::Auth::Audit.record(action, "FAIL", user: user, ip: context.ip, detail: "throttled")
          return login_failure("auth.errors.login.throttled", {"seconds" => wait.total_seconds.ceil.to_i.to_s})
        end
        nil
      end

      private def self.failed_attempt(user : Partiduo::Auth::User, action : String, key : String,
                                      context : LoginContext, field : String = FieldError::BASE) : Result(LoginView)
        count = Partiduo::Auth::Throttle.record_failure(user)
        Partiduo::Auth::Audit.record(action, "FAIL", user: user, ip: context.ip, detail: "attempt #{count}")
        if user.locked?
          Partiduo::Auth::Audit.record("account.lock", "FAIL", user: user, ip: context.ip, detail: "#{count} échecs")
          return login_failure("auth.errors.login.locked")
        end
        Result(LoginView).failure(FieldError.new(field, key))
      end

      # Mot de passe insuffisant seul : TOTP actif, ou passkey active
      # (ADR-002 D6 : sinon le repli affaiblirait ce qu'on vient de renforcer).
      private def self.second_factor_needed?(user : Partiduo::Auth::User) : Bool
        user.totp_enabled? || Partiduo::Auth::Passkey.filter(user_id: user.pk).exists?
      end

      private def self.second_factors(user : Partiduo::Auth::User) : Array(String)
        factors = [] of String
        factors << "totp" if user.totp_enabled?
        factors << "recovery_code" if Partiduo::Auth::RecoveryCodes.remaining(user) > 0
        factors
      end

      private def self.authenticated(user : Partiduo::Auth::User, level : Int32, method : String, action : String,
                                     context : LoginContext, policy = Partiduo::Auth::Policy.current) : Result(LoginView)
        Partiduo::Auth::Throttle.record_success(user) if level > Partiduo::Auth::Levels::ENROLLMENT
        opened = Partiduo::Auth::Sessions.open(user, level, method, context.ip, context.user_agent)
        required = Partiduo::Auth::Levels.required(user, policy)
        Partiduo::Auth::Audit.record(action, "SUCCESS", user: user, ip: context.ip, detail: "#{method}, niveau #{level}")
        Result(LoginView).success(LoginView.new(
          status: "authenticated",
          user_id: user.pk!.as(Int64),
          session_token: opened.token,
          level: level,
          required_level: required,
          elevation_required: level < required,
          suggest_passkey: level < Partiduo::Auth::Levels::PASSKEY && Partiduo::Auth::Levels.suggest_passkey?(user, policy),
        ))
      end

      private def self.raise_level(session : Partiduo::Auth::Session, level : Int32, method : String) : Nil
        user = session.user!
        if level > (session.level || 0).to_i32
          session.level = level
          session.method = method
          session.save!
        end
        Partiduo::Auth::Audit.record("session.elevate", "SUCCESS", user: user, detail: "#{method}, niveau #{session.level}")
      end

      private def self.verify_assertion(input : PasskeyAssertionInput, expected : Partiduo::Auth::User? = nil) : Partiduo::Auth::Passkeys::Verified
        Partiduo::Auth::Passkeys.finish_authentication(
          handle: input.challenge_id,
          credential_id: input.credential_id,
          authenticator_data: input.authenticator_data,
          client_data_json: input.client_data_json,
          signature: input.signature,
          user_handle: input.user_handle,
          expected_user: expected,
        )
      end

      private def self.active_provider(code : String) : Partiduo::Auth::IdentityProvider
        Partiduo::Auth::IdentityProvider.filter(code: code, active: true).first || raise NotFound.new("identity_provider", code)
      end

      private def self.token_view(user : Partiduo::Auth::User, purpose : String, ttl : Time::Span) : TokenView
        token, raw = Partiduo::Auth::Tokens.issue(user, purpose, ttl)
        TokenView.new(user.pk!.as(Int64), purpose, raw, token.expires_at!)
      end

      private def self.store_password(user : Partiduo::Auth::User, password : String) : Nil
        user.password = Partiduo::Auth::Passwords.hash(password)
        user.password_changed_at = Time.utc
        user.save!
      end

      private def self.session_view(session : Partiduo::Auth::Session) : SessionView
        user = session.user!
        policy = Partiduo::Auth::Policy.current
        level = (session.level || 0).to_i32
        required = Partiduo::Auth::Levels.required(user, policy)
        SessionView.new(
          user_id: user.pk!.as(Int64),
          email: user.email.to_s,
          full_name: user.full_name,
          locale: user.locale.to_s,
          role: user.role.to_s,
          method: session.method.to_s,
          level: level,
          required_level: required,
          elevation_required: level < required,
          suggest_passkey: level < Partiduo::Auth::Levels::PASSKEY && Partiduo::Auth::Levels.suggest_passkey?(user, policy),
          expires_at: session.expires_at!,
        )
      end

      private def self.provider_view(provider : Partiduo::Auth::IdentityProvider) : IdentityProviderView
        IdentityProviderView.new(provider.code.to_s, provider.kind.to_s, provider.name.to_s,
          (provider.level || 2).to_i32, provider.active == true)
      end
    end
  end
end
