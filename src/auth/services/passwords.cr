# SPDX-License-Identifier: AGPL-3.0-or-later

# Seul le hachage d'authn : `require "authn"` charge aussi `jwt`, dont
# `openssl_ext` entre en conflit avec `jose` (voir BLOCAGES B-AUTH-002).
require "authn/password"

module Partiduo
  module Auth
    # Mots de passe : règles de `password-policy` (CNIL 2022-100), hachage
    # BCrypt par `authn` (ADR-002 D1).
    module Passwords
      # Empreinte BCrypt d'un mot de passe connu de personne, comparée quand
      # l'adresse saisie ne correspond à aucun compte : la réponse prend le
      # même temps, et ne dit pas si le compte existe.
      @@decoy : String?

      # Erreurs de saisie du mot de passe, rattachées à `field`. Clés :
      # `auth.errors.password.<motif>` (motifs de `PasswordPolicy::Violation`).
      def self.errors(password : String, field : String = "password",
                      forbidden : Enumerable(String) = [] of String) : Array(Partiduo::Api::FieldError)
        policy = Config.password_policy
        params = {
          "minimum"   => policy.minimum_length.to_s,
          "maximum"   => policy.maximum_length.to_s,
          "max_bytes" => policy.maximum_bytesize.to_s,
        }
        errors = policy.validate(password).map do |violation|
          Partiduo::Api::FieldError.new(field, "auth.errors.password.#{violation.to_s.underscore}", params)
        end
        lowered = password.downcase
        if !password.empty? && forbidden.any? { |word| !word.empty? && lowered.includes?(word.downcase) }
          errors << Partiduo::Api::FieldError.new(field, "auth.errors.password.personal", params)
        end
        errors
      end

      # Mots que le mot de passe ne doit pas contenir : partie locale de
      # l'adresse, prénom, nom (quatre caractères au moins).
      def self.personal_words(email : String, first_name : String, last_name : String) : Array(String)
        [email.split('@').first? || "", first_name, last_name].select { |word| word.size >= 4 }
      end

      def self.hash(password : String) : String
        Authn::Password.hash(password, cost: Config.bcrypt_cost, policy: Config.password_policy)
      end

      def self.verify(user : User?, password : String) : Bool
        hash = user.try(&.password)
        if user.nil? || hash.nil? || !user.usable_password?
          Authn::Password.verify(password, decoy)
          return false
        end
        Authn::Password.verify(password, hash)
      end

      private def self.decoy : String
        @@decoy ||= Authn::Password.hash(Secrets.token, cost: Config.bcrypt_cost)
      end
    end
  end
end
