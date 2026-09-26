# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias AccountingApi = Partiduo::Api::Accounting

private def line(account, side, amount)
  AccountingApi::EntryLineInput.new(account, side, BigDecimal.new(amount))
end

describe_module "ACCOUNTING", Partiduo::Api::Accounting do
  describe ".check_entry" do
    it "accepte une écriture équilibrée et renvoie ses totaux" do
      input = AccountingApi::CheckEntryInput.new([
        line("604000", AccountingApi::Side::Debit, "100.00"),
        line("445660", AccountingApi::Side::Debit, "20.00"),
        line("401000", AccountingApi::Side::Credit, "120.00"),
      ])

      view = AccountingApi.check_entry(actor_with("accounting.entry.post"), input).value!

      view.total_debit.should eq(BigDecimal.new("120.00"))
      view.total_credit.should eq(BigDecimal.new("120.00"))
      view.balanced?.should be_true
    end

    it "refuse une écriture déséquilibrée, erreurs par champ en clés i18n" do
      input = AccountingApi::CheckEntryInput.new([
        line("604000", AccountingApi::Side::Debit, "100.01"),
        line("", AccountingApi::Side::Credit, "100.00"),
      ])

      result = AccountingApi.check_entry(actor_with("accounting.entry.post"), input)

      result.failure?.should be_true
      result.errors_for("lines[1].account").map(&.key).should eq(["accounting.errors.entry.account_missing"])
      unbalanced = result.errors_for("base").find!(&.key.==("accounting.errors.entry.unbalanced"))
      unbalanced.params["difference"].should eq("0.01")
    end

    it "refuse un montant nul ou à plus de quatre décimales" do
      input = AccountingApi::CheckEntryInput.new([
        line("604000", AccountingApi::Side::Debit, "0"),
        line("401000", AccountingApi::Side::Credit, "0.00001"),
      ])

      result = AccountingApi.check_entry(actor_with("accounting.entry.post"), input)

      result.errors_for("lines[0].amount").map(&.key).should eq(["accounting.errors.entry.amount_not_positive"])
      result.errors_for("lines[1].amount").map(&.key).should eq(["accounting.errors.entry.too_many_decimals"])
    end

    it "vérifie la permission" do
      input = AccountingApi::CheckEntryInput.new([] of AccountingApi::EntryLineInput)
      expect_raises(Partiduo::Api::Forbidden) { AccountingApi.check_entry(actor_with("accounting.entry.read"), input) }
    end
  end
end

describe "Partiduo::Api::Accounting sans le module Comptabilité" do
  it "refuse l'appel (ModuleDisabled)" do
    with_active_modules("invoicing") do
      input = AccountingApi::CheckEntryInput.new([] of AccountingApi::EntryLineInput)
      expect_raises(Partiduo::Api::ModuleDisabled) { AccountingApi.check_entry(Partiduo::Api::Actor.system, input) }
    end
  end
end
