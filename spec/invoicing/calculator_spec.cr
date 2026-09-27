# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias Calc = Partiduo::Invoicing::Calculator

private def d(text : String) : BigDecimal
  BigDecimal.new(text)
end

private def item(quantity : String, price : String, percent : String = "20", category : String = "S",
                 discount_kind : String = "none", discount : String = "0", rate_id : Int64? = 1_i64,
                 card_id : Int64? = nil) : Calc::LineData
  Calc::LineData.new(kind: "item", quantity: d(quantity), unit_price: d(price), discount_kind: discount_kind,
    discount_value: d(discount), vat_rate_id: rate_id, vat_percent: d(percent), vat_category: category,
    item_card_id: card_id)
end

# Calculs exacts en décimal, arrondis explicites (ADR-006 D5, convention C1).
describe "Facturation — calculs (Calculator)" do
  it "arrondit au centime, demi supérieur en valeur absolue" do
    Calc.round(d("2.345")).should eq(d("2.35"))
    Calc.round(d("-2.345")).should eq(d("-2.35"))
    Calc.round(d("2.3449")).should eq(d("2.34"))
    Calc.line(item("3", "0.335")).net.should eq(d("1.01"))
  end

  it "applique une remise de ligne en pourcentage ou en montant" do
    percent = Calc.line(item("3", "19.99", discount_kind: "percent", discount: "12.5"))
    percent.gross.should eq(d("59.97"))
    percent.discount.should eq(d("7.50")) # 59,97 × 12,5 % = 7,49625 → 7,50
    percent.net.should eq(d("52.47"))
    amount = Calc.line(item("2", "100", discount_kind: "amount", discount: "15.5"))
    amount.net.should eq(d("184.5"))
  end

  it "calcule la TVA par groupe sur la base arrondie (BR-CO-17), pas ligne à ligne" do
    lines = [item("1", "0.10"), item("1", "0.10"), item("1", "0.10")]
    totals = Calc.compute(lines)
    totals.total_net.should eq(d("0.30"))
    totals.total_vat.should eq(d("0.06")) # et non 3 × 0,02
    totals.total_gross.should eq(d("0.36"))
  end

  it "ventile la remise globale entre les groupes de TVA sans perdre un centime" do
    lines = [item("1", "100", "20", rate_id: 1_i64), item("1", "33.33", "5.5", rate_id: 2_i64),
             item("1", "10", "0", "E", rate_id: 3_i64)]
    totals = Calc.compute(lines, "percent", d("10"))
    totals.lines_total.should eq(d("143.33"))
    totals.discount_total.should eq(d("14.33"))
    totals.groups.sum(BigDecimal.new(0), &.allowance).should eq(d("14.33"))
    totals.groups.map(&.base).should eq([d("90.00"), d("30.00"), d("9.00")])
    totals.groups.map(&.vat).should eq([d("18.00"), d("1.65"), d("0.00")])
    totals.total_net.should eq(totals.lines_total - totals.discount_total)
    totals.total_gross.should eq(d("148.65"))
  end

  it "regroupe deux taux du socle de même catégorie et même pourcentage" do
    totals = Calc.compute([item("1", "10", "2.1", rate_id: 1_i64), item("1", "10", "2.10", rate_id: 2_i64)])
    totals.groups.size.should eq(1)
    totals.groups.first.vat.should eq(d("0.42"))
  end

  it "remet des parts de vente par article et taux dont la somme vaut le total HT" do
    lines = [item("3", "33.33", card_id: 10_i64), item("1", "0.01", card_id: 11_i64),
             item("7", "1.43", "5.5", rate_id: 2_i64, card_id: 10_i64)]
    totals = Calc.compute(lines, "amount", d("7.77"))
    totals.shares.sum(BigDecimal.new(0), &.amount).should eq(totals.total_net)
  end

  it "calcule les sous-totaux depuis le titre ou le sous-total précédent, hors totaux" do
    lines = [Calc::LineData.new(kind: "title"), item("1", "10"), item("2", "5"),
             Calc::LineData.new(kind: "subtotal"), item("1", "1"), Calc::LineData.new(kind: "note"),
             Calc::LineData.new(kind: "subtotal")]
    totals = Calc.compute(lines)
    totals.lines[3].net.should eq(d("20"))
    totals.lines[6].net.should eq(d("1"))
    totals.lines_total.should eq(d("21"))
  end

  it "écrit un décimal sans exposant ni zéro final" do
    Calc.plain(d("20.0000")).should eq("20")
    Calc.plain(d("0.00001")).should eq("0.00001")
    Calc.plain(d("-1250.50")).should eq("-1250.5")
    Calc.scale(d("1.2300")).should eq(2)
  end
end
