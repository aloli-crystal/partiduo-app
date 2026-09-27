# SPDX-License-Identifier: AGPL-3.0-or-later

require "./manifest"

module Partiduo
  # Module Facturation (ADR-006 D5) : devis, commandes, bons de livraison,
  # factures, acomptes, avoirs, règlements, relances, Factur-X. Jalon F.
  # Contrat : `Partiduo::Api::Invoicing` (link:doc/api/invoicing.adoc[]).
  module Invoicing
    class App < Marten::App
      label "invoicing"
    end
  end
end

require "./models/layout"
require "./models/document"
require "./models/counter"
require "./models/payment"
require "./models/reminder"
require "./models/email_log"
require "./models/document_event"
require "./models/settings"
require "./api/types"
require "./services/**"
require "./api/**"
