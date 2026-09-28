# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias Acc = Partiduo::Api::Accounting
private alias Lib = Partiduo::Api::Liberal
private alias I = IntegrationSpec
private alias L = LiberalSpec

# ADR-007 D6 et ADR-006 D3, D7 : le module liberal seul, avec la
# Comptabilité, avec la Facturation, avec les deux — uniquement par les
# contrats et les événements. Chaque groupe fixe sa configuration.

private def entry_lines(source : String) : Hash(String, Array({String, BigDecimal}))
  I.by_account(I.entry(source))
end

describe "Profession libérale seule" do
  it "tient le livre-journal et prépare la 2035 sans Comptabilité ni Facturation" do
    with_active_modules("liberal") do
      L.setup
      L.receipt("2026-09-10", "250")
      L.expense("2026-09-11", "50", "OFFICE")
      Partiduo::Modules.active?("ACCOUNTING").should be_false
      view = Lib.tax_return(L.system, 2026)
      view.amount("excess").should eq(L.d("200"))
      view.ready?.should be_true
    end
  end
end

describe "Profession libérale et Comptabilité — la partie double par événements" do
  it "passe l'écriture de trésorerie des recettes, dépenses, immobilisations et cessions" do
    with_active_modules("liberal,accounting") do
      L.setup
      receipt = L.receipt("2026-09-10", "100")
      lines = entry_lines("liberal:receipt:#{receipt.id}")
      lines["510001"].should eq([{"debit", L.d("100")}])
      lines["706"].should eq([{"credit", L.d("100")}])
      I.entry("liberal:receipt:#{receipt.id}").ledger_code.should eq("F01")

      rent = L.expense("2026-09-11", "800", "RENT")
      lines = entry_lines("liberal:expense:#{rent.id}")
      lines["613"].should eq([{"debit", L.d("800")}])
      lines["510001"].should eq([{"credit", L.d("800")}])

      withdrawal = L.expense("2026-09-12", "1500", "WITHDRAWAL")
      entry_lines("liberal:expense:#{withdrawal.id}")["108"].should eq([{"debit", L.d("1500")}])

      reversal = Lib.reverse_line(L.actor, Lib::ReverseInput.new(rent.id, L.date("2026-09-15"))).value!
      lines = entry_lines("liberal:expense:#{reversal.id}")
      lines["613"].should eq([{"credit", L.d("800")}])
      lines["510001"].should eq([{"debit", L.d("800")}])

      asset = L.asset("2026-09-01", "3000", 3)
      lines = entry_lines("liberal:asset:#{asset.id}")
      lines["2183"].should eq([{"debit", L.d("3000")}])
      lines["510001"].should eq([{"credit", L.d("3000")}])
      Lib.dispose_asset(L.actor, Lib::DisposalInput.new(asset.id, L.date("2026-09-20"), L.d("2500"), "cheque")).value!
      disposal = Lib.asset(L.system, asset.id).disposal || raise "cession absente"
      entry_lines("liberal:disposal:#{disposal.id}")["775"].should eq([{"credit", L.d("2500")}])

      # Paramétrage par nature : la dépense suivante prend le compte de la nature.
      Acc.create_account(L.system, Acc::AccountInput.new(number: "6132", label: "Locations immobilières")).value!
      Acc.set_liberal_account(L.system, "RENT", "6132").value!
      Acc.liberal_accounts(L.system).map { |row| {row.key, row.account.number} }.should eq([{"RENT", "6132"}])
      second = L.expense("2026-09-16", "700", "RENT")
      entry_lines("liberal:expense:#{second.id}")["6132"].should eq([{"debit", L.d("700")}])
      Acc.set_liberal_account(L.system, "bad key!", "6132").error_keys.should eq(["accounting.errors.liberal.key_invalid"])

      # Republier ne double rien.
      count = I.entries("liberal:receipt:#{receipt.id}").size
      Lib.republish(L.actor).should eq(7)
      I.entries("liberal:receipt:#{receipt.id}").size.should eq(count)
    end
  end
end

describe "Profession libérale et Comptabilité — tenue toutes taxes comprises (D-LIB-009)" do
  it "passe la TVA reversée en charge : aucun mouvement en classe 4" do
    with_active_modules("liberal,accounting") do
      L.setup
      receipt = L.receipt("2026-09-10", "1200")
      vat = L.expense("2026-09-15", "200", "VAT_PAID")
      entry_lines("liberal:receipt:#{receipt.id}")["706"].should eq([{"credit", L.d("1200")}])
      entry_lines("liberal:expense:#{vat.id}")["6358"].should eq([{"debit", L.d("200")}])
      balance = Acc.trial_balance(L.system, Acc::TrialBalanceQuery.new(date_from: L.date("2026-01-01"),
        date_to: L.date("2026-12-31")))
      balance.rows.select(&.number.starts_with?("4")).each do |row|
        {row.number, row.debit, row.credit}.should eq({row.number, BigDecimal.new(0), BigDecimal.new(0)})
      end
      balance.delta.should eq(BigDecimal.new(0))
    end
  end

  it "crée le compte de produit de cession à son propre libellé, pas à celui de la catégorie" do
    with_active_modules("liberal,accounting") do
      L.setup
      Partiduo::Accounting::Account.filter(number: "775").delete
      asset = L.asset("2026-09-01", "3000", 3, "vehicle")
      Lib.dispose_asset(L.actor, Lib::DisposalInput.new(asset.id, L.date("2026-09-20"), L.d("2500"), "cheque")).value!
      account = Acc.account(L.system, "775")
      account.label.should eq(I18n.t("accounting.liberal.disposal_account_label"))
    end
  end
end

