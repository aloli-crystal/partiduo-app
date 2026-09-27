# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias Acc = Partiduo::Api::Accounting
private alias Mic = Partiduo::Api::Micro
private alias I = IntegrationSpec
private alias M = MicroSpec

# Lot G (tests) : cas limites de l'alimentation du module micro par les
# événements de la Facturation (ADR-007 D1, D-MIC-005) et de la partie
# double automatique (ADR-007 D2, D-MIC-004). Chaque groupe fixe sa
# configuration de modules ; aucun module n'en appelle un autre.

describe "Micro-entreprise et Facturation — cas limites de l'alimentation" do
  it "ventile sur la nature par défaut quand la nature de l'article est désactivée" do
    with_active_modules("micro,invoicing") do
      setup = I.setup
      Mic.set_item_nature(M.system, setup.item.id, M.nature("SERVICE").id).value!
      service = M.nature("SERVICE")
      Mic.update_nature(M.system, service.id, Mic::NatureInput.new("SERVICE", service.label, "receipt", "service_bic",
        enabled: false)).value!
      invoice = InvoicingSpec.issued(setup)
      I.record_payment(invoice.id, "400", "2026-09-20")
      receipts = Mic.receipts(M.system)
      receipts.map(&.nature_code).should eq(["SALE"])
      receipts.first.amount.should eq(M.d("400"))
      receipts.first.vat_amount.should eq(M.d("66.67"))
    end
  end

  it "n'empêche jamais le règlement quand la recette ne peut pas être inscrite" do
    with_active_modules("micro,invoicing") do
      setup = I.setup
      Mic.natures(M.system, "receipt").each do |nature|
        Mic.update_nature(M.system, nature.id, Mic::NatureInput.new(nature.code, nature.label, nature.kind, nature.category,
          enabled: false)).value!
      end
      invoice = InvoicingSpec.issued(setup)
      payment = I.record_payment(invoice.id, "100", "2026-09-20")
      payment.id.should be > 0
      Mic.receipts(M.system).should be_empty
    end
  end

  it "inscrit chaque règlement séparément, et le reste d'arrondi sur la plus grande part" do
    with_active_modules("micro,invoicing") do
      setup = I.setup
      Mic.set_item_nature(M.system, setup.item.id, M.nature("SERVICE").id).value!
      invoice = InvoicingSpec.issued(setup)
      I.record_payment(invoice.id, "0.01", "2026-09-20")
      first = Mic.receipts(M.system)
      # Un centime : tout va à la plus grande part (le conseil), TVA nulle.
      first.map { |line| {line.nature_code, line.amount, line.vat_amount} }.should eq([{"SERVICE", M.d("0.01"), M.d("0")}])
      I.record_payment(invoice.id, "1019.75", "2026-09-21")
      all = Mic.receipts(M.system)
      all.sum(BigDecimal.new(0), &.amount).should eq(M.d("1019.76"))
      all.map(&.source).uniq!.size.should eq(2)
      all.each { |line| (line.vat_amount < line.amount).should be_true }
    end
  end

  it "retrouve dans le journal du socle une facture émise avant l'activation du module" do
    invoice = with_active_modules("invoicing") do
      InvoicingSpec.issued(I.setup)
    end
    with_active_modules("micro,invoicing") do
      Mic.load_defaults(M.system).should be > 0
      I.record_payment(invoice.id, "1019.76", "2026-09-20")
      receipts = Mic.receipts(M.system)
      receipts.sum(BigDecimal.new(0), &.amount).should eq(M.d("1019.76"))
      receipts.sum(BigDecimal.new(0), &.vat_amount).should eq(M.d("169.96"))
      receipts.map(&.reference).uniq!.should eq([invoice.number])
    end
  end
end

describe "Micro-entreprise et Comptabilité — cas limites de la partie double" do
  it "préfère le compte de la nature à celui de la catégorie, puis au compte du régime" do
    with_active_modules("micro,accounting") do
      M.setup
      Acc.set_micro_account(M.system, "bnc", "708").value!
      fee = M.receipt("2026-09-10", "50", "FEE")
      I.by_account(I.entry("micro:receipt:#{fee.id}"))["708"].should eq([{"credit", M.d("50")}])
      Acc.set_micro_account(M.system, "FEE", "706").value!
      again = M.receipt("2026-09-11", "60", "FEE")
      I.by_account(I.entry("micro:receipt:#{again.id}"))["706"].should eq([{"credit", M.d("60")}])
      # Retirer le paramétrage : retour au compte du régime (706 pour les BNC).
      Acc.set_micro_account(M.system, "FEE", nil).value!
      Acc.set_micro_account(M.system, "bnc", nil).value!
      Acc.micro_accounts(M.system).should be_empty
    end
  end

  it "contre-passe l'écriture d'un achat et comptabilise les espèces" do
    with_active_modules("micro,accounting") do
      M.setup
      purchase = M.purchase("2026-09-12", "40", "SUPPLIES")
      reversal = Mic.reverse_purchase(M.actor, Mic::ReverseInput.new(purchase.id, M.date("2026-09-13"))).value!
      original = I.by_account(I.entry("micro:purchase:#{purchase.id}"))
      reverse = I.by_account(I.entry("micro:purchase:#{reversal.id}"))
      original["606"].should eq([{"debit", M.d("40")}])
      reverse["606"].should eq([{"credit", M.d("40")}])
      bank = original.keys.find! { |number| number != "606" }
      reverse[bank].should eq([{"debit", M.d("40")}])

      cash = M.receipt("2026-09-14", "12", "SALE", method: "cash")
      cash_entry = I.entry("micro:receipt:#{cash.id}")
      cash_entry.lines.size.should eq(2)
      I.by_account(cash_entry)["707"].should eq([{"credit", M.d("12")}])
    end
  end

  it "inscrit la ligne au registre même quand l'écriture ne peut pas être passée" do
    with_active_modules("micro,accounting") do
      M.setup
      line = M.receipt("2026-09-10", "10")
      I.entries("micro:receipt:#{line.id}").size.should eq(1)
      # Recette hors de tout exercice : le registre l'accepte, la
      # Comptabilité la consigne sans bloquer.
      outside = M.receipt("2024-03-01", "15")
      outside.number.should eq("R2024-00001")
      I.entries("micro:receipt:#{outside.id}").should be_empty
      Mic.receipts(M.system).size.should eq(2)
    end
  end
end
