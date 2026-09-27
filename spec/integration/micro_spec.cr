# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias Acc = Partiduo::Api::Accounting
private alias Inv = Partiduo::Api::Invoicing
private alias Mic = Partiduo::Api::Micro
private alias I = IntegrationSpec
private alias M = MicroSpec

# ADR-007 D1, D2 et ADR-006 D3, D7 : le module micro seul, avec la
# Facturation, avec la Facturation et la Comptabilité — uniquement par les
# contrats et les événements. Chaque groupe fixe sa configuration.

private def entry_lines(source : String) : Hash(String, Array({String, BigDecimal}))
  I.by_account(I.entry(source))
end

private def micro_setup : InvoicingSpec::Setup
  setup = I.setup
  Mic.set_item_nature(M.system, setup.item.id, M.nature("SERVICE").id).value!
  setup
end

describe "Micro-entreprise et Facturation — une facture encaissée devient une recette" do
  it "ventile le règlement par nature d'article, TVA au prorata, sans ressaisie" do
    with_active_modules("micro,invoicing") do
      setup = micro_setup
      invoice = InvoicingSpec.issued(setup) # 800 HT de conseil, 49,80 HT de ramettes, 1 019,76 TTC
      payment = I.record_payment(invoice.id, "400", "2026-09-20", "cheque")
      receipts = Mic.receipts(M.system)
      receipts.size.should eq(2)
      receipts.sum(BigDecimal.new(0), &.amount).should eq(M.d("400"))
      receipts.sum(BigDecimal.new(0), &.vat_amount).should eq(M.d("66.67"))
      by_nature = receipts.to_h { |line| {line.nature_code, line} }
      by_nature["SERVICE"].amount.should eq(M.d("376.56"))
      by_nature["SALE"].amount.should eq(M.d("23.44"))
      receipts.each do |line|
        line.origin.should eq("invoicing")
        line.source.should eq("payment:#{payment.id}")
        line.method.should eq("cheque")
        line.date.should eq(M.date("2026-09-20"))
        line.card_id.should eq(setup.customer.id)
        line.party_name.should eq(setup.customer.name)
        line.reference.should eq(invoice.number)
      end
      I.record_payment(invoice.id, "619.76", "2026-09-25")
      Mic.receipts(M.system).sum(BigDecimal.new(0), &.amount).should eq(M.d("1019.76"))
      Mic.declarations(M.system, 2026)[2].turnover.should eq(M.d("849.8"))
    end
  end

  it "bascule vers la TVA : les articles en franchise prennent le taux normal, la mention 293 B disparaît" do
    with_active_modules("micro,invoicing") do
      setup = I.setup
      franchise = setup.rates["FRANC"]
      items = Partiduo::Api::Cards.category_by_code(M.system, "SALE") || raise "catégorie SALE absente"
      item = Partiduo::Api::Cards.create_card(M.system, Partiduo::Api::Cards::CardInput.new(category_id: items.id,
        name: "Cours", code: "COURS", unit_code: "HUR", sale_price: M.d("40"), vat_rate_id: franchise.id)).value!
      before = InvoicingSpec.issued(setup, lines: [InvoicingSpec.line(setup, "1", item_card_id: item.id)])
      InvoicingSpec.codes(before).should contain("special.franchise.fr")

      plan = Mic.vat_switch_plan(M.system)
      plan.items.map(&.code).should eq(["COURS"])
      plan.suggested_rate_id.should eq(setup.rates["NOR"].id)
      refused = Mic.switch_to_vat(M.actor, Mic::VatSwitchInput.new(M.date("2026-10-01"), franchise.id))
      refused.error_keys.should eq(["micro.errors.switch.vat.rate_invalid"])
      expect_raises(Partiduo::Api::Forbidden) do
        Mic.switch_to_vat(M.actor, Mic::VatSwitchInput.new(M.date("2026-10-01"), setup.rates["NOR"].id))
      end
      switcher = Partiduo::Api::Actor.user(9_i64, M::PERMISSIONS + ["cards.card.write"])
      settings = Mic.switch_to_vat(switcher, Mic::VatSwitchInput.new(M.date("2026-10-01"), setup.rates["NOR"].id)).value!
      settings.vat_liable_since.should eq(M.date("2026-10-01"))
      Partiduo::Api::Cards.card(M.system, item.id).vat_rate_id.should eq(setup.rates["NOR"].id)
      after = InvoicingSpec.issued(setup, lines: [InvoicingSpec.line(setup, "1", item_card_id: item.id)])
      InvoicingSpec.codes(after).should_not contain("special.franchise.fr")
      Mic.thresholds(M.system, 2026).thresholds.select(&.kind.==("vat")).map(&.status).uniq!.should eq(["not_applicable"])
      Mic.switch_to_vat(switcher, Mic::VatSwitchInput.new(M.date("2026-10-02"), setup.rates["NOR"].id))
        .error_keys.should eq(["micro.errors.switch.vat.already"])
    end
  end
end