describe "Profession libérale et Facturation — une facture encaissée devient une recette" do
  it "inscrit l'encaissement toutes taxes comprises, sans ressaisie" do
    with_active_modules("liberal,invoicing") do
      setup = I.setup
      invoice = InvoicingSpec.issued(setup)
      payment = I.record_payment(invoice.id, "400", "2026-09-20", "cheque")
      lines = Lib.lines(L.system)
      lines.size.should eq(1)
      line = lines.first
      {line.kind, line.heading, line.amount, line.origin, line.method}.should eq({"receipt", "receipts", L.d("400"), "invoicing", "cheque"})
      line.source.should eq("payment:#{payment.id}")
      line.card_id.should eq(setup.customer.id)
      line.reference.should eq(invoice.number)
      I.record_payment(invoice.id, "619.76", "2026-09-25")
      Lib.journal_totals(L.system).receipts.should eq(L.d("1019.76"))
    end
  end
end

describe "Profession libérale, Facturation et Comptabilité" do
  it "inscrit la recette au lettrage, sans seconde écriture, et la contre-passe au délettrage" do
    with_active_modules("liberal,invoicing,accounting") do
      setup = I.setup
      invoice = InvoicingSpec.issued(setup)
      sale = I.entry("invoice:#{invoice.id}")
      customer_line = I.line(sale, I.card_account(setup.customer.id)).id
      bank = I.bank_receipt(setup.customer.code, "400", [customer_line], "2026-09-20")
      lines = Lib.lines(L.system)
      lines.sum(BigDecimal.new(0), &.amount).should eq(L.d("400"))
      lines.first.source.should start_with("matching:")
      lines.each { |line| I.entries("liberal:receipt:#{line.id}").should be_empty }

      matching_id = Acc.entry(L.system, bank.id).lines.compact_map(&.matching_id).first
      Acc.unmatch(L.system, matching_id).value!
      all = Lib.lines(L.system)
      all.size.should eq(2)
      all.sum(BigDecimal.new(0), &.amount).should eq(BigDecimal.new(0))
      all.select(&.reversal?).map(&.date).should eq([Partiduo::Config.today])
    end
  end
end

describe "Profession libérale et Comptabilité — cas limites de la partie double" do
  it "passe la dépense entière (part privée au comptable), les espèces en caisse, rien pour une cession gratuite" do
    with_active_modules("liberal,accounting") do
      L.setup
      car = L.expense("2026-09-10", "100", "VEHICLE", nondeductible_amount: L.d("30"))
      lines = entry_lines("liberal:expense:#{car.id}")
      lines["510001"].should eq([{"credit", L.d("100")}])
      lines.reject { |account, _| account == "510001" }.values.flatten.should eq([{"debit", L.d("100")}])

      # Sans journal de caisse au plan, les espèces vont au premier journal financier.
      cash = L.receipt("2026-09-11", "20", method: "cash")
      entry = I.entry("liberal:receipt:#{cash.id}")
      entry.ledger_code.should eq("F01")
      I.by_account(entry)["510001"].should eq([{"debit", L.d("20")}])

      asset = L.asset("2026-09-01", "600", 3)
      reversal = Lib.reverse_asset(L.actor, Lib::ReverseInput.new(asset.id, L.date("2026-09-02"))).value!
      entry_lines("liberal:asset:#{reversal.id}")["2183"].should eq([{"credit", L.d("600")}])

      scrapped = L.asset("2026-09-03", "400", 3)
      Lib.dispose_asset(L.actor, Lib::DisposalInput.new(scrapped.id, L.date("2026-09-20"), L.d("0"), "cash")).value!
      disposal = Lib.asset(L.system, scrapped.id).disposal || raise "cession absente"
      I.entries("liberal:disposal:#{disposal.id}").should be_empty
    end
  end

  it "contrôle le paramétrage des comptes : compte inconnu, retrait, droits, module inactif" do
    with_active_modules("liberal,accounting") do
      L.setup
      Acc.set_liberal_account(L.system, "RENT", "999999").error_keys
        .should eq(["accounting.errors.default_account.account.not_found"])
      Acc.create_account(L.system, Acc::AccountInput.new(number: "6132", label: "Locations immobilières")).value!
      Acc.set_liberal_account(L.system, "rent", "6132").value!
      Acc.set_liberal_account(L.system, "rent", nil).value!
      Acc.liberal_accounts(L.system).should be_empty
      clerk = actor_with("accounting.account.read")
      expect_raises(Partiduo::Api::Forbidden) { Acc.set_liberal_account(clerk, "rent", "6132") }
      expect_raises(Partiduo::Api::Forbidden) { Acc.liberal_accounts(actor_with("liberal.register.read")) }
    end
    with_active_modules("liberal") do
      expect_raises(Partiduo::Api::ModuleDisabled) { Acc.liberal_accounts(L.system) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Acc.set_liberal_account(L.system, "rent", "6132") }
    end
  end

  it "comptabilise après coup, par republication, un livre-journal tenu sans Comptabilité" do
    with_active_modules("liberal") do
      L.setup
      L.receipt("2026-09-10", "100")
      L.expense("2026-09-11", "40", "OFFICE")
    end
    with_active_modules("liberal,accounting") do
      Lib.lines(L.system).each { |line| I.entries("liberal:#{line.kind}:#{line.id}").should be_empty }
      # Plan comptable chargé après l'activation, puis republication.
      Acc.load_initial_data(L.system, "fr", "fr").value!
      Lib.republish(L.actor).should eq(2)
      Lib.lines(L.system).each { |line| I.entries("liberal:#{line.kind}:#{line.id}").size.should eq(1) }
    end
  end
end
