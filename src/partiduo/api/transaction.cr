# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    # Exécute le corps d'une commande dans une transaction : si le bloc renvoie
    # un échec, tout est annulé ; s'il lève une exception, aussi (et elle est
    # propagée). Les événements publiés dans le bloc le sont dans la même
    # transaction (ADR-003 D7) : un abonné qui lève annule l'opération.
    #
    # ```
    # Transaction.run do
    #   entry = ...save!
    #   Partiduo::Events.publish("entry.posted", {"entry_id" => entry.pk.to_s})
    #   Result(EntryView).success(EntryView.from(entry))
    # end
    # ```
    module Transaction
      def self.run(& : -> Result(T)) : Result(T) forall T
        result = nil
        Marten::DB::Connection.default.transaction do
          outcome = yield
          result = outcome
          raise Marten::DB::Errors::Rollback.new if outcome.failure?
        end
        result || raise "transaction interrompue sans résultat"
      end
    end
  end
end
