# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  # Version du cœur. Les manifestes d'extension la comparent à `requires_core`.
  # Lue à la compilation dans `shard.yml`, seule source du numéro : chaque
  # commit y incrémente le dernier chiffre.
  VERSION = {{
              (read_file("#{__DIR__}/../../shard.yml")
                .lines
                .find(&.starts_with?("version:")) || "version: 0.0.0")
                .gsub(/^version:\s*/, "")
                .chomp
            }}

  # Version du contrat `Partiduo::Api` (ADR-003 D6, ADR-005 D1). Elle suit le
  # versionnage sémantique : toute rupture du contrat incrémente la majeure.
  API_VERSION = "0.6.0"
end

module Partiduo
  # Version du contrat de l'interface en ligne de commande d'instance
  # (`manage instance`, ADR-008 D4, `doc/api/instance-cli.adoc`), consommé
  # par l'exécutant de partiduo-admin. Versionnage sémantique : retirer ou
  # renommer une action, une clé JSON ou un code de sortie incrémente la
  # majeure ; en ajouter incrémente la mineure.
  INSTANCE_CLI_VERSION = "1.1.0"
end
