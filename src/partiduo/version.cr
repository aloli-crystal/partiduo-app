# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  # Version du cœur. Les manifestes d'extension la comparent à `requires_core`.
  VERSION = "0.1.0"

  # Version du contrat `Partiduo::Api` (ADR-003 D6, ADR-005 D1). Elle suit le
  # versionnage sémantique : toute rupture du contrat incrémente la majeure.
  API_VERSION = "0.5.0"
end
