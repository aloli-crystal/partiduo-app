# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

describe Partiduo::Core::Identifiers do
  it "contrôle la clé de Luhn du SIREN" do
    Partiduo::Core::Identifiers.valid_siren?("732829320").should be_true
    Partiduo::Core::Identifiers.valid_siren?("542065479").should be_true
    Partiduo::Core::Identifiers.valid_siren?("732829321").should be_false
    Partiduo::Core::Identifiers.valid_siren?("73282932").should be_false
    Partiduo::Core::Identifiers.valid_siren?("73282932A").should be_false
  end

  it "contrôle le SIRET, exception de La Poste comprise" do
    Partiduo::Core::Identifiers.valid_siret?("73282932000074").should be_true
    Partiduo::Core::Identifiers.valid_siret?("73282932000075").should be_false
    Partiduo::Core::Identifiers.valid_siret?("35600000000001").should be_true
  end

  it "compacte un identifiant saisi avec espaces et ponctuation" do
    Partiduo::Core::Identifiers.compact("fr 44 732.829-320").should eq("FR44732829320")
  end
end

describe Partiduo::Vat::Fr::VatNumber do
  it "contrôle la clé numérique" do
    Partiduo::Vat::Fr::VatNumber.valid?("FR44732829320").should be_true
    Partiduo::Vat::Fr::VatNumber.valid?("FR45732829320").should be_false
    Partiduo::Vat::Fr::VatNumber.valid?("FR4473282932").should be_false
  end

  it "admet une clé alphanumérique sur sa seule forme" do
    Partiduo::Vat::Fr::VatNumber.valid?("FRAB732829320").should be_true
  end

  it "extrait le SIREN" do
    Partiduo::Vat::Fr::VatNumber.siren("FR44732829320").should eq("732829320")
    Partiduo::Vat::Fr::VatNumber.siren("BE0403170701").should be_nil
  end
end

describe Partiduo::Vat::Be::VatNumber do
  it "contrôle le modulo 97 du numéro d'entreprise" do
    Partiduo::Vat::Be::VatNumber.valid?("BE0403170701").should be_true
    Partiduo::Vat::Be::VatNumber.valid?("BE0417497106").should be_true
    Partiduo::Vat::Be::VatNumber.valid?("BE0403170702").should be_false
    Partiduo::Vat::Be::VatNumber.valid?("BE2403170701").should be_false
    Partiduo::Vat::Be::VatNumber.valid?("BE403170701").should be_false
  end
end

describe PG::Numeric do
  it "relit en BigDecimal les multiples de 10 000 (correctif de crystal-pg)" do
    Marten::DB::Connection.default.open do |db|
      %w[10000 20000000 10000.5 0.0001 -30000 123456789.1234 0].each do |literal|
        db.query_one("SELECT #{literal}::numeric(20,4)", as: BigDecimal).should eq(BigDecimal.new(literal))
      end
    end
  end
end
