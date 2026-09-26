# SPDX-License-Identifier: AGPL-3.0-or-later

require "./manifest"

module Partiduo
  # Module Facturation (ADR-006 D5) : devis, commandes, bons de livraison,
  # factures, acomptes, avoirs, règlements, relances, Factur-X. Jalon F.
  module Invoicing
    class App < Marten::App
      label "invoicing"
    end
  end
end
