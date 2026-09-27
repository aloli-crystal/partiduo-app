# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Core
    # Outils SQL du socle, partagés par `core`, `cards` et `vat`.
    module Db
      # Code SQLSTATE d'une violation de clé étrangère.
      FOREIGN_KEY_VIOLATION = "23503"

      # Supprime des lignes par SQL direct, dans un point de sauvegarde, en
      # vérifiant *immédiatement* les clés étrangères (Marten les déclare
      # `DEFERRABLE INITIALLY DEFERRED`). Renvoie `false`, sans rien supprimer,
      # si une ligne est encore référencée — par une écriture, une facture, une
      # autre fiche… — : le socle n'a pas à connaître les modules qui le citent.
      #
      # Le SQL direct contourne volontairement la suppression en cascade de
      # Marten : une référence posée par un module doit *protéger* la ligne,
      # jamais l'emporter avec elle.
      #
      # `statements` : requêtes exécutées dans l'ordre (les lignes dépendantes
      # propres au socle d'abord), chacune avec ses paramètres.
      def self.delete_unless_referenced(statements : Array({String, Array(::DB::Any)})) : Bool
        connection = Marten::DB::Connection.default
        deleted = false
        connection.transaction do
          connection.open do |db|
            db.exec("SAVEPOINT partiduo_delete")
            begin
              db.exec("SET CONSTRAINTS ALL IMMEDIATE")
              statements.each { |(sql, args)| db.exec(sql, args: args) }
              db.exec("SET CONSTRAINTS ALL DEFERRED")
              db.exec("RELEASE SAVEPOINT partiduo_delete")
              deleted = true
            rescue ex : PQ::PQError
              raise ex unless ex.field_message(:code) == FOREIGN_KEY_VIOLATION
              db.exec("ROLLBACK TO SAVEPOINT partiduo_delete")
              db.exec("SET CONSTRAINTS ALL DEFERRED")
            end
          end
        end
        deleted
      end

      # Les lignes sont-elles citées ailleurs ? Essai de suppression aussitôt
      # annulé (dans une transaction).
      def self.referenced?(statements : Array({String, Array(::DB::Any)})) : Bool
        connection = Marten::DB::Connection.default
        referenced = false
        connection.transaction do
          connection.open do |db|
            db.exec("SAVEPOINT partiduo_probe")
            referenced = !delete_unless_referenced(statements)
            db.exec("ROLLBACK TO SAVEPOINT partiduo_probe")
          end
        end
        referenced
      end

      # Violation d'une contrainte d'unicité ou d'exclusion (SQLSTATE 23505,
      # 23P01) : levée par PostgreSQL quand deux transactions concurrentes
      # passent le contrôle applicatif en même temps.
      def self.conflict?(ex : Exception) : Bool
        pq = ex.is_a?(PQ::PQError) ? ex : ex.cause.as?(PQ::PQError)
        return false if pq.nil?
        {"23505", "23P01"}.includes?(pq.field_message(:code))
      end
    end
  end
end
