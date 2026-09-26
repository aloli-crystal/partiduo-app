# SPDX-License-Identifier: AGPL-3.0-or-later

require "openssl"
require "jose"
require "totp"
require "webauthn"

# Outils des specs de l'authentification (ADR-002) : utilisateurs, TOTP,
# authentificateur WebAuthn simulé, fournisseur SAML simulé.
module AuthSpec
  # Conforme à la politique : 14 caractères et plus, majuscule, minuscule, chiffre.
  PASSWORD = "Correcthorse42battery"
  ORIGIN   = "http://demo.partiduo.localhost:8000"

  def self.system : Partiduo::Api::Actor
    Partiduo::Api::Actor.system
  end

  def self.profile_id(code : String = "ADMIN") : Int64
    Partiduo::Api::Auth.ensure_default_profiles(system).find! { |profile| profile.code == code }.id
  end

  def self.create_user(email : String = "alice@example.com", password : String? = PASSWORD,
                       role : String = "member", profile : String? = "ADMIN",
                       first_name : String = "Alice", last_name : String = "Martin",
                       access_ends_on : Time? = nil) : Partiduo::Api::Auth::UserCreatedView
    input = Partiduo::Api::Auth::UserInput.new(
      email: email, first_name: first_name, last_name: last_name, role: role,
      profile_id: profile.try { |code| profile_id(code) }, access_ends_on: access_ends_on, password: password,
    )
    Partiduo::Api::Auth.create_user(system, input).value!
  end

  def self.login(email : String = "alice@example.com", password : String = PASSWORD) : Partiduo::Api::Result(Partiduo::Api::Auth::LoginView)
    Partiduo::Api::Auth.login_password(Partiduo::Api::Actor.anonymous,
      Partiduo::Api::Auth::PasswordLoginInput.new(email: email, password: password,
        context: Partiduo::Api::Auth::LoginContext.new(ip: "192.0.2.1", user_agent: "spec")))
  end

  # Session ouverte par mot de passe seul (utilisateur sans second facteur).
  def self.session_token(email : String = "alice@example.com", password : String = PASSWORD) : String
    login(email, password).value!.session_token!
  end

  def self.actor(token : String) : Partiduo::Api::Actor
    Partiduo::Api::Auth.actor(token)
  end

  def self.user_model(id : Int64) : Partiduo::Auth::User
    Partiduo::Auth::User.get!(id: id)
  end

  def self.totp_code(secret : String, time : Time = Time.utc) : String
    TOTP::Authenticator.from_base32(secret).at(time)
  end

  # Active le TOTP d'un utilisateur par le contrat ; renvoie le secret et les
  # codes de récupération.
  def self.enable_totp(actor : Partiduo::Api::Actor) : {String, Array(String)}
    enrollment = Partiduo::Api::Auth.begin_totp_enrollment(actor)
    # Code de la période précédente : celui de la période courante reste
    # disponible pour la connexion qui suit (anti-rejeu).
    code = totp_code(enrollment.secret_base32, Time.utc - 30.seconds)
    codes = Partiduo::Api::Auth.confirm_totp_enrollment(actor, code).value!.codes
    {enrollment.secret_base32, codes}
  end

  # --- CBOR minimal, pour fabriquer ce qu'enverrait un authentificateur -----

  def self.cbor_head(major : UInt8, n : Int) : Bytes
    io = IO::Memory.new
    value = n.to_u64
    if value < 24
      io.write_byte((major << 5) | value.to_u8)
    elsif value <= UInt8::MAX
      io.write_byte((major << 5) | 24_u8)
      io.write_byte(value.to_u8)
    elsif value <= UInt16::MAX
      io.write_byte((major << 5) | 25_u8)
      io.write_byte((value >> 8).to_u8)
      io.write_byte((value & 0xff).to_u8)
    else
      io.write_byte((major << 5) | 26_u8)
      4.times { |i| io.write_byte(((value >> ((3 - i) * 8)) & 0xff).to_u8) }
    end
    io.to_slice
  end

  def self.cbor_int(value : Int) : Bytes
    value < 0 ? cbor_head(1_u8, -1 - value) : cbor_head(0_u8, value)
  end

  def self.cbor_bytes(bytes : Bytes) : Bytes
    join(cbor_head(2_u8, bytes.size), bytes)
  end

  def self.cbor_text(text : String) : Bytes
    join(cbor_head(3_u8, text.bytesize), text.to_slice)
  end

  def self.cbor_map(pairs : Array(Tuple(Bytes, Bytes))) : Bytes
    io = IO::Memory.new
    io.write(cbor_head(5_u8, pairs.size))
    pairs.each do |(key, value)|
      io.write(key)
      io.write(value)
    end
    io.to_slice
  end

  def self.join(*parts : Bytes) : Bytes
    io = IO::Memory.new
    parts.each { |part| io.write(part) }
    io.to_slice
  end

  def self.sha256(bytes : Bytes) : Bytes
    OpenSSL::Digest.new("SHA256").update(bytes).final
  end

  def self.b64(bytes : Bytes) : String
    Base64.urlsafe_encode(bytes, padding: false)
  end

  FLAG_UP = WebAuthn::AuthenticatorData::FLAG_USER_PRESENT
  FLAG_UV = WebAuthn::AuthenticatorData::FLAG_USER_VERIFIED
  FLAG_AT = WebAuthn::AuthenticatorData::FLAG_ATTESTED_CREDENTIAL_DATA

  # Authentificateur de plate-forme simulé : ES256 (Apple, Android) ou
  # RS256 (Windows Hello). Compteur à zéro par défaut, comme chez Apple.
  class Authenticator
    getter key : Jose::JWK::ECKey | Jose::JWK::RSAKey
    getter credential_id : Bytes
    property sign_count : UInt32

    def initialize(rsa : Bool = false, @sign_count : UInt32 = 0_u32)
      @key = rsa ? Jose::JWK::RSAKey.generate(2048) : Jose::JWK::ECKey.generate(Jose::JWK::Curve::P256)
      @credential_id = Random::Secure.random_bytes(32)
    end

    def cose_key : Bytes
      case key = @key
      when Jose::JWK::ECKey
        public = key.public_key
        AuthSpec.cbor_map([
          {AuthSpec.cbor_int(1), AuthSpec.cbor_int(2)},
          {AuthSpec.cbor_int(3), AuthSpec.cbor_int(-7)},
          {AuthSpec.cbor_int(-1), AuthSpec.cbor_int(1)},
          {AuthSpec.cbor_int(-2), AuthSpec.cbor_bytes(public.x)},
          {AuthSpec.cbor_int(-3), AuthSpec.cbor_bytes(public.y)},
        ])
      else
        public = key.as(Jose::JWK::RSAKey).public_key
        AuthSpec.cbor_map([
          {AuthSpec.cbor_int(1), AuthSpec.cbor_int(3)},
          {AuthSpec.cbor_int(3), AuthSpec.cbor_int(-257)},
          {AuthSpec.cbor_int(-1), AuthSpec.cbor_bytes(public.n)},
          {AuthSpec.cbor_int(-2), AuthSpec.cbor_bytes(public.e)},
        ])
      end
    end

    def authenticator_data(rp_id : String, flags : UInt8, attested : Bool) : Bytes
      io = IO::Memory.new
      io.write(AuthSpec.sha256(rp_id.to_slice))
      io.write_byte(flags)
      4.times { |i| io.write_byte(((@sign_count >> ((3 - i) * 8)) & 0xff).to_u8) }
      if attested
        io.write(Bytes.new(16))
        io.write_byte(((@credential_id.size >> 8) & 0xff).to_u8)
        io.write_byte((@credential_id.size & 0xff).to_u8)
        io.write(@credential_id)
        io.write(cose_key)
      end
      io.to_slice
    end

    def client_data(type : String, challenge : String, origin : String) : Bytes
      %({"type":"#{type}","challenge":"#{challenge}","origin":"#{origin}","crossOrigin":false}).to_slice
    end

    # Réponse à `navigator.credentials.create()`.
    def register(options : Partiduo::Api::Auth::RegistrationOptionsView, origin : String = ORIGIN,
                 flags : UInt8 = FLAG_UP | FLAG_UV | FLAG_AT, rp_id : String? = nil,
                 name : String = "Portable") : Partiduo::Api::Auth::PasskeyRegistrationInput
      auth_data = authenticator_data(rp_id || options.rp_id, flags, attested: true)
      attestation = AuthSpec.cbor_map([
        {AuthSpec.cbor_text("fmt"), AuthSpec.cbor_text("none")},
        {AuthSpec.cbor_text("attStmt"), Bytes[0xa0]},
        {AuthSpec.cbor_text("authData"), AuthSpec.cbor_bytes(auth_data)},
      ])
      Partiduo::Api::Auth::PasskeyRegistrationInput.new(
        challenge_id: options.challenge_id,
        attestation_object: AuthSpec.b64(attestation),
        client_data_json: AuthSpec.b64(client_data("webauthn.create", options.challenge, origin)),
        transports: ["internal", "hybrid"],
        name: name,
      )
    end

    # Réponse à `navigator.credentials.get()`.
    def assert(options : Partiduo::Api::Auth::AuthenticationOptionsView, origin : String = ORIGIN,
               flags : UInt8 = FLAG_UP | FLAG_UV, user_handle : String? = nil,
               tamper : Bool = false) : Partiduo::Api::Auth::PasskeyAssertionInput
      auth_data = authenticator_data(options.rp_id, flags, attested: false)
      client = client_data("webauthn.get", options.challenge, origin)
      signed = AuthSpec.join(auth_data, AuthSpec.sha256(client))
      signed = AuthSpec.join(signed, Bytes[0]) if tamper
      algorithm = @key.is_a?(Jose::JWK::ECKey) ? Jose::JWS::Algorithm::ES256 : Jose::JWS::Algorithm::RS256
      signature = Jose::JWS.sign_data(signed, algorithm, @key)
      Partiduo::Api::Auth::PasskeyAssertionInput.new(
        challenge_id: options.challenge_id,
        credential_id: AuthSpec.b64(@credential_id),
        authenticator_data: AuthSpec.b64(auth_data),
        client_data_json: AuthSpec.b64(client),
        signature: AuthSpec.b64(signature),
        user_handle: user_handle,
      )
    end
  end

  # Enrôle une passkey pour l'acteur ; renvoie l'authentificateur et la vue.
  def self.enroll_passkey(actor : Partiduo::Api::Actor, rsa : Bool = false) : {Authenticator, Partiduo::Api::Auth::PasskeyEnrollmentView}
    authenticator = Authenticator.new(rsa: rsa)
    options = Partiduo::Api::Auth.begin_passkey_registration(actor)
    result = Partiduo::Api::Auth.finish_passkey_registration(actor, authenticator.register(options))
    {authenticator, result.value!}
  end

  def self.passkey_login(authenticator : Authenticator, origin : String = ORIGIN) : Partiduo::Api::Result(Partiduo::Api::Auth::LoginView)
    options = Partiduo::Api::Auth.begin_passkey_login(Partiduo::Api::Actor.anonymous)
    Partiduo::Api::Auth.login_passkey(Partiduo::Api::Actor.anonymous, authenticator.assert(options, origin))
  end
end
