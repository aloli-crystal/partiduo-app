# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Auth
    # Droits par journal, héritiers de `user_sec_jrn` et de
    # `Noalyss_user::get_ledger_access` : écriture partout pour un profil
    # administrateur ou si la sécurité des journaux est désactivée pour
    # l'utilisateur ; sinon le droit enregistré, et `X` (aucun) à défaut.
    module Ledgers
      def self.access(user : User, ledger_id : Int64) : String
        return "W" if Permissions.all_ledgers?(user) || user.ledger_security != true
        LedgerAccess.filter(user_id: user.pk, ledger_id: ledger_id).first.try(&.access.to_s) || "X"
      end

      def self.set(user : User, ledger_id : Int64, access : String) : LedgerAccess
        row = LedgerAccess.filter(user_id: user.pk, ledger_id: ledger_id).first ||
              LedgerAccess.new(user: user, ledger_id: ledger_id)
        row.access = access
        row.save!
        row
      end
    end
  end
end
