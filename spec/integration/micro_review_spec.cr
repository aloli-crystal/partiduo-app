# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias Acc = Partiduo::Api::Accounting
private alias Inv = Partiduo::Api::Invoicing
private alias Mic = Partiduo::Api::Micro
private alias I = IntegrationSpec
private alias M = MicroSpec

# Clôture du lot G (relecture) : lettrage fusionné puis défait, règlement
# saisi dans la Facturation puis lettré par la Comptabilité, remboursement
# noté par contre-passation, TVA déductible des achats, TVA ventilée par
# taux entre natures. Chaque groupe fixe sa configuration de modules.

private def micro_setup : InvoicingSpec::Setup
  setup = I.setup
  Mic.set_item_nature(M.system, setup.item.id, M.nature("SERVICE").id).value!
  setup
end

private def total(lines : Array(Mic::LineView)) : BigDecimal
  lines.sum(BigDecimal.new(0), &.amount)
end

describe "Micro-entreprise, Facturation et Comptabilité — lettrages et remboursements" do
  it "ne compte pas deux fois une facture après un lettrage fusionné, défait puis refait" do
    with_active_modules("micro,invoicing,accounting") do
      setup = micro_setup
      invoice = InvoicingSpec.issued(setup) # 1 019,76 TTC
      customer_account = I.card_account(setup.customer.id)
      customer_line = I.line(I.entry("invoice:#{invoice.id}"), customer_account).id
      deposit = I.bank_receipt(setup.customer.code, "400", [customer_line], "2026-09-20")
      total(Mic.receipts(M.system)).should eq(M.d("400"))

      # Solde encaissé puis lettré avec la facture et l'acompte : fusion.
      balance = I.bank_receipt(setup.customer.code, "619.76", [] of Int64, "2026-09-22")
      lines = [customer_line, I.line(deposit, customer_account).id, I.line(balance, customer_account).id]
      merged = Acc.match_lines(M.system, lines).value!
      total(Mic.receipts(M.system)).should eq(M.d("1019.76"))

      # Délettrage du lettrage fusionné : toute la facture est rouverte.
      Acc.unmatch(M.system, merged.id).value!
      total(Mic.receipts(M.system)).should eq(BigDecimal.new(0))
      I.document(invoice.id).totals.paid.should eq(BigDecimal.new(0))

      # Nouveau lettrage de l'ensemble : une seule fois le montant de la facture.
      Acc.match_lines(M.system, lines).value!
      total(Mic.receipts(M.system)).should eq(M.d("1019.76"))
      I.document(invoice.id).totals.paid.should eq(M.d("1019.76"))
    end
  end

  it "n'inscrit qu'une recette pour un règlement saisi dans la Facturation puis lettré par la Comptabilité" do
    with_active_modules("micro,invoicing,accounting") do
      setup = micro_setup
      invoice = InvoicingSpec.issued(setup)
      # Règlement saisi quand la Comptabilité était inactive (elle refuse
      # sinon la saisie dans la Facturation) : `payment.recorded`.
      payment = with_active_modules("micro,invoicing") { I.record_payment(invoice.id, "400", "2026-09-20") }
      total(Mic.receipts(M.system)).should eq(M.d("400"))
      # La Comptabilité passe l'historique : écriture `payment:`, lettrée
      # d'office avec la facture ; `payment.matched` n'en compte rien.
      Acc.post_invoicing_history(M.system).value!.posted.map(&.source).should eq(["payment:#{payment.id}"])
      I.entry("payment:#{payment.id}").lines.compact_map(&.matching_id).should_not be_empty
      receipts = Mic.receipts(M.system)
      total(receipts).should eq(M.d("400"))
      receipts.map(&.source).uniq!.should eq(["payment:#{payment.id}"])
      receipts.each { |line| I.entries("micro:receipt:#{line.id}").should be_empty }
    end
  end

  it "comptabilise le remboursement d'une recette issue de la Facturation noté par contre-passation" do
    with_active_modules("micro,invoicing,accounting") do
      setup = micro_setup
      invoice = InvoicingSpec.issued(setup, lines: [InvoicingSpec.line(setup, "1")]) # 80 HT, 96 TTC
      customer_line = I.line(I.entry("invoice:#{invoice.id}"), I.card_account(setup.customer.id)).id
      I.bank_receipt(setup.customer.code, "96", [customer_line], "2026-09-20")
      receipt = Mic.receipts(M.system).first
      receipt.origin.should eq("invoicing")
      refund = Mic.reverse_receipt(M.actor, Mic::ReverseInput.new(receipt.id, M.date("2026-09-25"))).value!
      refund.origin.should eq("manual")
      refund.source.should eq(receipt.source)
      lines = I.by_account(I.entry("micro:receipt:#{refund.id}"))
      lines["706"].should eq([{"debit", M.d("80")}])
      lines["44571"].should eq([{"debit", M.d("16")}])
      lines["510001"].should eq([{"credit", M.d("96")}])
    end
  end
end

describe "Micro-entreprise et Comptabilité — TVA déductible des achats" do
  it "passe la charge hors taxe et la TVA déductible, et les contre-passe" do
    with_active_modules("micro,accounting") do
      M.setup
      purchase = M.purchase("2026-09-12", "120", "GOODS", vat_amount: M.d("20"))
      lines = I.by_account(I.entry("micro:purchase:#{purchase.id}"))
      lines["607"].should eq([{"debit", M.d("100")}])
      lines["44566"].should eq([{"debit", M.d("20")}])
      bank = lines.keys.find! { |number| !number.in?("607", "44566") }
      lines[bank].should eq([{"credit", M.d("120")}])
      reversal = Mic.reverse_purchase(M.actor, Mic::ReverseInput.new(purchase.id, M.date("2026-09-13"))).value!
      back = I.by_account(I.entry("micro:purchase:#{reversal.id}"))
      back["44566"].should eq([{"credit", M.d("20")}])
      back[bank].should eq([{"debit", M.d("120")}])
    end
  end
end

describe "Micro-entreprise et Facturation — TVA ventilée par taux" do
  it "répartit la TVA de chaque taux sur les natures qui y sont soumises" do
    with_active_modules("micro,invoicing") do
      setup = micro_setup
      reduced = setup.rates["INT"] # 10 %
      invoice = InvoicingSpec.issued(setup, lines: [InvoicingSpec.line(setup, "10"),
                                                    InvoicingSpec.line(setup, "2", item_card_id: setup.goods.id, vat_rate_id: reduced.id)])
      # 800 HT à 20 % (160) de conseil, 49,80 HT à 10 % (4,98) de ramettes.
      invoice.totals.total_gross.should eq(M.d("1014.78"))
      I.record_payment(invoice.id, "1014.78", "2026-09-20")
      by_nature = Mic.receipts(M.system).to_h { |line| {line.nature_code, {line.amount, line.vat_amount}} }
      by_nature["SERVICE"].should eq({M.d("960"), M.d("160")})
      by_nature["SALE"].should eq({M.d("54.78"), M.d("4.98")})
    end
  end
end
