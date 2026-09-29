# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    # Administration : utilisateurs et rôle `comptable` (ADR-002 D4), profils
    # et permissions (ADR-003 D4), droits par journal, fournisseurs
    # d'identité (D3), journal d'audit.
    module Auth
      EMAIL_FORMAT = /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/
      CODE_FORMAT  = /\A[a-z0-9][a-z0-9_-]{0,63}\z/

      # --- Utilisateurs ----------------------------------------------------------

      def self.users(actor : Actor) : Array(UserView)
        Guard.authorize!(actor, "auth.users.manage", module_code: "AUTH")
        Partiduo::Auth::User.all.order(:email).map { |user| user_view(user) }
      end

      def self.user(actor : Actor, id : Int64) : UserView
        Guard.authorize!(actor, "auth.users.manage", module_code: "AUTH")
        user_view(find_user(id))
      end

      # Utilisateur par adresse (casse et espaces ignorés), ou `nil`.
      def self.user_by_email(actor : Actor, email : String) : UserView?
        Guard.authorize!(actor, "auth.users.manage", module_code: "AUTH")
        Partiduo::Auth::User.filter(email: normalize_email(email)).first.try { |user| user_view(user) }
      end

      # Crée un utilisateur et son jeton d'invitation. Sans mot de passe, le
      # compte n'en a pas : l'invitation mène à l'enrôlement d'une passkey,
      # proposée en premier, ou d'un mot de passe (ADR-002 D6). Un compte
      # `comptable` est nominatif : prénom et nom obligatoires.
      def self.create_user(actor : Actor, input : UserInput) : Result(UserCreatedView)
        Guard.authorize!(actor, "auth.users.manage", module_code: "AUTH")
        errors = user_errors(input, nil)
        return Result(UserCreatedView).failure(errors) unless errors.empty?

        Transaction.run do
          user = Partiduo::Auth::User.new(email: normalize_email(input.email))
          assign_user(user, input)
          if password = input.password.presence
            user.password = Partiduo::Auth::Passwords.hash(password)
            user.password_changed_at = Time.utc
          else
            user.set_unusable_password
          end
          user.save!
          invitation = token_view(user, "invitation", Partiduo::Auth::Config::INVITATION_TTL)
          Partiduo::Auth::Audit.record_for(actor, "user.create", "ADMIN", detail: "#{user.email} (#{user.role})")
          Result(UserCreatedView).success(UserCreatedView.new(user_view(user), invitation))
        end
      end

      # Modifie un utilisateur. Un changement de rôle ou de profil coupe ses
      # sessions : les droits se recalculent à la prochaine connexion.
      def self.update_user(actor : Actor, id : Int64, input : UserInput) : Result(UserView)
        Guard.authorize!(actor, "auth.users.manage", module_code: "AUTH")
        user = find_user(id)
        errors = user_errors(input, user)
        return Result(UserView).failure(errors) unless errors.empty?

        Transaction.run do
          rights_changed = user.role != input.role || user.profile_id != input.profile_id
          email = normalize_email(input.email)
          # Droits, adresse (où partent les liens de remise à zéro) ou mot de
          # passe changés : toutes les sessions de l'utilisateur sont coupées.
          security_changed = rights_changed || user.email != email || !input.password.presence.nil?
          user.email = email
          assign_user(user, input)
          if password = input.password.presence
            user.password = Partiduo::Auth::Passwords.hash(password)
            user.password_changed_at = Time.utc
          end
          user.save!
          Partiduo::Auth::Sessions.revoke_all(user) if security_changed
          Partiduo::Auth::Audit.record_for(actor, "user.update", "ADMIN", detail: user.email.to_s)
          Result(UserView).success(user_view(user))
        end
      end

      # Révocation immédiate (ADR-002 D4) : toutes les sessions sont coupées,
      # dans cette instance seulement.
      def self.revoke_access(actor : Actor, id : Int64) : Result(UserView)
        Guard.authorize!(actor, "auth.users.manage", module_code: "AUTH")
        user = find_user(id)
        if actor.user_id == user.pk
          return Result(UserView).failure(FieldError.base("auth.errors.user.self"))
        end
        Transaction.run do
          user.revoked_at = Time.utc
          user.save!
          Partiduo::Auth::Sessions.revoke_all(user)
          Partiduo::Auth::Audit.record_for(actor, "user.revoke", "ADMIN", detail: user.audit_label)
          Result(UserView).success(user_view(user))
        end
      end

      # Rouvre l'accès, avec une nouvelle date de fin éventuelle.
      def self.restore_access(actor : Actor, id : Int64, access_ends_on : Time? = nil) : Result(UserView)
        Guard.authorize!(actor, "auth.users.manage", module_code: "AUTH")
        user = find_user(id)
        if (ends = access_ends_on) && ends < Time.utc.at_beginning_of_day
          return Result(UserView).failure(FieldError.new("access_ends_on", "auth.errors.user.access_ends_on_past"))
        end
        Transaction.run do
          user.revoked_at = nil
          user.access_ends_on = access_ends_on.try(&.at_beginning_of_day)
          user.save!
          Partiduo::Auth::Audit.record_for(actor, "user.restore", "ADMIN", detail: user.audit_label)
          Result(UserView).success(user_view(user))
        end
      end

      # Débloque un compte bloqué après dix échecs.
      def self.unlock_user(actor : Actor, id : Int64) : Result(UserView)
        Guard.authorize!(actor, "auth.users.manage", module_code: "AUTH")
        user = find_user(id)
        Partiduo::Auth::Throttle.unlock(user)
        Partiduo::Auth::Audit.record_for(actor, "user.unlock", "ADMIN", detail: user.audit_label)
        Result(UserView).success(user_view(user))
      end

      # Nouvelle invitation : rouvre l'accès d'un utilisateur qui a perdu ses
      # moyens d'authentification (ADR-002 D7 — l'autorisation étant locale, la
      # société n'a besoin de personne d'autre).
      def self.issue_invitation(actor : Actor, id : Int64) : TokenView
        Guard.authorize!(actor, "auth.users.manage", module_code: "AUTH")
        user = find_user(id)
        Partiduo::Auth::Audit.record_for(actor, "user.invite", "ADMIN", detail: user.audit_label)
        token_view(user, "invitation", Partiduo::Auth::Config::INVITATION_TTL)
      end

      # --- Droits par journal (héritiers de user_sec_jrn) ----------------------

      def self.set_ledger_security(actor : Actor, user_id : Int64, enabled : Bool) : Result(UserView)
        Guard.authorize!(actor, "auth.users.manage", module_code: "AUTH")
        user = find_user(user_id)
        user.ledger_security = enabled
        user.save!
        Partiduo::Auth::Audit.record_for(actor, "user.ledger_security", "ADMIN", detail: "#{user.email} : #{enabled}")
        Result(UserView).success(user_view(user))
      end

      # `access` : `W` (écriture), `R` (lecture), `X` (aucun accès).
      def self.set_ledger_access(actor : Actor, user_id : Int64, ledger_id : Int64, access : String) : Result(LedgerAccessView)
        Guard.authorize!(actor, "auth.users.manage", module_code: "AUTH")
        user = find_user(user_id)
        value = access.upcase
        unless Partiduo::Auth::LedgerAccess::ACCESSES.includes?(value)
          return Result(LedgerAccessView).failure(FieldError.new("access", "auth.errors.ledger.access_invalid"))
        end
        row = Partiduo::Auth::Ledgers.set(user, ledger_id, value)
        Partiduo::Auth::Audit.record_for(actor, "user.ledger_access", "ADMIN", detail: "#{user.email} : #{ledger_id} = #{value}")
        Result(LedgerAccessView).success(LedgerAccessView.new(row.ledger_id!.to_i64, row.access.to_s))
      end

      def self.ledger_accesses(actor : Actor, user_id : Int64) : Array(LedgerAccessView)
        Guard.authorize!(actor, "auth.users.manage", module_code: "AUTH")
        user = find_user(user_id)
        Partiduo::Auth::LedgerAccess.filter(user_id: user.pk).order(:ledger_id).map do |row|
          LedgerAccessView.new(row.ledger_id!.to_i64, row.access.to_s)
        end
      end

      # Droit effectif d'un utilisateur sur un journal.
      def self.user_ledger_access(actor : Actor, user_id : Int64, ledger_id : Int64) : String
        Guard.authorize!(actor, "auth.users.manage", module_code: "AUTH")
        Partiduo::Auth::Ledgers.access(find_user(user_id), ledger_id)
      end

      # --- Identités fédérées ----------------------------------------------------

      # Ouvre l'accès fédéré d'un utilisateur existant (ADR-002 D3) : c'est la
      # société qui déclare quelle identité externe correspond à quel compte.
      def self.link_federated_identity(actor : Actor, user_id : Int64, provider_code : String,
                                       subject : String) : Result(FederatedIdentityView)
        Guard.authorize!(actor, "auth.users.manage", module_code: "AUTH")
        user = find_user(user_id)
        subject = subject.strip
        errors = [] of FieldError
        unless Partiduo::Auth::IdentityProvider.filter(code: provider_code).exists?
          errors << FieldError.new("provider", "auth.errors.provider.unknown")
        end
        errors << FieldError.new("subject", "auth.errors.federated.subject_required") if subject.empty?
        if Partiduo::Auth::FederatedIdentity.filter(provider: provider_code, subject: subject).exists?
          errors << FieldError.new("subject", "auth.errors.federated.subject_taken")
        end
        return Result(FederatedIdentityView).failure(errors) unless errors.empty?

        Transaction.run do
          link = Partiduo::Auth::FederatedIdentity.create!(user: user, provider: provider_code, subject: subject)
          Partiduo::Auth::Audit.record_for(actor, "user.federated.link", "ADMIN", detail: "#{user.email} : #{provider_code}")
          Result(FederatedIdentityView).success(federated_view(link))
        end
      end

      def self.unlink_federated_identity(actor : Actor, id : Int64) : Result(Nil)
        Guard.authorize!(actor, "auth.users.manage", module_code: "AUTH")
        link = Partiduo::Auth::FederatedIdentity.get(id: id) || raise NotFound.new("federated_identity", id)
        link.delete
        Partiduo::Auth::Audit.record_for(actor, "user.federated.unlink", "ADMIN", detail: "#{link.provider}:#{link.subject}")
        Result(Nil).success(nil)
      end

      def self.federated_identities(actor : Actor, user_id : Int64) : Array(FederatedIdentityView)
        Guard.authorize!(actor, "auth.users.manage", module_code: "AUTH")
        Partiduo::Auth::FederatedIdentity.filter(user_id: find_user(user_id).pk).map { |link| federated_view(link) }
      end

      # --- Profils -----------------------------------------------------------------

      def self.profiles(actor : Actor) : Array(ProfileView)
        Guard.authorize!(actor, "auth.profiles.manage", module_code: "AUTH")
        Partiduo::Auth::Profile.all.order(:name).map { |profile| profile_view(profile) }
      end

      def self.profile(actor : Actor, id : Int64) : ProfileView
        Guard.authorize!(actor, "auth.profiles.manage", module_code: "AUTH")
        profile_view(find_profile(id))
      end

      def self.create_profile(actor : Actor, input : ProfileInput) : Result(ProfileView)
        Guard.authorize!(actor, "auth.profiles.manage", module_code: "AUTH")
        errors = profile_errors(input, nil)
        return Result(ProfileView).failure(errors) unless errors.empty?
        Transaction.run do
          profile = Partiduo::Auth::Profile.create!(name: input.name.strip, description: input.description, admin: input.admin)
          store_permissions(profile, input.permissions)
          Partiduo::Auth::Audit.record_for(actor, "profile.create", "ADMIN", detail: profile.name.to_s)
          Result(ProfileView).success(profile_view(profile))
        end
      end

      def self.update_profile(actor : Actor, id : Int64, input : ProfileInput) : Result(ProfileView)
        Guard.authorize!(actor, "auth.profiles.manage", module_code: "AUTH")
        profile = find_profile(id)
        errors = profile_errors(input, profile)
        return Result(ProfileView).failure(errors) unless errors.empty?
        Transaction.run do
          profile.name = input.name.strip
          profile.description = input.description
          profile.admin = input.admin
          profile.save!
          store_permissions(profile, input.permissions)
          Partiduo::Auth::Audit.record_for(actor, "profile.update", "ADMIN", detail: profile.name.to_s)
          Result(ProfileView).success(profile_view(profile))
        end
      end

      def self.delete_profile(actor : Actor, id : Int64) : Result(Nil)
        Guard.authorize!(actor, "auth.profiles.manage", module_code: "AUTH")
        profile = find_profile(id)
        if Partiduo::Auth::User.filter(profile_id: profile.pk).exists?
          return Result(Nil).failure(FieldError.base("auth.errors.profile.in_use"))
        end
        Transaction.run do
          profile.delete
          Partiduo::Auth::Audit.record_for(actor, "profile.delete", "ADMIN", detail: profile.name.to_s)
          Result(Nil).success(nil)
        end
      end

      # Profils par défaut, créés s'ils manquent (provisionnement) :
      # administrateur (toutes les permissions), comptable (toutes les
      # permissions non administratives déclarées) et comptable invité en
      # lecture (ADR-006 D4 : consultation et transmission au comptable,
      # permissions `*.read` non administratives, D-GUEST-001).
      def self.ensure_default_profiles(actor : Actor) : Array(ProfileView)
        Guard.authorize!(actor, "auth.profiles.manage", module_code: "AUTH")
        admin = Partiduo::Auth::Profile.filter(code: "ADMIN").first ||
                Partiduo::Auth::Profile.create!(code: "ADMIN", name: I18n.t("auth.profiles.admin"), admin: true)
        names = Partiduo::Modules.manifests.values.flat_map(&.permissions)
          .reject { |name| Partiduo::Auth::Permissions.administrative?(name) }
        accountant = Partiduo::Auth::Profile.filter(code: "ACCOUNTANT").first
        if accountant.nil?
          accountant = Partiduo::Auth::Profile.create!(code: "ACCOUNTANT", name: I18n.t("auth.profiles.accountant"), admin: false)
          store_permissions(accountant, names)
        end
        guest = Partiduo::Auth::Profile.filter(code: GUEST_PROFILE).first
        if guest.nil?
          guest = Partiduo::Auth::Profile.create!(code: GUEST_PROFILE, name: I18n.t("auth.profiles.accountant_guest"),
            description: I18n.t("auth.profiles.accountant_guest_description"), admin: false)
          store_permissions(guest, names.select { |name| read_only_permission?(name) })
        end
        [profile_view(admin), profile_view(accountant), profile_view(guest)]
      end

      # Profil du comptable invité en lecture (ADR-006 D4).
      GUEST_PROFILE = "ACCOUNTANT_GUEST"

      # Permission de lecture : consultation, éditions, exports.
      def self.read_only_permission?(name : String) : Bool
        name.ends_with?(".read")
      end

      # --- Fournisseurs d'identité ------------------------------------------------

      def self.identity_providers(actor : Actor) : Array(IdentityProviderView)
        Guard.authorize!(actor, "auth.providers.manage", module_code: "AUTH")
        Partiduo::Auth::IdentityProvider.all.order(:code).map { |provider| provider_view(provider) }
      end

      # Types de fournisseurs enregistrés et leurs paramètres (écrans).
      def self.identity_provider_kinds(actor : Actor) : Array(ProviderKindView)
        Guard.authorize!(actor, "auth.providers.manage", module_code: "AUTH")
        Partiduo::Auth::Federation.kinds.sort.compact_map do |kind|
          adapter = Partiduo::Auth::Federation.adapter(kind) || next
          fields = adapter.settings_schema.map do |field|
            ProviderSettingView.new(field.key, field.required, field.secret, field.multiline)
          end
          ProviderKindView.new(kind, fields)
        end
      end

      # Un fournisseur, pour le modifier : les secrets ne sont jamais rendus.
      def self.identity_provider(actor : Actor, code : String) : IdentityProviderDetailView
        Guard.authorize!(actor, "auth.providers.manage", module_code: "AUTH")
        provider = Partiduo::Auth::IdentityProvider.filter(code: code).first || raise NotFound.new("identity_provider", code)
        settings = Partiduo::Auth::Federation.settings_of(provider)
        secrets = secret_keys(provider.kind.to_s)
        IdentityProviderDetailView.new(
          code: provider.code.to_s, kind: provider.kind.to_s, name: provider.name.to_s,
          level: (provider.level || 2).to_i32, active: provider.active == true,
          settings: settings.reject { |key, _| secrets.includes?(key) },
          secrets_set: secrets.select { |key| settings[key]?.presence },
          linked_identities: Partiduo::Auth::FederatedIdentity.filter(provider: provider.code).count.to_i32,
        )
      end

      # Crée ou met à jour (par `code`) un fournisseur d'identité. Un
      # paramètre secret laissé vide garde la valeur enregistrée (il n'est
      # jamais réaffiché) ; le type d'un fournisseur existant ne change pas.
      def self.save_identity_provider(actor : Actor, input : IdentityProviderInput) : Result(IdentityProviderView)
        Guard.authorize!(actor, "auth.providers.manage", module_code: "AUTH")
        existing = Partiduo::Auth::IdentityProvider.filter(code: input.code).first
        input = input.copy_with(settings: kept_secrets(input, existing)) if existing
        errors = [] of FieldError
        if existing && existing.kind != input.kind
          errors << FieldError.new("kind", "auth.errors.provider.kind_immutable")
        end
        errors << FieldError.new("code", "auth.errors.provider.code_invalid") unless input.code.matches?(CODE_FORMAT)
        errors << FieldError.new("name", "auth.errors.provider.required") if input.name.strip.empty?
        errors << FieldError.new("level", "auth.errors.provider.level_invalid") unless 1 <= input.level <= 3
        if adapter = Partiduo::Auth::Federation.adapter(input.kind)
          errors.concat(adapter.validate_settings(input.settings))
        else
          errors << FieldError.new("kind", "auth.errors.provider.kind_unsupported")
        end
        return Result(IdentityProviderView).failure(errors) unless errors.empty?

        Transaction.run do
          provider = Partiduo::Auth::IdentityProvider.filter(code: input.code).first ||
                     Partiduo::Auth::IdentityProvider.new(code: input.code)
          provider.kind = input.kind
          provider.name = input.name.strip
          provider.level = input.level
          provider.active = input.active
          provider.settings = input.settings.to_json
          provider.save!
          Partiduo::Auth::Audit.record_for(actor, "provider.save", "ADMIN", detail: input.code)
          Result(IdentityProviderView).success(provider_view(provider))
        end
      end

      private def self.secret_keys(kind : String) : Array(String)
        Partiduo::Auth::Federation.adapter(kind).try(&.settings_schema.select(&.secret).map(&.key)) || [] of String
      end

      # Paramètres saisis, secrets vides remplacés par ceux enregistrés ;
      # valeurs saisies nettoyées des espaces (sauf sur plusieurs lignes).
      private def self.kept_secrets(input : IdentityProviderInput, existing : Partiduo::Auth::IdentityProvider) : Hash(String, String)
        stored = Partiduo::Auth::Federation.settings_of(existing)
        settings = input.settings.dup
        secret_keys(input.kind).each do |key|
          if settings[key]?.to_s.strip.empty? && (value = stored[key]?.presence)
            settings[key] = value
          end
        end
        settings
      end

      # --- Journal d'audit ---------------------------------------------------------

      def self.audit_events(actor : Actor, query : AuditQuery = AuditQuery.new) : Array(AuditEventView)
        Guard.authorize!(actor, "auth.audit.view", module_code: "AUTH")
        events = Partiduo::Auth::AuditEvent.all
        if user_id = query.user_id
          events = events.filter(actor_id: user_id)
        end
        if module_code = query.module_code
          events = events.filter(module_code: module_code)
        end
        if state = query.state
          events = events.filter(state: state)
        end
        events.order("-id")[0...query.limit.clamp(1, 1000)].to_a.map do |event|
          AuditEventView.new(
            id: event.pk!.as(Int64),
            user_id: event.actor_id.try(&.to_i64),
            user_label: event.user_label.to_s,
            action: event.action.to_s,
            module_code: event.module_code.to_s,
            state: event.state.to_s,
            ip: event.ip.to_s,
            detail: event.detail.to_s,
            created_at: event.created_at,
          )
        end
      end

      # --- Aides internes -------------------------------------------------------

      private def self.find_user(id : Int64) : Partiduo::Auth::User
        Partiduo::Auth::User.get(id: id) || raise NotFound.new("user", id)
      end

      private def self.find_profile(id : Int64) : Partiduo::Auth::Profile
        Partiduo::Auth::Profile.get(id: id) || raise NotFound.new("profile", id)
      end

      private def self.assign_user(user : Partiduo::Auth::User, input : UserInput) : Nil
        user.first_name = input.first_name.strip
        user.last_name = input.last_name.strip
        user.locale = input.locale
        user.role = input.role
        user.profile_id = input.profile_id
        user.access_ends_on = input.access_ends_on.try(&.at_beginning_of_day)
      end

      private def self.user_errors(input : UserInput, existing : Partiduo::Auth::User?) : Array(FieldError)
        errors = email_errors(normalize_email(input.email), existing)
        errors.concat(identity_errors(input))
        if (profile_id = input.profile_id) && !Partiduo::Auth::Profile.filter(id: profile_id).exists?
          errors << FieldError.new("profile_id", "auth.errors.user.profile_unknown")
        end
        if (ends = input.access_ends_on) && ends < Time.utc.at_beginning_of_day &&
           (existing.nil? || existing.access_ends_on != ends.at_beginning_of_day)
          errors << FieldError.new("access_ends_on", "auth.errors.user.access_ends_on_past")
        end
        if password = input.password.presence
          errors.concat(Partiduo::Auth::Passwords.errors(password, "password",
            Partiduo::Auth::Passwords.personal_words(input.email, input.first_name, input.last_name)))
        end
        errors
      end

      private def self.email_errors(email : String, existing : Partiduo::Auth::User?) : Array(FieldError)
        return [FieldError.new("email", "auth.errors.user.email_required")] if email.empty?
        if !email.matches?(EMAIL_FORMAT) || email.size > 254
          return [FieldError.new("email", "auth.errors.user.email_invalid")]
        end
        taken = Partiduo::Auth::User.filter(email: email)
        taken = taken.exclude(id: existing.pk) if existing
        taken.exists? ? [FieldError.new("email", "auth.errors.user.email_taken")] : [] of FieldError
      end

      # Rôle, langue, nom ; un compte `comptable` est nominatif (ADR-002 D4).
      private def self.identity_errors(input : UserInput) : Array(FieldError)
        errors = [] of FieldError
        unless Partiduo::Auth::User::ROLES.includes?(input.role)
          errors << FieldError.new("role", "auth.errors.user.role_invalid")
        end
        unless Partiduo::LOCALES.includes?(input.locale)
          errors << FieldError.new("locale", "auth.errors.user.locale_invalid")
        end
        {"first_name" => input.first_name, "last_name" => input.last_name}.each do |field, value|
          if value.strip.empty? && input.role == "accountant"
            errors << FieldError.new(field, "auth.errors.user.nominative")
          elsif value.strip.size > 100
            errors << FieldError.new(field, "auth.errors.user.too_long")
          end
        end
        errors
      end

      private def self.profile_errors(input : ProfileInput, existing : Partiduo::Auth::Profile?) : Array(FieldError)
        errors = [] of FieldError
        name = input.name.strip
        if name.empty?
          errors << FieldError.new("name", "auth.errors.profile.name_required")
        elsif name.size > 100
          errors << FieldError.new("name", "auth.errors.user.too_long")
        else
          taken = Partiduo::Auth::Profile.filter(name: name)
          taken = taken.exclude(id: existing.pk) if existing
          errors << FieldError.new("name", "auth.errors.profile.name_taken") if taken.exists?
        end
        input.permissions.each_with_index do |permission, index|
          unless Partiduo::Modules.permission_declared?(permission)
            errors << FieldError.new("permissions[#{index}]", "auth.errors.profile.permission_unknown", {"permission" => permission})
          end
        end
        errors
      end

      private def self.store_permissions(profile : Partiduo::Auth::Profile, names : Enumerable(String)) : Nil
        Partiduo::Auth::ProfilePermission.filter(profile_id: profile.pk).delete
        names.to_set.each do |name|
          Partiduo::Auth::ProfilePermission.create!(profile: profile, permission: name)
        end
      end

      private def self.user_view(user : Partiduo::Auth::User) : UserView
        UserView.new(
          id: user.pk!.as(Int64),
          email: user.email.to_s,
          first_name: user.first_name.to_s,
          last_name: user.last_name.to_s,
          full_name: user.full_name,
          locale: user.locale.to_s,
          role: user.role.to_s,
          profile_id: user.profile_id.as(Int64?),
          active: user.is_active == true,
          revoked: user.revoked?,
          access_ends_on: user.access_ends_on,
          locked: user.locked?,
          failed_attempts: (user.failed_attempts || 0).to_i32,
          has_password: user.usable_password?,
          totp_enabled: user.totp_enabled?,
          passkey_count: Partiduo::Auth::Passkey.filter(user_id: user.pk).count.to_i32,
          ledger_security: user.ledger_security == true,
          last_login_at: user.last_login_at,
        )
      end

      private def self.profile_view(profile : Partiduo::Auth::Profile) : ProfileView
        ProfileView.new(
          id: profile.pk!.as(Int64),
          code: profile.code.to_s,
          name: profile.name.to_s,
          description: profile.description.to_s,
          admin: profile.admin == true,
          permissions: Partiduo::Auth::ProfilePermission.filter(profile_id: profile.pk).order(:permission).map(&.permission.to_s),
        )
      end

      private def self.federated_view(link : Partiduo::Auth::FederatedIdentity) : FederatedIdentityView
        FederatedIdentityView.new(link.pk!.as(Int64), link.provider.to_s, link.subject.to_s, link.last_used_at)
      end
    end
  end
end
