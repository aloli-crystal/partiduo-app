# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    # Contrat du module Comptabilité — comptes de TVA des taux du socle
    # (héritiers de `tva_rate.tva_poste`, D-ACC-009) : compte de TVA
    # déductible et compte de TVA collectée de chaque taux, pour ventiler la
    # TVA des achats et des ventes (lot 2).
    module Accounting
      # Comptes de TVA de tous les taux paramétrés, par code de taux.
      def self.vat_rate_accounts(actor : Actor) : Array(VatRateAccountsView)
        Guard.authorize!(actor, "accounting.account.read", module_code: MODULE_CODE)
        rates = Partiduo::Api::Vat.rates(Actor.system, include_disabled: true).to_h { |rate| {rate.id, rate.code} }
        Partiduo::Accounting::VatRateAccount.all.to_a.compact_map do |row|
          code = rates[row.vat_rate_id!.to_i64]? || next
          vat_rate_accounts_view(row, code)
        end.sort_by!(&.vat_rate_code)
      end

      # Comptes de TVA d'un taux ; `nil` s'il n'est pas paramétré.
      def self.vat_rate_account(actor : Actor, vat_rate_id : Int64) : VatRateAccountsView?
        Guard.authorize!(actor, "accounting.account.read", module_code: MODULE_CODE)
        rate = Partiduo::Api::Vat.rate(Actor.system, vat_rate_id)
        Partiduo::Accounting::VatRateAccount.filter(vat_rate_id: vat_rate_id).first.try do |row|
          vat_rate_accounts_view(row, rate.code)
        end
      end

      # Fixe les comptes de TVA d'un taux (comptes existants, utilisables
      # directement ; les deux pour un taux autoliquidé).
      def self.set_vat_rate_accounts(actor : Actor, input : VatRateAccountsInput) : Result(VatRateAccountsView)
        Guard.authorize!(actor, "accounting.account.write", module_code: MODULE_CODE)
        Transaction.run do
          rate = begin
            Partiduo::Api::Vat.rate(Actor.system, input.vat_rate_id)
          rescue NotFound
            next Result(VatRateAccountsView).failure(
              FieldError.new("vat_rate_id", "accounting.errors.vat_rate_account.vat_rate_id.not_found"))
          end
          errors = [] of FieldError
          deductible = vat_account(input.deductible_account, "deductible_account", errors)
          collected = vat_account(input.collected_account, "collected_account", errors)
          if rate.reverse_charge
            errors << FieldError.new("deductible_account", "accounting.errors.vat_rate_account.account.required") if deductible.nil? && errors.none?(&.field.==("deductible_account"))
            errors << FieldError.new("collected_account", "accounting.errors.vat_rate_account.account.required") if collected.nil? && errors.none?(&.field.==("collected_account"))
          end
          next Result(VatRateAccountsView).failure(errors) unless errors.empty?

          row = Partiduo::Accounting::VatRateAccount.filter(vat_rate_id: rate.id).first ||
                Partiduo::Accounting::VatRateAccount.new(vat_rate_id: rate.id)
          row.deductible_account = deductible
          row.collected_account = collected
          row.save!
          Result(VatRateAccountsView).success(vat_rate_accounts_view(row, rate.code))
        end
      end

      private def self.vat_account(number : String?, field : String, errors : Array(FieldError)) : Partiduo::Accounting::Account?
        normalized = Partiduo::Accounting::Chart.normalize(number || "")
        return if normalized.empty?
        account = Partiduo::Accounting::Account.filter(number: normalized).first
        if account.nil?
          errors << FieldError.new(field, "accounting.errors.vat_rate_account.account.not_found", {"number" => normalized})
        elsif !account.direct_use
          errors << FieldError.new(field, "accounting.errors.vat_rate_account.account.not_direct_use", {"number" => normalized})
        end
        account
      end

      private def self.vat_rate_accounts_view(row : Partiduo::Accounting::VatRateAccount, code : String) : VatRateAccountsView
        VatRateAccountsView.new(row.vat_rate_id!.to_i64, code,
          row.deductible_account.try { |account| account_view(account) },
          row.collected_account.try { |account| account_view(account) })
      end
    end
  end
end
