# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    module Accounting
      # Paramétrage comptable des registres de la micro-entreprise (ADR-007
      # D2) : compte de contrepartie par nature (code de la nature, `SALE`)
      # ou par catégorie (`sale_bic`, `service_bic`, `bnc`, `goods`, `other`,
      # et `vat` pour la TVA collectée).
      record MicroAccountView, key : String, account : AccountView

      def self.micro_accounts(actor : Actor) : Array(MicroAccountView)
        Guard.authorize!(actor, "accounting.account.read", module_code: MODULE_CODE)
        Partiduo::Accounting::MicroAccount.all.order(:key).to_a.map do |row|
          MicroAccountView.new(row.key.to_s, account_view(row.account!))
        end
      end

      # Définit (ou retire, `account` à `nil`) le compte d'une nature ou
      # d'une catégorie.
      def self.set_micro_account(actor : Actor, key : String, account : String?) : Result(Nil)
        Guard.authorize!(actor, "accounting.account.write", module_code: MODULE_CODE)
        Transaction.run do
          unless key.matches?(/\A[A-Za-z0-9_]{1,26}\z/)
            next Result(Nil).failure(FieldError.new("key", "accounting.errors.micro.key_invalid"))
          end
          row = Partiduo::Accounting::MicroAccount.filter(key: key).first
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
            next Result(Nil).failure(FieldError.new("account", "accounting.errors.micro.not_direct_use", {"number" => number}))
          end
          row ||= Partiduo::Accounting::MicroAccount.new(key: key)
          row.account = target
          row.save!
          Result(Nil).success(nil)
        end
      end
    end
  end
end
