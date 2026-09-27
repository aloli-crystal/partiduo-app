# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias Api = Partiduo::Api::Accounting

private def system
  Partiduo::Api::Actor.system
end

describe_module "ACCOUNTING", "Données initiales comptables (PCG, PCMN)" do
  it "charge le plan comptable français (mod2), ses comptes par défaut et ses journaux" do
    view = AccountingSpec.load("fr")
    view.accounts.should eq(167)
    view.ledgers.should eq(4)

    lines = Api.chart(system)
    lines.size.should eq(167)
    lines.select(&.depth.zero?).map(&.account.number).should eq(%w[1 2 3 4 5 6 7 8 9])
    Api.account(system, "7").kind.should eq(Api::AccountKind::Income) # PAS dans mod2, corrigé
    Api.account(system, "707").parent_number.should eq("7")
    Api.account(system, "4456602").parent_number.should eq("4456")
    Api.account(system, "51").direct_use.should be_false
    expect_raises(Partiduo::Api::NotFound) { Api.account(system, "4000001") } # fiche de démonstration

    Api.default_account(system, "customer").try(&.number).should eq("410")
    Api.default_account(system, "bank").try(&.number).should eq("51")

    ledgers = Api.ledgers(system)
    ledgers.map { |ledger| {ledger.code, ledger.kind} }.should eq([
      {"A01", Api::LedgerKind::Purchase}, {"F01", Api::LedgerKind::Financial},
      {"O01", Api::LedgerKind::Misc}, {"V01", Api::LedgerKind::Sale},
    ])
    financial = ledgers.find!(&.kind.financial?)
    financial.name.should eq("Financier")
    financial.default_account.try(&.number).should eq("510001")
    financial.currency_code.should eq("EUR")
    financial.next_receipt.should eq("F-00001")
  end

  it "charge le PCMN belge (mod1) sans les comptes des fiches de démonstration, journaux dans la langue du dossier" do
    AccountingSpec.load("be", "nl").accounts.should eq(504)

    Api.account(system, "5510").parent_number.should eq("55") # parent 551 absent de mod1
    Api.account(system, "411502").parent_number.should eq("4115")
    Api.account(system, "6").kind.should eq(Api::AccountKind::Expense)
    expect_raises(Partiduo::Api::NotFound) { Api.account(system, "4000001") }
    expect_raises(Partiduo::Api::NotFound) { Api.account(system, "55000002") }

    Api.ledgers(system).map(&.name).should eq(["Aankopen", "Financieel", "Diverse verrichtingen", "Verkopen"])
    Api.ledger_by_code(system, "f01").default_account.try(&.number).should eq("550")
  end

  it "corrige les types de compte erronés des modèles de NOALYSS (D-ACC-008)" do
    AccountingSpec.load("fr")
    kind = ->(number : String) { Api.account(system, number).kind }
    {
      "400" => Api::AccountKind::Liability, "419" => Api::AccountKind::Liability,
      "409" => Api::AccountKind::Asset, "410" => Api::AccountKind::Asset,
      "44571" => Api::AccountKind::Liability, "445661" => Api::AccountKind::Asset,
      "486" => Api::AccountKind::Asset, "487" => Api::AccountKind::Liability,
      "491" => Api::AccountKind::AssetContra, "496" => Api::AccountKind::AssetContra,
      "281" => Api::AccountKind::AssetContra, "290" => Api::AccountKind::AssetContra,
      "391" => Api::AccountKind::AssetContra, "590" => Api::AccountKind::AssetContra,
    }.each { |number, expected| {number, kind.call(number)}.should eq({number, expected}) }
    Api.account(system, "44571").parent_number.should eq("4457")
    Api.default_account(system, "vat").try(&.number).should eq("44551")

    # Un fournisseur hérite du type de son compte de base : au passif.
    supplier = (Partiduo::Api::Cards.category_by_code(system, "SUPPLIER") || raise "absent")
    card = ReferentialSpec.card(supplier.id, "Fournisseur")
    (Api.card_account(system, card.id) || raise "absent").account.kind.should eq(Api::AccountKind::Liability)
  end

  it "corrige les réductions de valeur actées du PCMN en déduction d'actif" do
    AccountingSpec.load("be")
    %w[2819 2839 5509 5519 5599 309].each do |number|
      {number, Api.account(system, number).kind}.should eq({number, Api::AccountKind::AssetContra})
    end
  end

  it "rattache le journal financier à une fiche Banque du socle (D-ACC-010)" do
    AccountingSpec.load("fr")
    financial = Api.ledger_by_code(system, "F01")
    card = Partiduo::Api::Cards.card(system, (financial.bank_card_id || raise "absent"))
    card.kind.should eq("bank")
    card.name.should eq("Banque")
    (Api.card_account(system, card.id) || raise "absent").account.number.should eq("510001")
    expect_raises(Partiduo::Api::NotFound) { Api.account(system, "510002") } # compte calculé retiré
  end

  it "charge les comptes de TVA de chaque taux (tva_rate.tva_poste, D-ACC-009)" do
    Partiduo::Api::Vat.load_rates(system, "fr")
    AccountingSpec.load("fr")
    accounts = Api.vat_rate_accounts(system).to_h { |row| {row.vat_rate_code, {row.deductible_account.try(&.number), row.collected_account.try(&.number)}} }
    accounts["NOR"].should eq({"445661", "44571"})
    accounts["TR55"].should eq({"445662", "44572"})
    accounts["DOM1"].should eq({"4456606", "445706"})
    accounts["INTS"].should eq({"44566015", "4457015"})
    accounts.size.should eq(Partiduo::Api::Vat.rates(system).size)
  end

  it "charge les comptes de TVA belges" do
    Partiduo::Api::Vat.load_rates(system, "be")
    AccountingSpec.load("be")
    rate = (Partiduo::Api::Vat.rate_by_code(system, "21G") || raise "absent")
    view = (Api.vat_rate_account(system, rate.id) || raise "absent")
    {view.deductible_account.try(&.number), view.collected_account.try(&.number)}.should eq({"4111", "4511"})
  end

  it "exige les deux comptes de TVA d'un taux autoliquidé" do
    Partiduo::Api::Vat.load_rates(system, "fr")
    AccountingSpec.load("fr")
    rate = (Partiduo::Api::Vat.rate_by_code(system, "INTS") || raise "absent")
    input = Api::VatRateAccountsInput.new(rate.id, "445661", nil)
    Api.set_vat_rate_accounts(system, input).error_keys.should eq(["accounting.errors.vat_rate_account.account.required"])
    Api.set_vat_rate_accounts(system, input.copy_with(collected_account: "4457")).error_keys
      .should eq(["accounting.errors.vat_rate_account.account.not_direct_use"])
    Api.set_vat_rate_accounts(system, input.copy_with(collected_account: "44571")).success?.should be_true
  end

  it "refuse un second chargement et un régime inconnu" do
    AccountingSpec.load("fr")
    Api.load_initial_data(system, "fr").error_keys.should eq(["accounting.errors.initial_data.not_empty"])
    Api.load_initial_data(system, "de").error_keys.should eq(["accounting.errors.initial_data.regime.invalid"])
  end

  it "exige les droits d'écriture du plan et des journaux" do
    expect_raises(Partiduo::Api::Forbidden) do
      Api.load_initial_data(actor_with("accounting.account.write"), "fr")
    end
  end

  it "est branché sur partiduo-provision : le plan du régime est chargé avec l'instance" do
    provision_instance(settings_input(tax_regime: "be", siren: nil, vat_number: nil))
    Api.account(system, "550").label.should eq("Banque 1")
    Api.ledgers(system).size.should eq(4)
  end
end

describe "Données initiales comptables : module inactif" do
  it "ne charge rien au provisionnement si la Comptabilité est inactive" do
    with_active_modules("invoicing") do
      provision_instance
    end
    Partiduo::Accounting::Account.all.count.should eq(0)
  end
end
