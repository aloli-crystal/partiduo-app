# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Formules des états (`Impress::parse_formula`, `check_formula`), sans base.

private class FakeContext < Partiduo::Accounting::Formula::Context
  getter calls = [] of String

  def account(pattern : String, prefix : Bool, mode : Char?) : BigDecimal
    @calls << "#{pattern}#{prefix ? "%" : ""}#{mode ? "-#{mode}" : ""}"
    BigDecimal.new(pattern.size * 10)
  end

  def card(code : String, mode : Char?) : BigDecimal
    @calls << "{#{code}#{mode ? "-#{mode}" : ""}}"
    BigDecimal.new(7)
  end

  def variable(name : String) : BigDecimal
    name == "X" ? BigDecimal.new(100) : raise Partiduo::Accounting::Formula::Error.new("variable", {"name" => name})
  end
end

private def evaluate(text : String, context = FakeContext.new) : BigDecimal
  Partiduo::Accounting::Formula.parse(text).evaluate(context)
end

describe Partiduo::Accounting::Formula do
  it "calcule avec priorités, parenthèses, signes et fonctions" do
    evaluate("1+2*3").should eq(7)
    evaluate("(1+2)*3").should eq(9)
    evaluate("-2+-(3)").should eq(-5)
    evaluate("10/4").should eq(BigDecimal.new("2.5"))
    evaluate("5/0").should eq(0)
    evaluate("abs(-3)+max(1, 2)+min(1, 2)").should eq(6)
    evaluate("round(2.345, 2)").should eq(BigDecimal.new("2.35"))
    evaluate("round(2.5)").should eq(3)
    evaluate("$X/4").should eq(25)
  end

  it "lit les références de comptes, de fiches et leurs modes" do
    context = FakeContext.new
    evaluate("[70%]+[706]-[6%-s]+[40%-S]+[41%-D]+[41%-C]+[7%-d]+[7%-c]+{cli01-s}", context).should eq(BigDecimal.new(127))
    context.calls.should eq(%w[70% 706 6%-s 40%-S 41%-D 41%-C 7%-d 7%-c {CLI01-s}])
    parsed = Partiduo::Accounting::Formula.parse("[60%]-[6061]")
    parsed.accounts.map(&.pattern).should eq(%w[60 6061])
    parsed.accounts.first.covers?("6063").should be_true
    parsed.accounts.last.covers?("60611").should be_false
  end

  it "reconnaît FROM=MM.AAAA" do
    parsed = Partiduo::Accounting::Formula.parse("[70%] FROM=03.2026")
    parsed.from.should eq(Time.utc(2026, 3, 1))
    Partiduo::Accounting::Formula.check("[70%] FROM=13.2026").try(&.key).should eq("from")
  end

  it "refuse ce qu'elle ne sait pas calculer" do
    {"" => "empty", "[70%" => "syntax", "1+" => "syntax", "2 3" => "syntax", "sqrt(2)" => "function",
     "round()" => "syntax", "max(1)" => "arguments", "[]" => "account", "{{AXE}}" => "analytic",
     "$C1" => "variable", "[70%]?1:2" => "syntax", "system('ls')" => "function"}.each do |text, key|
      Partiduo::Accounting::Formula.check(text).try(&.key).should eq(key)
    end
    Partiduo::Accounting::Formula.check("$C1", variables: true).should be_nil
    Partiduo::Accounting::Formula.check("round([70%-s]*1.2, 2)").should be_nil
  end

  it "borne la longueur et l'imbrication d'une formule" do
    formula = Partiduo::Accounting::Formula
    formula.check("(" * 100_000).try(&.key).should eq("too_long")
    formula.check("-" * 100_000 + "1").try(&.key).should eq("too_long")
    formula.check("(" * 60 + "1" + ")" * 60).try(&.key).should eq("depth")
    formula.check("-" * 60 + "1").try(&.key).should eq("depth")
    formula.check("abs(" * 60 + "1" + ")" * 60).try(&.key).should eq("depth")
    evaluate("(" * 40 + "2" + ")" * 40).should eq(2)
    evaluate("1+" * 499 + "1").should eq(500)
    formula.check("1+" * 500 + "1").try(&.key).should eq("too_long")
  end

  it "n'admet pour round qu'un nombre de décimales entier de 0 à 10" do
    formula = Partiduo::Accounting::Formula
    {"round(1, 100000000)", "round(1, 1.5)", "round(1, -1)", "round(1, 11)",
     "round(1, 99999999999999999999999999)"}.each do |text|
      formula.check(text).try(&.key).should eq("round")
    end
    evaluate("round(1.23456, 10)").should eq(BigDecimal.new("1.23456"))
    evaluate("round(2.345, 1+1)").should eq(BigDecimal.new("2.35"))
    # Nombre de décimales calculé : refusé au calcul.
    expect_raises(Partiduo::Accounting::Formula::Error, "round") { evaluate("round(1, [7%]*1000000)") }
    expect_raises(Partiduo::Accounting::Formula::Error, "round") { evaluate("round(1, 1/3)") }
  end
end
