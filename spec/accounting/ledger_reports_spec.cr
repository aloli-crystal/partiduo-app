# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Grand livre (`impress_gl_comptes`, `impress_poste`) et journaux
# (`impress_jrn`).

private alias Api = Partiduo::Api::Accounting

private def system
  Partiduo::Api::Actor.system
end

private def d(text : String) : BigDecimal
  BigDecimal.new(text)
end

private def date(text : String) : Time
  EntrySpec.date(text)
end

describe_module "ACCOUNTING", "Grand livre et journaux" do
  describe ".general_ledger" do
    it "liste les mouvements par compte avec solde progressif" do
      data = ReportSpec.dataset
      view = Api.general_ledger(system)
      view.by_card.should be_false
      view.total_debit.should eq(d("12880"))
      view.total_credit.should eq(d("12880"))
      section = view.sections.find!(&.key.==(EntrySpec.card_account(data.customer)))
      section.opening_balance.should eq(0)
      section.lines.map(&.balance).should eq([d("1200"), d("600"), d("960")])
      section.lines.first.card_code.should eq(data.customer.code)
      section.lines.first.ledger_code.should eq("V01")
      section.lines.first.receipt.should eq(data.sale.receipt)
      section.lines[0].matching_code.should_not be_nil
      section.lines[0].matching_code.should eq(section.lines[1].matching_code)
      section.closing_balance.should eq(d("960"))
      view.sections.map(&.key).should eq(view.sections.map(&.key).sort!)
    end

    it "part du solde d'ouverture et borne les comptes" do
      data = ReportSpec.dataset
      account = EntrySpec.card_account(data.customer)
      view = Api.general_ledger(system, Api::GeneralLedgerQuery.new(date_from: date("2026-04-01"),
        account_from: account, account_to: account))
      view.sections.size.should eq(1)
      section = view.sections.first
      section.opening_balance.should eq(d("600"))
      section.lines.map(&.balance).should eq([d("960")])
      # Compte sans mouvement ni solde : absent ; compte soldé avant la
      # période mais avec un solde d'ouverture : présent.
      capital = Api.general_ledger(system, Api::GeneralLedgerQuery.new(date_from: date("2026-04-01"), account_from: "101",
        account_to: "101"))
      capital.sections.first.lines.should be_empty
      capital.sections.first.opening_balance.should eq(d("-10000"))
    end

    it "regroupe par fiche (grand livre des tiers)" do
      data = ReportSpec.dataset
      view = Api.general_ledger(system, Api::GeneralLedgerQuery.new(by_card: true))
      view.by_card.should be_true
      view.sections.map(&.key).should eq([data.customer.code, data.supplier.code])
      view.sections.first.label.should eq("Client Alpha")
      view.sections.first.closing_balance.should eq(d("960"))
      view.sections.last.closing_balance.should eq(d("-600"))
      one = Api.general_ledger(system, Api::GeneralLedgerQuery.new(card: data.supplier.code))
      one.sections.map(&.key).should eq([data.supplier.code])
      expect_raises(Partiduo::Api::NotFound) { Api.general_ledger(system, Api::GeneralLedgerQuery.new(card: "INCONNU")) }
    end
  end

  describe ".journals" do
    it "reproduit chaque journal avec ses écritures, ses totaux par mois et par compte" do
      data = ReportSpec.dataset
      view = Api.journals(system, Api::JournalQuery.new(date_to: date("2026-12-31")))
      view.ledgers.map(&.ledger_code).should eq(%w[A01 F01 O01 V01])
      view.entries.should eq(6)
      view.total_debit.should eq(d("12880"))
      view.total_credit.should eq(view.total_debit)
      sales = view.ledgers.find!(&.ledger_code.==("V01"))
      sales.ledger_kind.should eq(Api::LedgerKind::Sale)
      sales.entries.map(&.entry_id).first.should eq(data.sale.id)
      sales.entries.first.debit.should eq(d("1200"))
      sales.entries.first.lines.size.should eq(data.sale.lines.size)
      sales.months.map(&.key).should eq(%w[2026-02 2026-07])
      sales.months.map(&.debit).should eq([d("1200"), d("360")])
      sales.accounts.find!(&.key.==("706")).credit.should eq(d("1300"))
      sales.accounts.find!(&.key.==("706")).entries.should eq(2)
      sales.total_debit.should eq(d("1560"))

      only = Api.journals(system, Api::JournalQuery.new(ledger_ids: [EntrySpec.ledger("A01").id],
        date_from: date("2026-02-01"), date_to: date("2026-02-28")))
      only.ledgers.map(&.ledger_code).should eq(%w[A01])
      only.entries.should eq(1)
    end

    it "garde l'écriture annulée et son extourne" do
      ReportSpec.dataset
      entry = EntrySpec.post_misc([EntrySpec.debit("681", "10"), EntrySpec.credit("281", "10")], "2026-08-01")
      reversal = Api.cancel_entry(system, Api::CancelEntryInput.new(entry_id: entry.id, date: date("2026-08-02"))).value!
      misc = Api.journals(system).ledgers.find!(&.ledger_code.==("O01"))
      ids = misc.entries.map(&.entry_id)
      ids.should contain(entry.id)
      ids.should contain(reversal.id)
      misc.entries.find!(&.entry_id.==(reversal.id)).reversal_of_id.should eq(entry.id)
    end
  end
end
