# SPDX-License-Identifier: AGPL-3.0-or-later

require "base64"
require "crypto/subtle"
require "openssl"

module Partiduo
  module Auth
    # Jetons aléatoires et empreintes. Un jeton remis au client (session,
    # invitation, défi) n'est jamais stocké en clair : seule son empreinte
    # SHA-256 l'est, et une fuite de la table ne donne aucun jeton utilisable.
    module Secrets
      # Jeton de 256 bits, en base64url sans remplissage.
      def self.token(bytes : Int32 = 32) : String
        base64url(Random::Secure.random_bytes(bytes))
      end

      def self.digest(value : String) : String
        OpenSSL::Digest.new("SHA256").update(value).final.hexstring
      end

      def self.base64url(bytes : Bytes) : String
        Base64.urlsafe_encode(bytes, padding: false)
      end

      # Décode du base64url (ou du base64 classique), remplissage facultatif ;
      # `nil` si la valeur est mal formée.
      def self.decode64?(value : String) : Bytes?
        normalized = value.strip.tr("-_", "+/").delete('=')
        return Bytes.empty if normalized.empty?
        normalized += "=" * ((4 - normalized.size % 4) % 4)
        Base64.decode(normalized)
      rescue Base64::Error
        nil
      end

      def self.equal?(a : String, b : String) : Bool
        Crypto::Subtle.constant_time_compare(a, b)
      end
    end
  end
end
