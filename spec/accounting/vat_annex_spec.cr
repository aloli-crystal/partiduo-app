# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Annexe 3310-A : ligne 14 de la CA3 et de la CA12 détaillée taux par taux
# (DECISIONS D-TVA-006 révisée, D-R5-006).

private alias Api = Partiduo::Api::Accounting

private def system
  Partiduo::Api::Actor.system
end

private def d(text : String) : BigDecimal
  BigDecimal.new(text)
end

private def particular_rates_sales : Nil
  VatReturnSpec.setup("fr")
  customer = VatReturnSpec.card("CUSTOMER", "Client Corse")
  VatReturnSpec.sale(customer, [EntrySpec.item("1000", "COR13", account: "706"), EntrySpec.item("500", "TP021", account: "706")])
  VatReturnSpec.sale(customer, [EntrySpec.item("100", "NOR", account: "706")])
end

describe_module "ACCOUNTING", "Annexe 3310-A (taux particuliers)" do
  it "détaille la ligne 14 par taux et la reporte depuis l'annexe" do
    particular_rates_sales
    view = Api.preview_vat_return(system, VatReturnSpec.input("fr_ca3")).value!
    view.annex_lines.map { |line| {line.vat_number, line.amount, line.vat} }.should eq([
      {"COR13", d("1000"), d("130")}, {"TP021", d("500"), d("11")},
    ])
    view.annex_lines.first.name.should contain("13 %")
    {view.amount("14.base"), view.amount("14.tax")}.should eq({d("1500"), d("141")})
    view.amount("16").should eq(d("161"))
    Api.preview_vat_return(system, VatReturnSpec.input("fr_ca12", "year")).value!.annex_lines.size.should eq(2)
  end

  it "conserve l'annexe d'une déclaration enregistrée et l'imprime à la suite des cases" do
    particular_rates_sales
    id = VatReturnSpec.create(VatReturnSpec.input("fr_ca3"))
    Api.vat_return(system, id).annex_lines.map(&.vat_number).should eq(%w[COR13 TP021])
    csv = String.new(Api.vat_return_file(system, id, Api::VatFileFormat::Csv).value!.content)
    csv.should contain("Annexe 3310-A")
    csv.should contain("Taxe due — ")
    Partiduo::LOCALES.each do |locale|
      I18n.with_locale(locale) { I18n.t("accounting.vat_returns.annex_title").should_not contain("missing") }
    end
  end

  it "n'a pas d'annexe sans opération à un taux particulier" do
    VatReturnSpec.setup("fr")
    customer = VatReturnSpec.card("CUSTOMER", "Client Durand")
    VatReturnSpec.sale(customer, [EntrySpec.item("100", "NOR", account: "706")])
    view = Api.preview_vat_return(system, VatReturnSpec.input("fr_ca3")).value!
    view.annex_lines.should be_empty
    view.amount("14.base").should eq(d("0"))
  end
end
