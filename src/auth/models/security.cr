# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Auth
    # Droit d'un utilisateur sur un journal, héritier de `user_sec_jrn` :
    # `W` écriture, `R` lecture, `X` aucun accès. Le journal est désigné par
    # son identifiant (`ledger_id`), sans clé étrangère : les journaux
    # appartiennent au module Comptabilité, que le socle ne cite pas
    # (ADR-006 D3). N'a d'effet que si `User#ledger_security` est vrai.
    class LedgerAccess < Marten::Model
      ACCESSES = %w[W R X]

      field :id, :big_int, primary_key: true, auto: true
      field :user, :many_to_one, to: Partiduo::Auth::User, on_delete: :cascade
      field :ledger_id, :big_int
      field :access, :string, max_size: 1

      db_unique_constraint :auth_ledger_access_unique, field_names: [:user, :ledger_id]
    end

    # Session ouverte par une authentification. Le jeton n'est conservé que
    # sous forme d'empreinte SHA-256 ; `level` est le niveau atteint
    # (ADR-002 D2 : 1 mot de passe, 2 mot de passe + TOTP, 3 passkey ; 0 pour
    # une session d'enrôlement ouverte par une invitation). `method` : dernier
    # facteur présenté — `password`, `totp`, `recovery_code`, `passkey`,
    # `federated`, `invitation`.
    class Session < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :user, :many_to_one, to: Partiduo::Auth::User, on_delete: :cascade
      field :token_digest, :string, max_size: 64, unique: true
      field :level, :int, default: 0
      field :method, :string, max_size: 16
      field :ip, :string, max_size: 64, blank: true, default: ""
      field :user_agent, :string, max_size: 255, blank: true, default: ""
      field :created_at, :date_time, auto_now_add: true
      field :last_seen_at, :date_time
      field :expires_at, :date_time
      field :revoked_at, :date_time, null: true, blank: true
    end

    # Défi à usage unique, conservé côté serveur : WebAuthn (enregistrement,
    # authentification), second facteur en attente après le mot de passe,
    # requête SAML (`InResponseTo`). Le client ne détient que `handle`, dont
    # seule l'empreinte est stockée.
    class Challenge < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :purpose, :string, max_size: 32
      field :handle_digest, :string, max_size: 64, unique: true
      field :value, :string, max_size: 255, blank: true, default: ""
      field :data, :string, max_size: 255, blank: true, default: ""
      field :user, :many_to_one, to: Partiduo::Auth::User, null: true, blank: true, on_delete: :cascade
      field :created_at, :date_time, auto_now_add: true
      field :expires_at, :date_time
      field :used_at, :date_time, null: true, blank: true
    end

    # Passkey enrôlée (ADR-002 D2) : clé publique COSE, compteur de signature,
    # drapeaux de sauvegarde. Aucun secret.
    class Passkey < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :user, :many_to_one, to: Partiduo::Auth::User, on_delete: :cascade
      field :credential_id, :string, max_size: 1400, unique: true
      field :public_key, :text
      field :cose_algorithm, :int
      field :sign_count, :big_int, default: 0
      field :aaguid, :string, max_size: 36, blank: true, default: ""
      field :transports, :string, max_size: 128, blank: true, default: ""
      field :backup_eligible, :bool, default: false
      field :backup_state, :bool, default: false
      field :name, :string, max_size: 100, blank: true, default: ""
      field :created_at, :date_time, auto_now_add: true
      field :last_used_at, :date_time, null: true, blank: true
    end

    # Code de récupération à usage unique (ADR-002 D7). Codes aléatoires de
    # 80 bits : une empreinte SHA-256 suffit, sans BCrypt.
    class RecoveryCode < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :user, :many_to_one, to: Partiduo::Auth::User, on_delete: :cascade
      field :code_digest, :string, max_size: 64
      field :created_at, :date_time, auto_now_add: true
      field :used_at, :date_time, null: true, blank: true
    end

    # Jeton à usage unique remis hors bande (courriel) : invitation, remise à
    # zéro du mot de passe, déblocage du compte.
    class Token < Marten::Model
      PURPOSES = %w[invitation password_reset unlock]

      field :id, :big_int, primary_key: true, auto: true
      field :purpose, :string, max_size: 16
      field :digest, :string, max_size: 64, unique: true
      field :user, :many_to_one, to: Partiduo::Auth::User, on_delete: :cascade
      field :created_at, :date_time, auto_now_add: true
      field :expires_at, :date_time
      field :used_at, :date_time, null: true, blank: true
    end

    # Fournisseur d'identité configuré sur l'instance (ADR-002 D3). `kind` :
    # `saml` (intégré) ou `oidc` (interface pluggable). `level` : niveau que
    # l'instance reconnaît à une authentification par ce fournisseur (2 par
    # défaut ; 3 seulement si l'IdP impose une authentification résistante à
    # l'hameçonnage). `settings` : paramètres propres au type, en JSON.
    class IdentityProvider < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :code, :string, max_size: 64, unique: true
      field :kind, :string, max_size: 16
      field :name, :string, max_size: 100
      field :level, :int, default: 2
      field :active, :bool, default: true
      field :settings, :text, blank: true, default: "{}"
      field :created_at, :date_time, auto_now_add: true
      field :updated_at, :date_time, auto_now: true
    end

    # Identité fédérée d'un utilisateur *déjà créé localement* (ADR-002 D3) :
    # `provider` + `subject`. Pas d'auto-provisionnement.
    class FederatedIdentity < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :user, :many_to_one, to: Partiduo::Auth::User, on_delete: :cascade
      field :provider, :string, max_size: 64
      field :subject, :string, max_size: 255
      field :created_at, :date_time, auto_now_add: true
      field :last_used_at, :date_time, null: true, blank: true

      db_unique_constraint :auth_federated_identity_unique, field_names: [:provider, :subject]
    end

    # Journal d'audit nominatif, héritier d'`audit_connect` (ADR-002 D4).
    # `state` : `SUCCESS`, `FAIL`, `AUDIT`, `ADMIN`. Pas de clé étrangère vers
    # l'utilisateur (`actor_id`) : le journal survit à tout, et `user_label` fige le nom au
    # moment de l'action. Lignes immuables (déclencheur, migration 0002).
    class AuditEvent < Marten::Model
      STATES = %w[SUCCESS FAIL AUDIT ADMIN]

      field :id, :big_int, primary_key: true, auto: true
      field :actor_id, :big_int, null: true, blank: true
      field :user_label, :string, max_size: 255, blank: true, default: ""
      field :action, :string, max_size: 64
      field :module_code, :string, max_size: 64, blank: true, default: ""
      field :state, :string, max_size: 8
      field :ip, :string, max_size: 64, blank: true, default: ""
      field :detail, :text, blank: true, default: ""
      field :created_at, :date_time, auto_now_add: true
    end
  end
end
