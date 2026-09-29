# SPDX-License-Identifier: AGPL-3.0-or-later

# Droits par dépôt, par profil (`profile_sec_repository` d'origine ;
# DECISIONS D-STK-006 révisée, D-R5-015) : `R` lecture, `W` écriture. Un
# profil sans ligne garde les droits globaux du Stock ; dès qu'il en a une,
# il ne voit que les dépôts cités. Les lignes disparaissent avec leur profil
# ou leur dépôt.
class Migration::Stock::V0002 < Marten::Migration
  depends_on :stock, "0001_stock"

  def plan
    create_table :stock_repository_access do
      column :id, :big_int, primary_key: true, auto: true
      column :profile_id, :big_int
      column :repository_id, :big_int
      column :access, :string, max_size: 1
      column :created_at, :date_time
      column :updated_at, :date_time
      unique_constraint :stock_repository_access_unique, [:profile_id, :repository_id]
    end

    execute(<<-SQL, "SELECT 1")
        ALTER TABLE stock_repository_access
          ADD CONSTRAINT stock_repository_access_check CHECK (access IN ('R', 'W')),
          ADD CONSTRAINT stock_repository_access_profile_fk FOREIGN KEY (profile_id)
            REFERENCES auth_profile (id) ON DELETE CASCADE,
          ADD CONSTRAINT stock_repository_access_repository_fk FOREIGN KEY (repository_id)
            REFERENCES stock_repository (id) ON DELETE CASCADE
      SQL
  end
end
