# SPDX-License-Identifier: AGPL-3.0-or-later

# Lot 0 (ADR-002) : profils et droits, rôle comptable, limitation des
# tentatives, TOTP, passkeys, codes de récupération, sessions, défis, jetons,
# fournisseurs d'identité, journal d'audit immuable.
class Migration::Auth::V0002 < Marten::Migration
  depends_on :auth, "0001_create_auth_user_table"

  def plan
    create_table :auth_profile do
      column :id, :big_int, primary_key: true, auto: true
      column :code, :string, max_size: 32, default: ""
      column :name, :string, max_size: 100, unique: true
      column :description, :text, default: ""
      column :admin, :bool, default: false
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :auth_profile_permission do
      column :id, :big_int, primary_key: true, auto: true
      column :profile_id, :reference, to_table: :auth_profile, to_column: :id
      column :permission, :string, max_size: 128
      unique_constraint :auth_profile_permission_unique, [:profile_id, :permission]
    end

    add_column :auth_user, :first_name, :string, max_size: 100, default: ""
    add_column :auth_user, :last_name, :string, max_size: 100, default: ""
    add_column :auth_user, :locale, :string, max_size: 8, default: "fr"
    add_column :auth_user, :role, :string, max_size: 16, default: "member"
    add_column :auth_user, :profile_id, :reference, to_table: :auth_profile, to_column: :id, null: true
    add_column :auth_user, :is_active, :bool, default: true
    add_column :auth_user, :access_ends_on, :date, null: true
    add_column :auth_user, :revoked_at, :date_time, null: true
    add_column :auth_user, :ledger_security, :bool, default: false
    add_column :auth_user, :failed_attempts, :int, default: 0
    add_column :auth_user, :last_failed_at, :date_time, null: true
    add_column :auth_user, :locked_at, :date_time, null: true
    add_column :auth_user, :totp_secret, :string, max_size: 64, null: true
    add_column :auth_user, :totp_pending_secret, :string, max_size: 64, null: true
    add_column :auth_user, :totp_enabled_at, :date_time, null: true
    add_column :auth_user, :last_otp_counter, :big_int, null: true
    add_column :auth_user, :passkey_prompt_dismissed_at, :date_time, null: true
    add_column :auth_user, :last_login_at, :date_time, null: true
    add_column :auth_user, :password_changed_at, :date_time, null: true

    create_table :auth_ledger_access do
      column :id, :big_int, primary_key: true, auto: true
      column :user_id, :reference, to_table: :auth_user, to_column: :id
      column :ledger_id, :big_int
      column :access, :string, max_size: 1
      unique_constraint :auth_ledger_access_unique, [:user_id, :ledger_id]
    end

    create_table :auth_session do
      column :id, :big_int, primary_key: true, auto: true
      column :user_id, :reference, to_table: :auth_user, to_column: :id
      column :token_digest, :string, max_size: 64, unique: true
      column :level, :int, default: 0
      column :method, :string, max_size: 16
      column :ip, :string, max_size: 64, default: ""
      column :user_agent, :string, max_size: 255, default: ""
      column :created_at, :date_time
      column :last_seen_at, :date_time
      column :expires_at, :date_time
      column :revoked_at, :date_time, null: true
    end

    create_table :auth_challenge do
      column :id, :big_int, primary_key: true, auto: true
      column :purpose, :string, max_size: 32
      column :handle_digest, :string, max_size: 64, unique: true
      column :value, :string, max_size: 255, default: ""
      column :data, :string, max_size: 255, default: ""
      column :user_id, :reference, to_table: :auth_user, to_column: :id, null: true
      column :created_at, :date_time
      column :expires_at, :date_time
      column :used_at, :date_time, null: true
    end

    create_table :auth_passkey do
      column :id, :big_int, primary_key: true, auto: true
      column :user_id, :reference, to_table: :auth_user, to_column: :id
      column :credential_id, :string, max_size: 1400, unique: true
      column :public_key, :text
      column :cose_algorithm, :int
      column :sign_count, :big_int, default: 0
      column :aaguid, :string, max_size: 36, default: ""
      column :transports, :string, max_size: 128, default: ""
      column :backup_eligible, :bool, default: false
      column :backup_state, :bool, default: false
      column :name, :string, max_size: 100, default: ""
      column :created_at, :date_time
      column :last_used_at, :date_time, null: true
    end

    create_table :auth_recovery_code do
      column :id, :big_int, primary_key: true, auto: true
      column :user_id, :reference, to_table: :auth_user, to_column: :id
      column :code_digest, :string, max_size: 64
      column :created_at, :date_time
      column :used_at, :date_time, null: true
    end

    create_table :auth_token do
      column :id, :big_int, primary_key: true, auto: true
      column :purpose, :string, max_size: 16
      column :digest, :string, max_size: 64, unique: true
      column :user_id, :reference, to_table: :auth_user, to_column: :id
      column :created_at, :date_time
      column :expires_at, :date_time
      column :used_at, :date_time, null: true
    end

    create_table :auth_identity_provider do
      column :id, :big_int, primary_key: true, auto: true
      column :code, :string, max_size: 64, unique: true
      column :kind, :string, max_size: 16
      column :name, :string, max_size: 100
      column :level, :int, default: 2
      column :active, :bool, default: true
      column :settings, :text, default: "{}"
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :auth_federated_identity do
      column :id, :big_int, primary_key: true, auto: true
      column :user_id, :reference, to_table: :auth_user, to_column: :id
      column :provider, :string, max_size: 64
      column :subject, :string, max_size: 255
      column :created_at, :date_time
      column :last_used_at, :date_time, null: true
      unique_constraint :auth_federated_identity_unique, [:provider, :subject]
    end

    create_table :auth_audit_event do
      column :id, :big_int, primary_key: true, auto: true
      column :actor_id, :big_int, null: true
      column :user_label, :string, max_size: 255, default: ""
      column :action, :string, max_size: 64
      column :module_code, :string, max_size: 64, default: ""
      column :state, :string, max_size: 8
      column :ip, :string, max_size: 64, default: ""
      column :detail, :text, default: ""
      column :created_at, :date_time
    end

    # Règles portées par la base, en plus du modèle (une instruction par
    # `execute` : PostgreSQL refuse plusieurs commandes préparées).
    check :auth_user, :auth_user_role_check, "role IN ('member', 'accountant')"
    check :auth_user, :auth_user_failed_attempts_check, "failed_attempts >= 0"
    check :auth_ledger_access, :auth_ledger_access_access_check, "access IN ('W', 'R', 'X')"
    check :auth_session, :auth_session_level_check, "level BETWEEN 0 AND 3"
    check :auth_audit_event, :auth_audit_event_state_check, "state IN ('SUCCESS', 'FAIL', 'AUDIT', 'ADMIN')"

    # Journal d'audit en ajout seul (ADR-002 D4 : « qui a passé cette
    # écriture » doit rester vrai) : ni modification ni suppression.
    execute(<<-SQL, "DROP FUNCTION auth_audit_event_immutable()")
      CREATE FUNCTION auth_audit_event_immutable() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'auth_audit_event : le journal d''audit est en ajout seul'
          USING ERRCODE = 'insufficient_privilege';
      END;
      $$
      SQL
    execute(<<-SQL, "DROP TRIGGER auth_audit_event_immutable ON auth_audit_event")
      CREATE TRIGGER auth_audit_event_immutable
        BEFORE UPDATE OR DELETE ON auth_audit_event
        FOR EACH ROW EXECUTE FUNCTION auth_audit_event_immutable()
      SQL
  end

  private def check(table : Symbol, name : Symbol, condition : String) : Nil
    execute("ALTER TABLE #{table} ADD CONSTRAINT #{name} CHECK (#{condition})",
      "ALTER TABLE #{table} DROP CONSTRAINT #{name}")
  end
end
