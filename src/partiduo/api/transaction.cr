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
    #
    # *Imbrication* (D-024) : une commande appelée dans une autre (chargeur de
    # données initiales, abonné d'événement) s'exécute dans un point de
    # sauvegarde. Son échec n'annule que ses propres écritures et lui est
    # renvoyé tel quel (`Result` en échec, erreurs par champ) ; l'appelant
    # décide. Les effets extérieurs (`Events.after_commit`) enregistrés dans un
    # point de sauvegarde annulé sont abandonnés.
    module Transaction
      @@savepoints = 0_u64
      @@frames = {} of UInt64 => Array(Array(-> Nil))
      @@mutex = Mutex.new

      def self.run(& : -> Result(T)) : Result(T) forall T
        connection = Marten::DB::Connection.default
        return nested(connection) { yield } if connection.in_transaction?

        result = nil
        connection.transaction do
          outcome = yield
          result = outcome
          raise Marten::DB::Errors::Rollback.new if outcome.failure?
        end
        result || raise "transaction interrompue sans résultat"
      end

      # Effet extérieur à exécuter à la validation : rattaché au point de
      # sauvegarde courant s'il y en a un (abandonné s'il est annulé), sinon à
      # la transaction. Appelé par `Partiduo::Events.after_commit`.
      def self.after_commit(block : -> Nil) : Nil
        connection = Marten::DB::Connection.default
        unless connection.in_transaction?
          block.call
          return
        end
        if frame = current_frames.last?
          frame << block
        else
          connection.observe_transaction_commit(block)
        end
      end

      private def self.nested(connection, & : -> Result(T)) : Result(T) forall T
        name = @@mutex.synchronize { "partiduo_cmd_#{@@savepoints += 1}" }
        connection.open(&.exec("SAVEPOINT #{name}"))
        frames = current_frames
        frames << [] of -> Nil
        outcome = begin
          yield
        rescue ex
          frames.pop
          rollback_to(connection, name)
          raise ex
        end
        blocks = frames.pop
        if outcome.failure?
          rollback_to(connection, name)
        else
          connection.open(&.exec("RELEASE SAVEPOINT #{name}"))
          blocks.each { |block| after_commit(block) }
        end
        outcome
      ensure
        @@mutex.synchronize { @@frames.delete(Fiber.current.object_id) if @@frames[Fiber.current.object_id]?.try(&.empty?) }
      end

      private def self.rollback_to(connection, name : String) : Nil
        connection.open do |db|
          db.exec("ROLLBACK TO SAVEPOINT #{name}")
          db.exec("RELEASE SAVEPOINT #{name}")
        end
      end

      private def self.current_frames : Array(Array(-> Nil))
        @@mutex.synchronize { @@frames[Fiber.current.object_id] ||= [] of Array(-> Nil) }
      end
    end
  end
end
