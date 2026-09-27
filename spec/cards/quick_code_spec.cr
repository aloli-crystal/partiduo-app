# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias R = ReferentialSpec

describe Partiduo::Cards::QuickCode do
  # ficheTest::dataFormat_QuickCode et dataUpdateQuickCode.
  {
    {"a+z+1-5", "AZ1-5"}, {"///a+z+1-5", "AZ1-5"}, {"/*/a+z+1-5", "AZ1-5"}, {".2a+z+1-5", ".2AZ1-5"},
    {"ÀÉ@Ê", "AE@E"}, {"ça&\"", "CA"}, {"", ""}, {",,,,", ""}, {"####", ""}, {" a a a a", "AAAA"},
    {"àz-5&é", "AZ-5E"}, {"é####àz-5", "EAZ-5"},
  }.each do |(raw, formatted)|
    it "formate « #{raw} » en « #{formatted} » (format_quickcode)" do
      Partiduo::Cards::QuickCode.format(raw).should eq(formatted)
      Partiduo::Api::Cards.format_code(raw).should eq(formatted)
    end
  end

  it "tire la base d'un code généré du nom, ou CRD" do
    Partiduo::Cards::QuickCode.base_from_name("Boulangerie Martin").should eq("BOULAN")
    Partiduo::Cards::QuickCode.base_from_name("####").should eq("CRD")
  end

  it "numérote les doublons (ficheTest::testQuickCodeNumbering)" do
    category = R.category
    first = R.card(category.id, "Card for PHPUNIT", code: "DUP")
    first.code.should eq("DUP")
    codes = (1..12).map { |index| R.card(category.id, "Base Card #{index}").code }
    codes.first.should eq("BASECA")
    codes[1].should eq("BASECA1")
    codes.last.should eq("BASECA11")
  end
end
