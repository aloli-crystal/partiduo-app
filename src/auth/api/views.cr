# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    # Contrat de l'authentification et des droits (ADR-002, ADR-003 D4) :
    # objets de vue et entrées. Les commandes et requêtes sont dans
    # `auth_*.cr` ; la référence est `doc/api/auth.adoc`.
    module Auth
      # Contexte d'une tentative de connexion, fourni par l'interface et
      # consigné dans le journal d'audit.
      # La session de l'acteur n'a pas le niveau qu'exige l'opération
      # (ADR-002 D6) : l'interface propose l'élévation (passkey ou TOTP).
      class ElevationRequired < AccessDenied
        getter level : Int32

        def initialize(@level : Int32)
          super("session de niveau #{@level} requise")
        end

        def key : String
          "auth.errors.elevation_required"
        end
      end

      record LoginContext, ip : String = "", user_agent : String = ""

      # Issue d'une étape de connexion.
      #
      # * `status` : `authenticated` (session ouverte, `session_token`) ou
      #   `second_factor_required` (mot de passe correct ; `pending_token` à
      #   repasser avec le code, `second_factors` : `totp`, `recovery_code`) ;
      # * `elevation_required` : la session est ouverte mais son niveau est
      #   inférieur à `required_level` — l'utilisateur n'a *aucun droit* tant
      #   qu'il n'a pas élevé sa session (ADR-002 D6) ;
      # * `suggest_passkey` : inviter à enrôler une passkey.
      record LoginView,
        status : String,
        user_id : Int64,
        session_token : String? = nil,
        pending_token : String? = nil,
        second_factors : Array(String) = [] of String,
        level : Int32 = 0,
        required_level : Int32 = 1,
        elevation_required : Bool = false,
        suggest_passkey : Bool = false do
        def authenticated? : Bool
          status == "authenticated"
        end

        # Jeton de session ; lève si l'étape n'a pas ouvert de session.
        def session_token! : String
          session_token || raise NilAssertionError.new("aucune session ouverte (#{status})")
        end

        # Jeton de second facteur ; lève si aucun second facteur n'est attendu.
        def pending_token! : String
          pending_token || raise NilAssertionError.new("aucun second facteur attendu (#{status})")
        end
      end

      # Session courante, vue de l'interface.
      record SessionView,
        user_id : Int64,
        email : String,
        full_name : String,
        locale : String,
        role : String,
        method : String,
        level : Int32,
        required_level : Int32,
        elevation_required : Bool,
        suggest_passkey : Bool,
        expires_at : Time

      record PasskeyView,
        id : Int64,
        name : String,
        created_at : Time?,
        last_used_at : Time?,
        backup_eligible : Bool,
        backup_state : Bool,
        transports : Array(String)

      # Page « sécurité du compte » (ADR-002 D6) : niveau que les méthodes
      # enrôlées permettent d'atteindre, niveau exigé, et ce qui manque pour
      # monter (`totp`, `passkey`, `recovery_codes`).
      record SecurityView,
        user_id : Int64,
        achievable_level : Int32,
        session_level : Int32,
        required_level : Int32,
        methods : Array(String),
        missing : Array(String),
        passkeys : Array(PasskeyView),
        recovery_codes_remaining : Int32,
        suggest_passkey : Bool,
        has_password : Bool

      # Règles de mot de passe, pour l'aide à la saisie.
      record PasswordPolicyView,
        minimum_length : Int32,
        maximum_bytes : Int32,
        require_uppercase : Bool,
        require_lowercase : Bool,
        require_digit : Bool,
        require_special : Bool,
        entropy_bits : Float64

      # QR code : `modules[y][x]` vrai pour un module sombre, sans la zone de
      # silence (quatre modules clairs à ajouter autour).
      record QrCodeView, size : Int32, modules : Array(Array(Bool))

      # Enrôlement TOTP (ADR-002) : QR code *et* secret base32 pour une saisie
      # manuelle ; paramètres de la RFC 6238 (SHA-1, 6 chiffres, 30 s).
      record TotpEnrollmentView,
        secret_base32 : String,
        provisioning_uri : String,
        qr_code : QrCodeView,
        issuer : String,
        account : String,
        algorithm : String,
        digits : Int32,
        period : Int32

      # Codes de récupération, affichés une seule fois.
      record RecoveryCodesView, codes : Array(String)

      record PasskeyEnrollmentView, passkey : PasskeyView, recovery_codes : Array(String)

      # Options de `navigator.credentials.create()`. Octets en base64url.
      record RegistrationOptionsView,
        challenge_id : String,
        challenge : String,
        rp_id : String,
        rp_name : String,
        user_handle : String,
        user_name : String,
        user_display_name : String,
        algorithms : Array(Int64),
        resident_key : String,
        user_verification : String,
        attestation : String,
        timeout_ms : Int32,
        exclude_credentials : Array(String)

      # Options de `navigator.credentials.get()`. `allow_credentials` vide :
      # credential découvrable, sans identifiant saisi.
      record AuthenticationOptionsView,
        challenge_id : String,
        challenge : String,
        rp_id : String,
        user_verification : String,
        timeout_ms : Int32,
        allow_credentials : Array(String)

      record FederatedStartView, redirect_url : String, request_id : String

      record IdentityProviderView, code : String, kind : String, name : String, level : Int32, active : Bool

      record FederatedIdentityView, id : Int64, provider : String, subject : String, last_used_at : Time?

      # Jeton à transmettre hors bande (courriel), en clair une seule fois.
      # Jeton à remettre hors bande. `email` : adresse *enregistrée* de
      # l'utilisateur, seule destinataire admise du courriel ; `locale` : sa
      # langue ; `domain` : nom d'hôte configuré de l'instance (celui du lien,
      # jamais l'en-tête `Host` de la requête) ; `country_code` : pays de la
      # société (présentation des dates).
      record TokenView, user_id : Int64, purpose : String, token : String, expires_at : Time,
        email : String = "", locale : String = "fr", domain : String = "", country_code : String = ""

      record UserView,
        id : Int64,
        email : String,
        first_name : String,
        last_name : String,
        full_name : String,
        locale : String,
        role : String,
        profile_id : Int64?,
        active : Bool,
        revoked : Bool,
        access_ends_on : Time?,
        locked : Bool,
        failed_attempts : Int32,
        has_password : Bool,
        totp_enabled : Bool,
        passkey_count : Int32,
        ledger_security : Bool,
        last_login_at : Time?

      # Utilisateur créé, avec son jeton d'invitation : la passkey est
      # proposée en premier, le mot de passe en repli (ADR-002 D6).
      record UserCreatedView, user : UserView, invitation : TokenView

      record ProfileView,
        id : Int64,
        code : String,
        name : String,
        description : String,
        admin : Bool,
        permissions : Array(String)

      record LedgerAccessView, ledger_id : Int64, access : String

      record AuditEventView,
        id : Int64,
        user_id : Int64?,
        user_label : String,
        action : String,
        module_code : String,
        state : String,
        ip : String,
        detail : String,
        created_at : Time?

      # --- Entrées -----------------------------------------------------------

      record PasswordLoginInput, email : String, password : String, context : LoginContext = LoginContext.new

      # `kind` : `totp` ou `recovery_code`.
      record SecondFactorInput, pending_token : String, code : String, kind : String = "totp",
        context : LoginContext = LoginContext.new

      # Réponse de `navigator.credentials.create()`, octets en base64url.
      record PasskeyRegistrationInput,
        challenge_id : String,
        attestation_object : String,
        client_data_json : String,
        transports : Array(String) = [] of String,
        name : String = ""

      # Réponse de `navigator.credentials.get()`, octets en base64url.
      record PasskeyAssertionInput,
        challenge_id : String,
        credential_id : String,
        authenticator_data : String,
        client_data_json : String,
        signature : String,
        user_handle : String? = nil,
        context : LoginContext = LoginContext.new

      record UserInput,
        email : String,
        first_name : String = "",
        last_name : String = "",
        locale : String = "fr",
        role : String = "member",
        profile_id : Int64? = nil,
        access_ends_on : Time? = nil,
        password : String? = nil

      record ChangePasswordInput, new_password : String, current_password : String? = nil

      record ProfileInput,
        name : String,
        description : String = "",
        admin : Bool = false,
        permissions : Array(String) = [] of String

      # `kind` : `saml` ou un type enregistré par `Partiduo::Auth::Federation`.
      record IdentityProviderInput,
        code : String,
        kind : String,
        name : String,
        level : Int32 = 2,
        active : Bool = true,
        settings : Hash(String, String) = {} of String => String

      record AuditQuery, user_id : Int64? = nil, module_code : String? = nil, state : String? = nil, limit : Int32 = 100
    end
  end
end
