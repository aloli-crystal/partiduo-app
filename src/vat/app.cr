# SPDX-License-Identifier: AGPL-3.0-or-later

require "./manifest"
require "./models/**"
require "./services/**"
require "./api/**"
require "./be/**"
require "./fr/**"
require "./initial_data"

module Partiduo
  # Socle : taux de TVA et régime du dossier. Les spécificités nationales sont
  # isolées dans `Vat::Be` (`be/`) et `Vat::Fr` (`fr/`) : formulaires,
  # règles par défaut et fichiers des déclarations, dont le moteur
  # (`Vat::Returns`) et les tables sont au socle ; le calcul depuis les
  # écritures et le contrat relèvent du module Comptabilité (lot 4,
  # D-TVA-001).
  module Vat
    class App < Marten::App
      label "vat"
    end
  end
end
