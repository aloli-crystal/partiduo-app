# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias Acc = Partiduo::Api::Accounting
private alias Mic = Partiduo::Api::Micro
private alias I = IntegrationSpec
private alias M = MicroSpec

# D-MIC2-001, D-MIC2-003 : une ligne modifiée ou supprimée dans une période
# ouverte ne désynchronise jamais la Comptabilité. Modification : écriture
# extournée, nouvelle écriture sous la même référence ; suppression :
# écriture extournée ; impossible côté Comptabilité : l'opération est refusée
# et rien ne change.

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
      signed = line.side.debit? ? line.amount : -line.amount
      totals[line.account_number] += signed
    end
  end
  totals.reject { |_, amount| amount.zero? }
end

# Élément tiré au hasard, `nil` pour une liste vide.
private def pick(list : Array(T), random : Random) : T? forall T
  list.empty? ? nil : list.sample(random)
end

# Invariant : chaque ligne saisie a exactement une écriture en vigueur, du
# montant de la ligne ; une ligne supprimée n'en a plus aucune et ses
# écritures se soldent.
private def expect_synchronized(deleted : Array(String) = [] of String) : Nil
  lines = Mic.receipts(M.system).map { |line| {"micro:receipt:#{line.id}", line} } +
          Mic.purchases(M.system).map { |line| {"micro:purchase:#{line.id}", line} }
  lines.each do |(source, line)|
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

describe "Micro-entreprise et Comptabilité — modification en période ouverte (D-MIC2-003)" do
  it "remplace l'écriture d'une recette modifiée : extourne puis nouvelle écriture" do
    with_active_modules("micro,accounting") do
      M.setup
      line = M.receipt("2026-09-10", "100")
      source = "micro:receipt:#{line.id}"
      Mic.update_receipt(M.actor, line.id, M.receipt_input("2026-09-12", "120", vat_amount: M.d("20"))).value!
      entries = I.entries(source)
      entries.size.should eq(3)
      entries.count(&.reversal?).should eq(1)
      entries.count(&.cancelled?).should eq(1)
      current = live(source).first
      current.date.should eq(M.date("2026-09-12"))
      lines = I.by_account(current)
      lines["510001"].should eq([{"debit", M.d("120")}])
      lines["706"].should eq([{"credit", M.d("100")}])
      lines["44571"].should eq([{"credit", M.d("20")}])
      net(source).should eq({"510001" => M.d("120"), "706" => M.d("-100"), "44571" => M.d("-20")})
      expect_synchronized
    end
  end

  it "ne touche pas l'écriture quand la modification ne la change pas" do
    with_active_modules("micro,accounting") do
      M.setup
      line = M.receipt("2026-09-10", "100")
      Mic.update_receipt(M.actor, line.id, M.receipt_input("2026-09-10", "100", reference: "F-99")).value!
      I.entries("micro:receipt:#{line.id}").size.should eq(1)
      expect_synchronized
    end
  end

  it "extourne l'écriture d'une ligne supprimée, recette ou achat" do
    with_active_modules("micro,accounting") do
      M.setup
      receipt = M.receipt("2026-09-10", "100")
      purchase = M.purchase("2026-09-12", "40")
      Mic.delete_receipt(M.actor, receipt.id).value!
      Mic.delete_purchase(M.actor, purchase.id).value!
      I.entries("micro:receipt:#{receipt.id}").size.should eq(2)
      expect_synchronized(["micro:receipt:#{receipt.id}", "micro:purchase:#{purchase.id}"])
    end
  end

  it "refuse la modification que la Comptabilité ne peut passer : registre et écriture inchangés" do
    with_active_modules("micro,accounting") do
      M.setup
      line = M.receipt("2026-01-10", "100")
      # 2025 n'a pas d'exercice : la Comptabilité refuse l'écriture, donc la
      # modification.
      refused = Mic.update_receipt(M.actor, line.id, M.receipt_input("2025-12-30", "100"))
      refused.failure?.should be_true
      refused.error_keys.should_not be_empty
      ReferentialSpec.expect_translated(refused)
      Mic.receipt(M.system, line.id).date.should eq(M.date("2026-01-10"))
      Mic.receipt(M.system, line.id).number.should eq(line.number)
      I.entries("micro:receipt:#{line.id}").size.should eq(1)
      expect_synchronized
    end
  end

  it "reste synchronisée au fil d'opérations mêlées (saisies, modifications, suppressions, contre-passations)" do
    with_active_modules("micro,accounting") do
      M.setup
      random = Random.new(20260929)
      deleted = [] of String
      natures = %w[SERVICE SALE FEE]
      30.times do
        receipts = Mic.receipts(M.system)
        case random.rand(5)
        when 0, 1
          M.receipt("2026-09-#{random.rand(1..26).to_s.rjust(2, '0')}", random.rand(10..500).to_s, natures.sample(random))
        when 2
          if line = pick(receipts.select(&.editable?), random)
            Mic.update_receipt(M.actor, line.id, M.receipt_input("2026-09-#{random.rand(1..26).to_s.rjust(2, '0')}",
              random.rand(10..500).to_s, natures.sample(random))).value!
          end
        when 3
          if line = pick(receipts.select(&.deletable?), random)
            Mic.delete_receipt(M.actor, line.id).value!
            deleted << "micro:receipt:#{line.id}"
          end
        else
          if line = pick(receipts.select(&.reversible?), random)
            Mic.reverse_receipt(M.actor, Mic::ReverseInput.new(line.id, Math.max(line.date, M.date("2026-09-20")))).value!
          end
        end
        expect_synchronized(deleted)
      end
      Mic.republish(M.actor)
      expect_synchronized(deleted)
    end
  end

  it "refuse de modifier une recette issue de la Facturation, laissée à ses écritures" do
    with_active_modules("micro,invoicing,accounting") do
      setup = I.setup
      Mic.set_item_nature(M.system, setup.item.id, M.nature("SERVICE").id).value!
      invoice = InvoicingSpec.issued(setup)
      sale = I.entry("invoice:#{invoice.id}")
      I.bank_receipt(setup.customer.code, "400", [I.line(sale, I.card_account(setup.customer.id)).id], "2026-09-20")
      line = Mic.receipts(M.system).first
      line.origin.should eq("invoicing")
      Mic.update_receipt(M.actor, line.id, M.receipt_input).error_keys.should eq(["micro.errors.line.change.from_invoicing"])
      Mic.delete_receipt(M.actor, line.id).error_keys.should eq(["micro.errors.line.change.from_invoicing"])
    end
  end
end

describe "Micro-entreprise et Facturation — encaissement d'une période déjà déclarée (D-MIC2-001)" do
  it "inscrit l'encaissement à la date du jour, sur la déclaration suivante" do
    with_active_modules("micro,invoicing") do
      setup = I.setup
      Mic.set_item_nature(M.system, setup.item.id, M.nature("SERVICE").id).value!
      invoice = InvoicingSpec.issued(setup)
      Partiduo::Config.travel_to(Time.utc(2026, 10, 5, 9)) do
        Mic.mark_declared(M.actor, Mic::DeclarationInput.new(M.date("2026-07-01"), M.date("2026-10-02"))).value!
        I.record_payment(invoice.id, "400", "2026-09-28", "cheque")
        receipts = Mic.receipts(M.system)
        receipts.sum(BigDecimal.new(0), &.amount).should eq(M.d("400"))
        receipts.map(&.date).uniq!.should eq([M.date("2026-10-05")])
        receipts.each(&.locked.should(be_false))
      end
    end
  end
end
