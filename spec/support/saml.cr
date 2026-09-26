# SPDX-License-Identifier: AGPL-3.0-or-later

require "base64"
require "jose"
require "xml"

# Fournisseur d'identité SAML simulé : clé RSA (jose), certificat auto-signé
# (ligne de commande `openssl`), réponses signées selon le profil SAML
# (signature enveloppée dans l'assertion, C14N exclusive, RSA-SHA256).
module SamlSpec
  IDP_ENTITY = "https://idp.example.test/metadata"
  SP_ENTITY  = "https://demo.partiduo.localhost/saml/metadata"
  ACS_URL    = "https://demo.partiduo.localhost/auth/saml/acs"
  DS         = "http://www.w3.org/2000/09/xmldsig#"

  record Identity, key : Jose::JWK::RSAKey, certificate : String

  @@idp : Identity?
  @@attacker : Identity?

  def self.idp : Identity
    @@idp ||= generate("idp.example.test")
  end

  def self.attacker : Identity
    @@attacker ||= generate("attacker.example.test")
  end

  def self.generate(common_name : String) : Identity
    key = Jose::JWK::RSAKey.generate(2048)
    dir = File.tempname("partiduo-saml")
    Dir.mkdir_p(dir)
    key_path = File.join(dir, "key.pem")
    cert_path = File.join(dir, "cert.pem")
    File.write(key_path, "-----BEGIN PRIVATE KEY-----\n#{Base64.encode(key.to_pkcs8_der)}-----END PRIVATE KEY-----\n")
    status = Process.run("openssl", ["req", "-new", "-x509", "-key", key_path, "-out", cert_path,
                                     "-days", "2", "-subj", "/CN=#{common_name}"], error: Process::Redirect::Inherit)
    raise "openssl req a échoué" unless status.success?
    Identity.new(key, File.read(cert_path))
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  def self.settings(certificate : String = idp.certificate) : Hash(String, String)
    {
      "idp_entity_id"                  => IDP_ENTITY,
      "idp_sso_service_url"            => "https://idp.example.test/sso",
      "idp_cert"                       => certificate,
      "sp_entity_id"                   => SP_ENTITY,
      "assertion_consumer_service_url" => ACS_URL,
    }
  end

  def self.configure(code : String = "idp", level : Int32 = 2) : Partiduo::Api::Auth::IdentityProviderView
    input = Partiduo::Api::Auth::IdentityProviderInput.new(code: code, kind: "saml", name: "IdP du cabinet",
      level: level, settings: settings)
    Partiduo::Api::Auth.save_identity_provider(Partiduo::Api::Actor.system, input).value!
  end

  def self.canonical(xml : String) : String
    CrystalSaml::XmlSecurity::C14N.canonicalize(XML.parse(xml).first_element_child || raise "XML vide")
  end

  def self.b64(bytes : Bytes) : String
    Base64.strict_encode(bytes)
  end

  # Signature enveloppée de l'élément `id`, dont `unsigned` est le XML sans
  # signature ; `signer` signe, `embed` : certificat placé dans KeyInfo.
  def self.signature(id : String, unsigned : String, signer : Identity, embed : Identity? = nil) : String
    digest = b64(OpenSSL::Digest.new("SHA256").update(canonical(unsigned)).final)
    signed_info = %(<ds:SignedInfo xmlns:ds="#{DS}">) +
                  %(<ds:CanonicalizationMethod Algorithm="http://www.w3.org/2001/10/xml-exc-c14n#"/>) +
                  %(<ds:SignatureMethod Algorithm="http://www.w3.org/2001/04/xmldsig-more#rsa-sha256"/>) +
                  %(<ds:Reference URI="##{id}"><ds:Transforms>) +
                  %(<ds:Transform Algorithm="http://www.w3.org/2000/09/xmldsig#enveloped-signature"/>) +
                  %(<ds:Transform Algorithm="http://www.w3.org/2001/10/xml-exc-c14n#"/></ds:Transforms>) +
                  %(<ds:DigestMethod Algorithm="http://www.w3.org/2001/04/xmlenc#sha256"/>) +
                  %(<ds:DigestValue>#{digest}</ds:DigestValue></ds:Reference></ds:SignedInfo>)
    value = b64(Jose::JWS.sign_data(canonical(signed_info).to_slice, Jose::JWS::Algorithm::RS256, signer.key))
    key_info = if embedded = embed
                 body = embedded.certificate.gsub(/-----(BEGIN|END) CERTIFICATE-----/, "").gsub(/\s+/, "")
                 %(<ds:KeyInfo><ds:X509Data><ds:X509Certificate>#{body}</ds:X509Certificate></ds:X509Data></ds:KeyInfo>)
               else
                 ""
               end
    %(<ds:Signature xmlns:ds="#{DS}">#{signed_info.sub(%( xmlns:ds="#{DS}"), "")}<ds:SignatureValue>#{value}</ds:SignatureValue>#{key_info}</ds:Signature>)
  end

  def self.assertion(id : String, subject : String, issuer : String, audience : String, request_id : String,
                     not_before : Time, not_after : Time, signature : String = "") : String
    %(<saml:Assertion xmlns:saml="urn:oasis:names:tc:SAML:2.0:assertion" ID="#{id}" Version="2.0" IssueInstant="#{stamp(Time.utc)}">) +
      %(<saml:Issuer>#{issuer}</saml:Issuer>#{signature}) +
      %(<saml:Subject><saml:NameID Format="urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress">#{subject}</saml:NameID>) +
      %(<saml:SubjectConfirmation Method="urn:oasis:names:tc:SAML:2.0:cm:bearer"><saml:SubjectConfirmationData InResponseTo="#{request_id}" NotOnOrAfter="#{stamp(not_after)}" Recipient="#{ACS_URL}"/></saml:SubjectConfirmation></saml:Subject>) +
      %(<saml:Conditions NotBefore="#{stamp(not_before)}" NotOnOrAfter="#{stamp(not_after)}"><saml:AudienceRestriction><saml:Audience>#{audience}</saml:Audience></saml:AudienceRestriction></saml:Conditions>) +
      %(<saml:AuthnStatement AuthnInstant="#{stamp(Time.utc)}" SessionIndex="_s1"><saml:AuthnContext><saml:AuthnContextClassRef>urn:oasis:names:tc:SAML:2.0:ac:classes:PasswordProtectedTransport</saml:AuthnContextClassRef></saml:AuthnContext></saml:AuthnStatement>) +
      %(<saml:AttributeStatement><saml:Attribute Name="email"><saml:AttributeValue>#{subject}</saml:AttributeValue></saml:Attribute></saml:AttributeStatement>) +
      %(</saml:Assertion>)
  end

  # Réponse encodée en base64, assertion signée par `signer`.
  def self.response(request_id : String, subject : String = "expert@cabinet.example", *,
                    signer : Identity = idp, embed : Identity? = nil, issuer : String = IDP_ENTITY,
                    audience : String = SP_ENTITY, status : String = "urn:oasis:names:tc:SAML:2.0:status:Success",
                    not_before : Time = Time.utc - 2.minutes, not_after : Time = Time.utc + 5.minutes,
                    signed : Bool = true, wrap_subject : String? = nil) : String
    id = "_a#{Random::Secure.hex(8)}"
    unsigned = assertion(id, subject, issuer, audience, request_id, not_before, not_after)
    sig = signed ? signature(id, unsigned, signer, embed) : ""
    body = assertion(id, subject, issuer, audience, request_id, not_before, not_after, sig)
    # Emballage : une seconde assertion, non signée, pour un autre sujet.
    if other = wrap_subject
      body = assertion("_w#{Random::Secure.hex(8)}", other, issuer, audience, request_id, not_before, not_after) + body
    end
    xml = %(<samlp:Response xmlns:samlp="urn:oasis:names:tc:SAML:2.0:protocol" xmlns:saml="urn:oasis:names:tc:SAML:2.0:assertion" ID="_r#{Random::Secure.hex(8)}" Version="2.0" IssueInstant="#{stamp(Time.utc)}" Destination="#{ACS_URL}" InResponseTo="#{request_id}">) +
          %(<saml:Issuer>#{issuer}</saml:Issuer><samlp:Status><samlp:StatusCode Value="#{status}"/></samlp:Status>#{body}</samlp:Response>)
    Base64.strict_encode(xml)
  end

  def self.stamp(time : Time) : String
    time.to_utc.to_s("%Y-%m-%dT%H:%M:%SZ")
  end

  # Identifiant de requête SAML (`InResponseTo`) d'une connexion commencée.
  def self.request_id(start : Partiduo::Api::Auth::FederatedStartView) : String
    Partiduo::Auth::Challenge.filter(handle_digest: Partiduo::Auth::Secrets.digest(start.request_id)).first!.value.to_s
  end
end
