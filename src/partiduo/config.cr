# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  # Configuration d'une instance, lue dans son environnement (ADR-001 D2 :
  # « la configuration d'une instance tient dans son environnement »).
  #
  # [cols="1,3"]
  # |===
  # |`DATABASE_URL`     |URL PostgreSQL, par socket Unix : `postgres:///partiduo_dev?host=/tmp`
  # |`PARTIDUO_MODULES` |modules et extensions actifs, séparés par des virgules (`accounting,invoicing`)
  # |`PARTIDUO_DOMAIN`  |domaine des instances (`partiduo.localhost` en développement)
  # |===
  module Config
    # Modules activables officiels, dans l'ordre de l'ADR-006 D1 (sans le Stock, lot 6).
    DEFAULT_MODULES = %w[accounting invoicing analytic]

    DEFAULT_DOMAIN = "partiduo.localhost"

    # URL de connexion à la base de l'instance.
    #
    # Sans `DATABASE_URL`, la base par défaut dépend de l'environnement Marten :
    # `partiduo_test` en test, `partiduo_dev` sinon — toujours par socket Unix.
    def self.database_url : String
      ENV["DATABASE_URL"]?.presence || default_database_url
    end

    def self.default_database_url : String
      name = ENV["MARTEN_ENV"]? == "test" ? "partiduo_test" : "partiduo_dev"
      "postgres:///#{name}?host=/tmp"
    end

    # Codes (en minuscules) des modules et extensions actifs sur l'instance.
    #
    # `PARTIDUO_MODULES` absent : tous les modules officiels. Vide (`""`) ou
    # `none` : le socle seul.
    def self.active_module_codes : Set(String)
      raw = ENV["PARTIDUO_MODULES"]?
      return DEFAULT_MODULES.to_set if raw.nil?
      return Set(String).new if raw.strip.downcase == "none"

      raw.split(',').map(&.strip.downcase).reject(&.empty?).to_set
    end

    # Domaine sous lequel les instances sont servies (`<dossier>.<domaine>`),
    # qui sert aussi d'identifiant de la partie de confiance WebAuthn (ADR-002 D5).
    def self.domain : String
      ENV["PARTIDUO_DOMAIN"]?.presence || DEFAULT_DOMAIN
    end
  end
end
