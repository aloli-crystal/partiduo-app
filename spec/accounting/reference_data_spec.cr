# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias Api = Partiduo::Api::Accounting

private def system
  Partiduo::Api::Actor.system
end

describe_module "ACCOUNTING", "Données initiales comptables (PCG, PCMN)" do
  it "charge le plan comptable français (mod2), ses comptes par défaut et ses journaux" do
    view = AccountingSpec.load("fr")
    view.accounts.should eq(163)
    view.ledgers.should eq(4)

    lines = Api.chart(system)
    lines.size.should eq(163)
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
