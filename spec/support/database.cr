# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module SpecSupport
    # Reconstruit le schéma de la base de test *par les migrations*, et non par
    # la synchronisation des modèles de `marten/spec` : les contraintes et
    # déclencheurs posés en SQL par les migrations (équilibre des écritures,
    # périodes closes…) doivent exister pendant les specs.
    def self.migrate_fresh! : Nil
      connection = Marten::DB::Connection.default
      name = Marten.settings.databases.first.name.to_s
      unless name.includes?("test")
        raise "Base de test refusée : « #{name} » ne contient pas « test » (voir DATABASE_URL)."
      end

      connection.open do |db|
        db.exec("DROP SCHEMA public CASCADE")
        db.exec("CREATE SCHEMA public")
      end
      Marten::DB::Management::Migrations::Runner.new(connection).execute
    end
  end
end

# Enregistré après celui de `marten/spec` (synchronisation des modèles) : on
# repart d'un schéma vide et on applique les migrations.
Spec.before_suite { Partiduo::SpecSupport.migrate_fresh! }
