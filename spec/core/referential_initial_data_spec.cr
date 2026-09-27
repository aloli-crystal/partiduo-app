# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias R = ReferentialSpec

describe "Provisionnement : référentiel du socle (lot 1)" do
  it "charge la devise de tenue, les taux et les catégories du régime français" do
    view = provision_instance
    view.loaders.should contain("CORE.base_currency")
    view.loaders.should contain("VAT.rates")
    view.loaders.should contain("CARDS.categories")
    view.loaders.index!("VAT.rates").should be < view.loaders.index!("CARDS.categories")

    actor = Partiduo::Api::Actor.system
    Partiduo::Api::Core.base_currency(actor).code.should eq("EUR")
    R.present(Partiduo::Api::Vat.rate_by_code(actor, "NOR")).label.should eq("TVA 20 % (taux normal)")
    Partiduo::Api::Vat.rate_by_code(actor, "21G").should be_nil
    R.present(Partiduo::Api::Cards.category_by_code(actor, "CUSTOMER")).name.should eq("Clients")
  end

  it "charge les taux belges et libellés néerlandais pour un dossier belge en néerlandais" do
    provision_instance(settings_input(tax_regime: "be", siren: nil, rcs: nil, vat_number: nil, default_locale: "nl"))
    actor = Partiduo::Api::Actor.system
    R.present(Partiduo::Api::Vat.rate_by_code(actor, "21G")).label.should eq("Btw 21 %")
    Partiduo::Api::Vat.rate_by_code(actor, "NOR").should be_nil
    R.present(Partiduo::Api::Cards.category_by_code(actor, "SUPPLIER")).name.should eq("Leveranciers")
  end
end
