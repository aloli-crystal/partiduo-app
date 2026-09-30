# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias Lib = Partiduo::Api::Liberal
private alias I = IntegrationSpec
private alias L = LiberalSpec

# D-LIB2-001, D-LIB2-002 : une ligne du livre-journal ou une immobilisation
# modifiée ou supprimée dans un exercice ouvert ne désynchronise jamais la
# Comptabilité. Modification : écriture extournée, nouvelle écriture sous la
# même référence ; suppression : écriture extournée ; impossible côté
# Comptabilité : l'opération est refusée et rien ne change.

# Écritures en vigueur (ni extourne, ni extournée) d'une référence.
private def live(source : String) : Array(Partiduo::Api::Accounting::EntryView)
  I.entries(source).reject { |entry| entry.cancelled? || entry.reversal? }
end

# Solde net par compte de toutes les écritures d'une référence, extournes
# comprises (débit positif).
private def net(source : String) : Hash(String, BigDecimal)
  totals = Hash(String, BigDecimal).new { BigDecimal.new(0) }
  I.entries(source).each do |entry|
    entry_lines = entry.lines
    entry_lines.each do |line|
      totals[line.account_number] += line.side.debit? ? line.amount : -line.amount
    end
  end
  totals.reject { |_, amount| amount.zero? }
end

private def pick(list : Array(T), random : Random) : T? forall T
  list.empty? ? nil : list.sample(random)
end

private def day(random : Random) : String
  "2026-0#{random.rand(1..8)}-#{random.rand(1..28).to_s.rjust(2, '0')}"
end

# Invariant : chaque ligne a exactement une écriture en vigueur, de son
# montant et de sa date, et ses écritures se soldent ; une ligne supprimée
# n'en a plus aucune.
private def expect_synchronized(deleted : Array(String) = [] of String) : Nil
  Lib.lines(L.system).each do |line|
    source = "liberal:#{line.kind}:#{line.id}"
    entries = live(source)
    entries.size.should eq(1)
    entries.first.amount.should eq(line.amount.abs)
    entries.first.date.should eq(line.date)
    net(source).values.sum(BigDecimal.new(0)).should eq(BigDecimal.new(0))
  end
  deleted.each do |source|
    live(source).should be_empty
    net(source).should be_empty
  end
end

