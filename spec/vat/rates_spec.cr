# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias Api = Partiduo::Api::Vat
private alias R = ReferentialSpec

private def writer : Partiduo::Api::Actor
  actor_with("vat.rate.read", "vat.rate.write")
end

private def input(code : String = "NOR", rate : String = "20", **options) : Api::RateInput
  Api::RateInput.new(code: code, label: "Test #{code}", rate: BigDecimal.new(rate)).copy_with(**options)
end

describe "Partiduo::Api::Vat — taux de TVA (tva_rate)" do
  it "crée un taux et en déduit la catégorie" do
    view = Api.create_rate(writer, input("nor", "20")).value!
    view.code.should eq("NOR")
    view.category.should eq("S")
    view.fraction.should eq(BigDecimal.new("0.2"))
    view.tax_on(BigDecimal.new("99.99")).should eq(BigDecimal.new("20.00"))
    view.category_key.should eq("vat.categories.s")
    Api.create_rate(writer, input("ZERO", "0")).value!.category.should eq("Z")
  end

  {
    {"abc", true}, {"13A", true}, {"1", false}, {"1-A", false}, {"+a", false}, {"abcdefg", false},
  }.each do |(code, valid)|
    it "contrôle le code TVA « #{code} » (Acc_TVATest::testCheck)" do
      Api.check_rate(writer, input(code)).success?.should eq(valid)
    end
  end

  it "donne la raison du refus d'un code" do
    Api.check_rate(writer, input("1")).error_keys.should eq(["vat.errors.rate.code.digits_only"])
    Api.check_rate(writer, input("1-A")).error_keys.should eq(["vat.errors.rate.code.invalid_characters"])
    Api.check_rate(writer, input("ABCDEFG")).error_keys.should eq(["vat.errors.rate.code.too_long"])
  end

  it "refuse un libellé vide ou déjà pris, sans tenir compte de la casse" do
    Api.create_rate(writer, input("NOR", label: "Taux normal"))
    result = Api.create_rate(writer, input("NOR2", label: "TAUX NORMAL"))
    result.error_keys.should eq(["vat.errors.rate.label.taken"])
    Api.check_rate(writer, input("X1", label: " ")).error_keys.should eq(["vat.errors.rate.label.blank"])
    R.expect_translated(result)
  end

  it "borne le taux entre 0 et 100 % à quatre décimales" do
    Api.check_rate(writer, input("A", "101")).error_keys.should eq(["vat.errors.rate.rate.out_of_range"])
    Api.check_rate(writer, input("A", "-1")).error_keys.should eq(["vat.errors.rate.rate.out_of_range"])
    Api.check_rate(writer, input("A", "5.55555")).error_keys.should eq(["vat.errors.rate.rate.too_precise"])
  end

  it "applique les règles de catégorie de l'EN 16931" do
    Api.check_rate(writer, input("A", "0", category: "S")).error_keys.should eq(["vat.errors.rate.rate.must_be_positive"])
    Api.check_rate(writer, input("A", "20", category: "Z")).error_keys.should eq(["vat.errors.rate.rate.must_be_zero"])
    Api.check_rate(writer, input("A", "0", category: "E")).error_keys.should eq(["vat.errors.rate.exemption_code.required"])
    Api.check_rate(writer, input("A", "0", category: "E", exemption_reason: "Article 261 du CGI")).success?.should be_true
    Api.check_rate(writer, input("A", "20", exemption_code: "VATEX-EU-G")).error_keys
      .should eq(["vat.errors.rate.exemption_code.not_applicable"])
    Api.check_rate(writer, input("A", "0", category: "G", exemption_code: "G")).error_keys
      .should eq(["vat.errors.rate.exemption_code.invalid"])
    Api.check_rate(writer, input("A", "0", category: "X")).error_keys.should eq(["vat.errors.rate.category.invalid"])
    # Autoliquidation d'une acquisition : taux de l'acquéreur, catégorie AE.
    Api.check_rate(writer, input("A", "21", category: "AE", exemption_code: "VATEX-EU-AE", reverse_charge: true))
      .success?.should be_true
  end

  it "modifie un taux libre, pas le taux d'un taux déjà cité" do
    rate = Api.create_rate(writer, input("NOR", "20")).value!
    Api.update_rate(writer, rate.id, input("NOR", "19.6", label: "Ancien")).value!.rate.should eq(BigDecimal.new("19.6"))

    category = R.category("SALE", "item")
    R.card(category.id, "Conseil", vat_rate_id: rate.id)
    result = Api.update_rate(writer, rate.id, input("NOR", "20", label: "Ancien"))
    result.error_keys.should eq(["vat.errors.rate.rate.in_use"])
    R.expect_translated(result)
    # Le libellé et l'activation restent modifiables.
    Api.update_rate(writer, rate.id, input("NOR", "19.6", label: "TVA 19,6 %", enabled: false)).value!.enabled.should be_false
    Api.rates(writer).should be_empty
    Api.rates(writer, include_disabled: true).size.should eq(1)
    Api.delete_rate(writer, rate.id).error_keys.should eq(["vat.errors.rate.base.in_use"])
  end

  it "supprime un taux libre" do
    rate = Api.create_rate(writer, input).value!
    Api.delete_rate(writer, rate.id).success?.should be_true
    Api.rate_by_code(writer, "nor").should be_nil
  end

  it "charge les taux belges et français en vigueur" do
    be = Api.load_rates(R.system, "be", "nl")
    be.should contain("21G")
    R.present(Api.rate_by_code(writer, "21G")).label.should eq("Btw 21 %")
    R.present(Api.rate_by_code(writer, "INTL")).category.should eq("K")
    Api.load_rates(R.system, "be").should be_empty

    Partiduo::Vat::Rate.all.delete(raw: true)
    Api.load_rates(R.system, "fr")
    rates = Api.rates(writer).to_h { |rate| {rate.code, rate.rate} }
    rates["NOR"].should eq(BigDecimal.new("20"))
    rates["INT"].should eq(BigDecimal.new("10"))
    rates["TR55"].should eq(BigDecimal.new("5.5"))
    rates["TP021"].should eq(BigDecimal.new("2.1"))
    R.present(Api.rate_by_code(writer, "FRANC")).exemption_code.should eq("VATEX-FR-FRANCHISE")
    expect_raises(Partiduo::Api::Forbidden) { Api.load_rates(writer, "fr") }
  end

  it "exige les permissions vat.rate.read et vat.rate.write" do
    expect_raises(Partiduo::Api::Forbidden) { Api.rates(actor_with) }
    expect_raises(Partiduo::Api::Forbidden) { Api.create_rate(actor_with("vat.rate.read"), input) }
  end

  it "contraint le code et le taux en base (tva_code_number_check)" do
    expect_raises(Exception, /vat_rate_code_check/) do
      Marten::DB::Connection.default.open do |db|
        db.exec("INSERT INTO vat_rate (code, label, rate, description, category, exemption_code, exemption_reason, " \
                "reverse_charge, sale_on_payment, purchase_on_payment, enabled, created_at, updated_at) " \
                "VALUES ('123', 'x', 1, '', 'S', '', '', false, false, false, true, now(), now())")
      end
    end
  end
end
