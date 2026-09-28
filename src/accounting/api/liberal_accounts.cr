# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    module Accounting
      # Paramétrage comptable du module liberal (ADR-007 D6) : compte par
      # nature (code de la nature, `RENT`), par rubrique de la 2035-A
      # (`rent`, `receipts`…), par catégorie d'immobilisation
      # (`asset_<catégorie>`) et `disposal` (produit de cession).
      record LiberalAccountView, key : String, account : AccountView

      def self.liberal_accounts(actor : Actor) : Array(LiberalAccountView)
        Guard.authorize!(actor, "accounting.account.read", module_code: MODULE_CODE)
        Partiduo::Accounting::LiberalAccount.all.order(:key).to_a.map do |row|
          LiberalAccountView.new(row.key.to_s, account_view(row.account!))
        end
      end

      # Définit (ou retire, `account` à `nil`) le compte d'une clé.
      def self.set_liberal_account(actor : Actor, key : String, account : String?) : Result(Nil)
        Guard.authorize!(actor, "accounting.account.write", module_code: MODULE_CODE)
        Transaction.run do
          unless key.matches?(/\A[A-Za-z0-9_]{1,40}\z/)
            next Result(Nil).failure(FieldError.new("key", "accounting.errors.liberal.key_invalid"))
          end
          row = Partiduo::Accounting::LiberalAccount.filter(key: key).first
          number = Partiduo::Accounting::Chart.normalize(account || "")
          if number.empty?
            row.try(&.delete)
            next Result(Nil).success(nil)
          end
          target = Partiduo::Accounting::Account.filter(number: number).first
          if target.nil?
            next Result(Nil).failure(FieldError.new("account", "accounting.errors.default_account.account.not_found",
              {"number" => number}))
          end
          unless target.direct_use
            next Result(Nil).failure(FieldError.new("account", "accounting.errors.liberal.not_direct_use",
              {"number" => number}))
          end
          row ||= Partiduo::Accounting::LiberalAccount.new(key: key)
          row.account = target
          row.save!
          Result(Nil).success(nil)
        end
      end
    end
  end
end