describe "Profession libérale et Comptabilité — modification dans un exercice ouvert (D-LIB2-002)" do
  it "remplace l'écriture d'une dépense modifiée : extourne puis nouvelle écriture" do
    with_active_modules("liberal,accounting") do
      L.setup
      line = L.expense("2026-09-10", "800", "RENT")
      source = "liberal:expense:#{line.id}"
      Lib.update_line(L.actor, line.id, L.input("2026-09-12", "120", "OFFICE")).value!
      entries = I.entries(source)
      entries.size.should eq(3)
      entries.count(&.reversal?).should eq(1)
      entries.count(&.cancelled?).should eq(1)
      current = live(source).first
      current.date.should eq(L.date("2026-09-12"))
      lines = I.by_account(current)
      lines["510001"].should eq([{"credit", L.d("120")}])
      lines.has_key?("613").should be_false
      net(source).values.sum(BigDecimal.new(0)).should eq(BigDecimal.new(0))
      expect_synchronized
    end
  end

  it "ne touche pas l'écriture quand la modification ne la change pas" do
    with_active_modules("liberal,accounting") do
      L.setup
      line = L.receipt("2026-09-10", "100")
      Lib.update_line(L.actor, line.id, L.input("2026-09-10", "100", "RECEIPTS", reference: "F-99")).value!
      I.entries("liberal:receipt:#{line.id}").size.should eq(1)
      expect_synchronized
    end
  end

  it "extourne l'écriture d'une ligne ou d'une contre-passation supprimée" do
    with_active_modules("liberal,accounting") do
      L.setup
      receipt = L.receipt("2026-09-10", "100")
      expense = L.expense("2026-09-12", "40")
      reversal = Lib.reverse_line(L.actor, Lib::ReverseInput.new(expense.id, L.date("2026-09-13"))).value!
      Lib.delete_line(L.actor, receipt.id).value!
      Lib.delete_line(L.actor, reversal.id).value!
      I.entries("liberal:receipt:#{receipt.id}").size.should eq(2)
      expect_synchronized(["liberal:receipt:#{receipt.id}", "liberal:expense:#{reversal.id}"])
    end
  end

  it "remplace ou extourne les écritures d'une immobilisation et de sa cession" do
    with_active_modules("liberal,accounting") do
      L.setup
      asset = L.asset("2026-04-01", "3000", 3)
      Lib.update_asset(L.actor, asset.id, Lib::AssetInput.new(label: "Portable", category: "equipment",
        acquired_on: L.date("2026-04-02"), amount: L.d("3200"), duration_years: 4, method: "card")).value!
      current = live("liberal:asset:#{asset.id}")
      current.size.should eq(1)
      current.first.amount.should eq(L.d("3200"))
      net("liberal:asset:#{asset.id}").keys.sort!.should eq(["2154", "510001"])
      Lib.dispose_asset(L.actor, Lib::DisposalInput.new(asset.id, L.date("2026-08-01"), L.d("1000"), "cheque")).value!
      disposal = Lib.asset(L.system, asset.id).disposal || raise "cession absente"
      live("liberal:disposal:#{disposal.id}").size.should eq(1)
      Lib.delete_disposal(L.actor, asset.id).value!
      live("liberal:disposal:#{disposal.id}").should be_empty
      net("liberal:disposal:#{disposal.id}").should be_empty
      Lib.delete_asset(L.actor, asset.id).value!
      live("liberal:asset:#{asset.id}").should be_empty
      net("liberal:asset:#{asset.id}").should be_empty
    end
  end

  it "refuse la modification que la Comptabilité ne peut passer : livre-journal et écriture inchangés" do
    with_active_modules("liberal,accounting") do
      L.setup
      line = L.receipt("2026-01-10", "100")
      # 2025 n'a pas d'exercice : la Comptabilité refuse l'écriture, donc la
      # modification.
      refused = Lib.update_line(L.actor, line.id, L.input("2025-12-30", "100", "RECEIPTS"))
      refused.failure?.should be_true
      refused.error_keys.should_not be_empty
      ReferentialSpec.expect_translated(refused)
      Lib.line(L.system, line.id).date.should eq(L.date("2026-01-10"))
      Lib.line(L.system, line.id).number.should eq(line.number)
      I.entries("liberal:receipt:#{line.id}").size.should eq(1)
      expect_synchronized
    end
  end

  it "reste synchronisée au fil d'opérations mêlées (saisies, modifications, suppressions, contre-passations)" do
    with_active_modules("liberal,accounting") do
      L.setup
      random = Random.new(20260930)
      deleted = [] of String
      natures = {"receipt" => %w[RECEIPTS FINANCIAL_INCOME], "expense" => %w[OFFICE RENT TRAVEL]}
      40.times do
        lines = Lib.lines(L.system)
        case random.rand(6)
        when 0, 1
          kind = %w[receipt expense].sample(random)
          nature = natures[kind].sample(random)
          kind == "receipt" ? L.receipt(day(random), random.rand(10..500).to_s, nature) : L.expense(day(random), random.rand(10..500).to_s, nature)
        when 2, 3
          if line = pick(lines.select(&.editable?), random)
            Lib.update_line(L.actor, line.id, L.input(day(random), random.rand(10..500).to_s,
              natures[line.kind].sample(random))).value!
          end
        when 4
          if line = pick(lines.select(&.deletable?), random)
            Lib.delete_line(L.actor, line.id).value!
            deleted << "liberal:#{line.kind}:#{line.id}"
          end
        else
          if line = pick(lines.select(&.reversible?), random)
            Lib.reverse_line(L.actor, Lib::ReverseInput.new(line.id, Math.max(line.date, L.date("2026-09-01")))).value!
          end
        end
        expect_synchronized(deleted)
      end
      Lib.republish(L.actor)
      expect_synchronized(deleted)
    end
  end

  it "refuse de modifier une recette issue de la Facturation, laissée à ses écritures" do
    with_active_modules("liberal,invoicing,accounting") do
      setup = I.setup
      invoice = InvoicingSpec.issued(setup)
      sale = I.entry("invoice:#{invoice.id}")
      I.bank_receipt(setup.customer.code, "400", [I.line(sale, I.card_account(setup.customer.id)).id], "2026-09-20")
      line = Lib.lines(L.system).first
      line.origin.should eq("invoicing")
      {line.editable?, line.deletable?}.should eq({false, false})
      Lib.update_line(L.actor, line.id, L.input("2026-09-20", "1", "RECEIPTS")).error_keys
        .should eq(["liberal.errors.line.change.from_invoicing"])
      Lib.delete_line(L.actor, line.id).error_keys.should eq(["liberal.errors.line.change.from_invoicing"])
    end
  end
end

describe "Profession libérale et Facturation — encaissement dans un exercice figé (D-LIB2-001)" do
  it "inscrit l'encaissement à la date du jour, dans l'exercice ouvert" do
    with_active_modules("liberal,invoicing") do
      setup = I.setup
      invoice = InvoicingSpec.issued(setup)
      Partiduo::Api::Transaction.run do
        Partiduo::Events.publish("tax_return.transmitted", {"form" => "2035", "year" => "2025", "reference" => "x"})
        Partiduo::Api::Result(Nil).success(nil)
      end
      I.record_payment(invoice.id, "400", "2025-12-28", "cheque")
      lines = Lib.lines(L.system)
      lines.map(&.date).should eq([Partiduo::Config.today])
      lines.first.locked.should be_false
    end
  end
end
