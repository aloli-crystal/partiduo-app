# SPDX-License-Identifier: AGPL-3.0-or-later

require "base64"
require "crypto/subtle"
require "jose"
require "openssl"
require "xml"
# Composants de `prod-crystal/saml` utilisés, sans `crystal_saml/openssl_ext`,
# dont les liaisons OpenSSL entrent en conflit avec celles de `jose` (requis
# par `webauthn`) : voir BLOCAGES B-AUTH-002.
require "saml/crystal_saml/utils"
require "saml/crystal_saml/settings"
require "saml/crystal_saml/xml_security"
require "saml/crystal_saml/authrequest"

lib LibCrypto
  # Nom propre à Partiduo : `saml` lie le même symbole sous un autre type.
  fun partiduo_x509_get_pubkey = X509_get_pubkey(x : X509) : EvpPKey
end

module Partiduo
  module Auth
    # SAML 2.0 intégré (ADR-002 D3) avec `prod-crystal/saml`, en fournisseur
    # de service : requête `AuthnRequest` par liaison HTTP-Redirect (construite
    # par le shard), réponse par HTTP-POST.
    #
    # La réponse est contrôlée ici, pas par `CrystalSaml::Response` : le
    # validateur du shard préfère le certificat embarqué dans la réponse au
    # certificat configuré, n'applique pas la transformation
    # « enveloped-signature », et n'exige ni l'audience ni `InResponseTo`
    # (voir BLOCAGES B-AUTH-001). Contrôles : pas de DTD, statut `Success`,
    # émetteur, `InResponseTo` (connexions à l'initiative du fournisseur
    # refusées), destination, période de validité (±60 s), audience, et
    # signature couvrant l'unique assertion (`SamlSignature`).
    class SamlAdapter < Federation::Adapter
      REQUIRED = %w[idp_entity_id idp_sso_service_url idp_cert sp_entity_id assertion_consumer_service_url]
      SKEW     = 60.seconds
      SUCCESS  = "urn:oasis:names:tc:SAML:2.0:status:Success"
      # Déclaration de type de document ou d'entité (DOCTYPE, ENTITY).
      DTD = /<!\s*(DOCTYPE|ENTITY)/i

      def kind : String
        "saml"
      end

      def validate_settings(settings : Hash(String, String)) : Array(Partiduo::Api::FieldError)
        errors = REQUIRED.compact_map do |key|
          next if settings[key]?.presence
          Partiduo::Api::FieldError.new("settings.#{key}", "auth.errors.provider.required")
        end
        if (cert = settings["idp_cert"]?.presence) && !SamlSignature.certificate?(cert)
          errors << Partiduo::Api::FieldError.new("settings.idp_cert", "auth.errors.provider.certificate")
        end
        errors
      end

      def begin_login(provider : IdentityProvider, settings : Hash(String, String)) : Federation::Start
        request = CrystalSaml::AuthRequest.new(saml_settings(settings))
        Federation::Start.new(request.redirect_url(relay_state: provider.code), request.id)
      end

      def complete_login(provider : IdentityProvider, settings : Hash(String, String),
                         payload : Hash(String, String), request_id : String,
                         now : Time = Time.utc) : Federation::Identity
        xml = decode_response(payload)
        check_envelope(xml, request_id, settings)
        subject, assertion = SamlSignature.signed_subject(xml, settings["idp_cert"]? || "")
        check_assertion(assertion, settings, now)
        attributes = attributes_of(assertion)
        email = attributes["email"]?.try(&.first?) || (subject.includes?('@') ? subject : nil)
        Federation::Identity.new(subject: subject, email: email, attributes: attributes)
      rescue ex : SamlSignature::Error
        raise Federation::Error.new("auth.errors.federated.signature", ex.message)
      end

      # XML de la réponse (liaison HTTP-POST : base64), sans DTD — ni entité
      # externe, ni expansion d'entités.
      private def decode_response(payload : Hash(String, String)) : String
        raw = payload["SAMLResponse"]?.presence || invalid("SAMLResponse absent")
        xml = begin
          String.new(Base64.decode(raw.gsub(/\s+/, "")))
        rescue Base64::Error
          invalid("SAMLResponse n'est pas du base64")
        end
        invalid("DTD refusée") if xml.matches?(DTD)
        xml
      end

      # Enveloppe `Response` : statut, requête d'origine, destination.
      private def check_envelope(xml : String, request_id : String, settings : Hash(String, String)) : Nil
        document = begin
          XML.parse(xml, XML::ParserOptions::NONET | XML::ParserOptions::NOBLANKS)
        rescue ex : XML::Error
          invalid(ex.message.to_s)
        end
        root = document.first_element_child || invalid("document vide")
        invalid("élément racine #{root.name}") unless SamlSignature.local_name(root) == "Response"

        status = SamlSignature.first(root, "StatusCode").try(&.["Value"]?)
        invalid("statut #{status || "absent"}") unless status == SUCCESS
        invalid("InResponseTo inattendu") unless root["InResponseTo"]? == request_id
        destination = root["Destination"]?
        invalid("Destination inattendue") if destination && destination != settings["assertion_consumer_service_url"]?
      end

      # Assertion signée : émetteur, période de validité, audience.
      private def check_assertion(assertion : XML::Node, settings : Hash(String, String), now : Time) : Nil
        issuer = SamlSignature.child(assertion, "Issuer").try(&.content.strip)
        invalid("émetteur inattendu") unless issuer == settings["idp_entity_id"]?

        conditions = SamlSignature.child(assertion, "Conditions") || invalid("Conditions absentes")
        not_before = timestamp(conditions["NotBefore"]?)
        invalid("réponse pas encore valable") if not_before && now + SKEW < not_before
        not_after = timestamp(conditions["NotOnOrAfter"]?) || invalid("NotOnOrAfter absent")
        invalid("réponse expirée") if now - SKEW >= not_after
        audiences = SamlSignature.all(conditions, "Audience").map(&.content.strip)
        invalid("audience absente ou différente") unless audiences.includes?(settings["sp_entity_id"]?)
      end

      private def attributes_of(assertion : XML::Node) : Hash(String, Array(String))
        attributes = {} of String => Array(String)
        SamlSignature.all(assertion, "Attribute").each do |attribute|
          name = attribute["Name"]? || next
          attributes[name] = SamlSignature.all(attribute, "AttributeValue").map(&.content.strip)
        end
        attributes
      end

      private def invalid(reason : String) : NoReturn
        raise Federation::Error.new("auth.errors.federated.invalid", reason)
      end

      private def timestamp(value : String?) : Time?
        return if value.nil?
        Time.parse_rfc3339(value)
      rescue Time::Format::Error
        invalid("horodatage illisible : #{value}")
      end

      private def saml_settings(settings : Hash(String, String)) : CrystalSaml::Settings
        config = CrystalSaml::Settings.new
        config.idp_entity_id = settings["idp_entity_id"]? || ""
        config.idp_sso_service_url = settings["idp_sso_service_url"]? || ""
        config.idp_cert = settings["idp_cert"]? || ""
        config.sp_entity_id = settings["sp_entity_id"]? || ""
        config.assertion_consumer_service_url = settings["assertion_consumer_service_url"]? || ""
        if format = settings["name_identifier_format"]?.presence
          config.name_identifier_format = format
        end
        config
      end
    end

    # Vérification XML-DSig d'une réponse SAML *contre le seul certificat
    # configuré* pour le fournisseur (tout certificat embarqué est ignoré).
    # Profil SAML (core §5.4) : signature enveloppée, enfant de l'élément
    # signé (`Response` ou `Assertion`), dont elle référence l'`ID` ;
    # l'empreinte porte sur l'élément *sans* sa signature, canonicalisé par
    # `CrystalSaml::XmlSecurity::C14N` (C14N exclusive). SHA-256 au moins.
    #
    # Contre l'emballage de signature : identifiants `ID` uniques, une seule
    # `Assertion`, et son `NameID` n'est lu que si l'assertion est signée ou
    # directement contenue dans une `Response` signée.
    module SamlSignature
      DS_NS = "http://www.w3.org/2000/09/xmldsig#"

      class Error < Exception
      end

      def self.certificate?(pem : String) : Bool
        pkey = public_key(pem)
        LibCrypto.evp_pkey_free(pkey)
        true
      rescue Error
        false
      end

      # `NameID` de l'unique assertion et l'assertion elle-même, après
      # vérification de la signature qui la couvre.
      def self.signed_subject(xml : String, cert : String) : {String, XML::Node}
        raise Error.new("certificat du fournisseur absent") if cert.strip.empty?
        document = XML.parse(xml, XML::ParserOptions::NONET | XML::ParserOptions::NOBLANKS)
        root = document.first_element_child || raise Error.new("document vide")
        ids = all(root, "*").compact_map(&.["ID"]?)
        raise Error.new("identifiants ID en double") unless ids.uniq.size == ids.size

        assertions = all(root, "Assertion")
        raise Error.new("#{assertions.size} assertions (une seule admise)") unless assertions.size == 1
        assertion = assertions.first

        verified = all(root, "Signature")
          .select { |node| node.namespace.try(&.href) == DS_NS }
          .map { |signature| verify(xml, signature, cert) }

        covered = verified.includes?(assertion["ID"]?) ||
                  (verified.includes?(root["ID"]?) && assertion.parent.try(&.object_id) == root.object_id)
        raise Error.new("aucune signature valide ne couvre l'assertion") unless covered

        name_ids = all(assertion, "NameID")
        raise Error.new("NameID absent ou multiple") unless name_ids.size == 1
        subject = name_ids.first.content.strip
        raise Error.new("NameID vide") if subject.empty?
        {subject, assertion}
      end

      # Vérifie une signature enveloppée ; renvoie l'`ID` de l'élément signé.
      private def self.verify(xml : String, signature : XML::Node, cert : String) : String
        signed = signature.parent || raise Error.new("signature orpheline")
        id = signed["ID"]? || raise Error.new("élément signé sans ID")

        signed_info = child(signature, "SignedInfo") || raise Error.new("SignedInfo absent")
        references = signed_info.children.select { |node| node.element? && local_name(node) == "Reference" }
        raise Error.new("une seule référence admise") unless references.size == 1
        reference = references.first
        raise Error.new("la référence ne désigne pas l'élément parent") unless reference["URI"]? == "##{id}"
        verify_digest(xml, id, reference)

        method = child(signed_info, "SignatureMethod").try(&.["Algorithm"]?) || ""
        value = decode(child(signature, "SignatureValue").try(&.content) || "")
        canonical_info = CrystalSaml::XmlSecurity::C14N.canonicalize(signed_info)
        raise Error.new("signature invalide") unless verify_signature(cert, canonical_info, value, digest_name(method))
        id
      end

      # Empreinte de l'élément signé, sa signature retirée, sur une copie.
      private def self.verify_digest(xml : String, id : String, reference : XML::Node) : Nil
        copy = XML.parse(xml, XML::ParserOptions::NONET | XML::ParserOptions::NOBLANKS)
        root = copy.first_element_child || raise Error.new("document vide")
        target = all(root, "*").find { |node| node["ID"]? == id } || raise Error.new("élément signé introuvable")
        target.children.to_a.each do |node|
          node.unlink if node.element? && local_name(node) == "Signature" && node.namespace.try(&.href) == DS_NS
        end
        canonical = CrystalSaml::XmlSecurity::C14N.canonicalize(target, inclusive_prefixes(reference))
        digest_method = child(reference, "DigestMethod").try(&.["Algorithm"]?) || ""
        expected = decode(child(reference, "DigestValue").try(&.content) || "")
        actual = OpenSSL::Digest.new(digest_name(digest_method)).update(canonical).final
        raise Error.new("empreinte différente") unless Crypto::Subtle.constant_time_compare(actual, expected)
      end

      # Vérifie `signature` sur `data` avec la clé publique du certificat PEM.
      def self.verify_signature(cert : String, data : String, signature : Bytes, digest : String) : Bool
        pkey = public_key(cert)
        ctx = LibCrypto.evp_md_ctx_new
        begin
          md = LibCrypto.evp_get_digestbyname(digest)
          raise Error.new("empreinte inconnue : #{digest}") if md.null?
          return false unless LibCrypto.evp_digestverifyinit(ctx, nil, md, nil, pkey) == 1
          LibCrypto.evp_digestverify(ctx, signature.to_unsafe, signature.size, data.to_unsafe, data.bytesize) == 1
        ensure
          LibCrypto.evp_md_ctx_free(ctx)
          LibCrypto.evp_pkey_free(pkey)
        end
      end

      private def self.public_key(pem : String) : LibCrypto::EvpPKey
        body = pem.gsub(/-----(BEGIN|END) CERTIFICATE-----/, "").gsub(/\s+/, "")
        der = begin
          Base64.decode(body)
        rescue Base64::Error
          raise Error.new("certificat illisible")
        end
        certificate, _rest = OpenSSL::X509::Certificate.from_der?(der)
        raise Error.new("certificat illisible") if certificate.nil?
        pkey = LibCrypto.partiduo_x509_get_pubkey(certificate.to_unsafe)
        raise Error.new("clé publique illisible") if pkey.null?
        pkey
      end

      # SHA-256 et plus seulement : SHA-1 est refusé.
      private def self.digest_name(algorithm : String) : String
        case algorithm
        when /sha512\z/i then "SHA512"
        when /sha384\z/i then "SHA384"
        when /sha256\z/i then "SHA256"
        else
          raise Error.new("algorithme refusé : #{algorithm}")
        end
      end

      private def self.inclusive_prefixes(reference : XML::Node) : Array(String)
        transforms = child(reference, "Transforms")
        return [] of String if transforms.nil?
        transforms.children.each do |transform|
          next unless transform.element?
          if list = child(transform, "InclusiveNamespaces").try(&.["PrefixList"]?)
            return list.split(/\s+/).reject(&.empty?)
          end
        end
        [] of String
      end

      private def self.decode(value : String) : Bytes
        Base64.decode(value.gsub(/\s+/, ""))
      rescue Base64::Error
        raise Error.new("base64 invalide")
      end

      def self.child(node : XML::Node, name : String) : XML::Node?
        node.children.find { |item| item.element? && local_name(item) == name }
      end

      def self.first(node : XML::Node, name : String) : XML::Node?
        all(node, name).first?
      end

      # Descendants (et le nœud lui-même) de nom local `name` ; `*` : tous.
      def self.all(node : XML::Node, name : String, found = [] of XML::Node) : Array(XML::Node)
        found << node if node.element? && (name == "*" || local_name(node) == name)
        node.children.each { |item| all(item, name, found) if item.element? }
        found
      end

      def self.local_name(node : XML::Node) : String
        node.name.split(':').last
      end
    end

    Federation.register(SamlAdapter.new)
  end
end