describe "Micro-entreprise, Facturation et Comptabilité — la partie double sans la montrer" do
  it "passe l'écriture de trésorerie d'une recette, d'un achat et d'une contre-passation, selon la nature" do
    with_active_modules("micro,invoicing,accounting") do
      micro_setup
      receipt = M.receipt("2026-09-10", "100")
      lines = entry_lines("micro:receipt:#{receipt.id}")
      lines["510001"].should eq([{"debit", M.d("100")}])
      lines["706"].should eq([{"credit", M.d("100")}])
      I.entry("micro:receipt:#{receipt.id}").ledger_code.should eq("F01")

      purchase = M.purchase("2026-09-12", "40")
      lines = entry_lines("micro:purchase:#{purchase.id}")
      lines["607"].should eq([{"debit", M.d("40")}])
      lines["510001"].should eq([{"credit", M.d("40")}])

      reversal = Mic.reverse_receipt(M.actor, Mic::ReverseInput.new(receipt.id, M.date("2026-09-15"))).value!
      lines = entry_lines("micro:receipt:#{reversal.id}")
      lines["510001"].should eq([{"credit", M.d("100")}])
      lines["706"].should eq([{"debit", M.d("100")}])

      # Paramétrage par nature : la recette suivante prend le compte de la nature.
      Acc.set_micro_account(M.system, "SERVICE", "708").value!
      Acc.micro_accounts(M.system).map { |row| {row.key, row.account.number} }.should eq([{"SERVICE", "708"}])
      taxed = M.receipt("2026-09-16", "120", vat_amount: M.d("20"))
      lines = entry_lines("micro:receipt:#{taxed.id}")
      lines["708"].should eq([{"credit", M.d("100")}])
      lines["44571"].should eq([{"credit", M.d("20")}])
      Acc.set_micro_account(M.system, "bad key!", "708").error_keys.should eq(["accounting.errors.micro.key_invalid"])
      Acc.set_micro_account(M.system, "SERVICE", "60").error_keys.should eq(["accounting.errors.micro.not_direct_use"])

      # Republier ne double rien.
      count = I.entries("micro:receipt:#{receipt.id}").size
      Mic.republish(M.actor).should eq(4)
      I.entries("micro:receipt:#{receipt.id}").size.should eq(count)
    end
  end

  it "inscrit la recette au lettrage de l'encaissement, sans seconde écriture, et la contre-passe au délettrage" do
    with_active_modules("micro,invoicing,accounting") do
      setup = micro_setup
      invoice = InvoicingSpec.issued(setup)
      sale = I.entry("invoice:#{invoice.id}")
      customer_line = I.line(sale, I.card_account(setup.customer.id)).id
      bank = I.bank_receipt(setup.customer.code, "400", [customer_line], "2026-09-20")
      receipts = Mic.receipts(M.system)
      receipts.sum(BigDecimal.new(0), &.amount).should eq(M.d("400"))
      receipts.map(&.source).uniq!.size.should eq(1)
      receipts.first.source.should start_with("matching:")
      receipts.first.date.should eq(M.date("2026-09-20"))
      receipts.each { |line| I.entries("micro:receipt:#{line.id}").should be_empty }

      matching_id = Acc.entry(M.system, bank.id).lines.compact_map(&.matching_id).first
      Acc.unmatch(M.system, matching_id).value!
      all = Mic.receipts(M.system)
      all.size.should eq(4)
      all.sum(BigDecimal.new(0), &.amount).should eq(BigDecimal.new(0))
      all.select(&.reversal?).map(&.date).uniq!.should eq([Partiduo::Config.today])
    end
  end
end

describe "Micro-entreprise et Comptabilité, sans Facturation" do
  it "comptabilise les registres et ne s'abonne à aucune facture" do
    with_active_modules("micro,accounting") do
      M.setup
      cash = M.receipt("2026-09-10", "35", "SALE", method: "cash")
      lines = entry_lines("micro:receipt:#{cash.id}")
      lines["707"].should eq([{"credit", M.d("35")}])
      supplies = M.purchase("2026-09-11", "12.30", "SUPPLIES")
      entry_lines("micro:purchase:#{supplies.id}")["606"].should eq([{"debit", M.d("12.3")}])
    end
  end
end

describe "Micro-entreprise seule, puis bascule vers le régime réel" do
  it "tient les registres sans Comptabilité, puis l'active et en passe les écritures sans ressaisie" do
    with_active_modules("micro") do
      M.setup
      receipt = M.receipt("2026-09-10", "250")
      Partiduo::Modules.active?("ACCOUNTING").should be_false
      expect_raises(Partiduo::Api::Forbidden) { Mic.switch_to_real(M.actor, M.date("2027-01-01")) }
      admin = Partiduo::Api::Actor.user(9_i64, M::PERMISSIONS + ["core.modules.manage"])
      settings = Mic.switch_to_real(admin, M.date("2027-01-01")).value!
      settings.real_regime_since.should eq(M.date("2027-01-01"))
      Partiduo::Modules.active?("ACCOUNTING").should be_true
      # Plan comptable chargé après l'activation : la republication passe l'écriture.
      Acc.load_initial_data(M.system, "fr", "fr").value!
      Mic.republish(M.actor).should eq(1)
      entry_lines("micro:receipt:#{receipt.id}")["706"].should eq([{"credit", M.d("250")}])
      Mic.switch_to_real(admin, M.date("2027-01-02")).error_keys.should eq(["micro.errors.switch.real.already"])
    end
  end
end
