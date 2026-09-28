# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"
require "xml"

# Moteur des déclarations de TVA du socle (lot 4) : règles (`Tva_Amount`),
# totaux des formulaires belge (`Ext_Tva::compute`) et français (CA3, CA12),
# fichiers Intervat (`Declaration_Period`, `Client`, `Client_Intracom`).

private alias Returns = Partiduo::Vat::Returns

private def d(text : String) : BigDecimal
  BigDecimal.new(text)
end

private def movement(source : String, amount : String, account : String = "604", rate : Int64? = 1_i64,
                     kind : String = "purchase", card : Int64? = nil) : Returns::Movement
  Returns::Movement.new(entry_id: 1_i64, date: Time.utc(2026, 1, 15), ledger_id: 1_i64, ledger_kind: kind,
    account: account, vat_rate_id: rate, source: source, amount: d(amount), card_id: card)
end

private def rule(box : String, source : String, rate : Int64? = nil, kind : String? = nil, accounts = [] of String,
                 excluded = [] of String, sign = "all", operation = "add") : Returns::Rule
  Returns::Rule.new(box: box, position: 1, vat_rate_id: rate, ledger_kind: kind, ledger_id: nil, accounts: accounts,
    excluded_accounts: excluded, source: source, sign: sign, operation: operation)
end

describe Partiduo::Vat::Returns do
  it "calcule les bornes d'un mois, d'un trimestre, d'une année" do
    Returns.period("month", 2026, 2).should eq({Time.utc(2026, 2, 1), Time.utc(2026, 2, 28)})
    Returns.period("quarter", 2026, 4).should eq({Time.utc(2026, 10, 1), Time.utc(2026, 12, 31)})
    Returns.period("year", 2026, 1).should eq({Time.utc(2026, 1, 1), Time.utc(2026, 12, 31)})
    Returns.period("month", 2026, 13).should be_nil
    Returns.period("quarter", 2026, 0).should be_nil
  end

  it "lit les préfixes de comptes à la manière de l'application d'origine (`60%,61%`)" do
    Returns.prefixes("60%, 61 ,,22%").should eq(%w[60 61 22])
    Returns.prefixes("").should eq([] of String)
  end

  it "applique taux, nature de journal, comptes retenus et exclus, signe et opération" do
    movements = [
      movement("base", "100", "604"), movement("base", "-30", "604"), movement("base", "50", "2400"),
      movement("base", "70", "604", rate: 2_i64), movement("base", "40", "700", kind: "sale"),
      movement("deductible", "21", "604"),
    ]
    boxes, contributions = Returns.evaluate([
      rule("81", "base", kind: "purchase", accounts: %w[60], sign: "positive"),
      rule("85", "base", kind: "purchase", sign: "negative", operation: "subtract"),
      rule("83", "base", rate: 1_i64, accounts: %w[2]),
      rule("01", "base", rate: 1_i64, kind: "sale"),
      rule("59", "deductible", excluded: %w[2]),
    ], movements)

    boxes["81"].should eq(d("170"))
    boxes["85"].should eq(d("30"))
    boxes["83"].should eq(d("50"))
    boxes["01"].should eq(d("40"))
    boxes["59"].should eq(d("21"))
    contributions.map(&.rule.box).should eq(%w[81 85 83 01 59])
    contributions.first.count.should eq(2)
  end

  it "arrondit les cases au nombre de décimales du formulaire (euros entiers en France)" do
    boxes, _ = Returns.evaluate([rule("09.tax", "collected")], [movement("collected", "5.50")], 0)
    boxes["09.tax"].should eq(d("6"))
  end

  it "totalise par client les montants d'un relevé" do
    movements = [
      movement("base", "300", "700", kind: "sale", card: 7_i64), movement("collected", "63", "700", kind: "sale", card: 7_i64),
      movement("base", "-50", "700", kind: "sale", card: 7_i64), movement("base", "10", "700", kind: "sale", card: nil),
    ]
    totals = Returns.by_card([rule("listing", "base"), rule("listing_vat", "collected")], movements, "listing", "listing_vat")
    totals.should eq({7_i64 => {d("250"), d("63")}})
  end

  it "totalise la déclaration belge : xx, yy, 71 ou 72" do
    amounts = {"54" => d("240"), "55" => d("210"), "61" => d("10"), "59" => d("294"), "64" => d("21")}
    Returns.totals!("be_periodic", amounts)
    amounts["xx"].should eq(d("460"))
    amounts["yy"].should eq(d("315"))
    amounts["71"].should eq(d("145"))
    amounts["72"].should eq(d("0"))

    credit = {"54" => d("10"), "59" => d("50")}
    Returns.totals!("be_periodic", credit)
    credit["71"].should eq(d("0"))
    credit["72"].should eq(d("40"))
  end

  it "totalise la CA3 : TVA brute, déductible, crédit, reste à payer" do
    amounts = {"08.tax" => d("400"), "09.tax" => d("6"), "19" => d("200"), "20" => d("100"), "22" => d("30"), "29" => d("12")}
    Returns.totals!("fr_ca3", amounts)
    amounts["16"].should eq(d("406"))
    amounts["23"].should eq(d("330"))
    amounts["28"].should eq(d("76"))
    amounts["25"].should eq(d("0"))
    amounts["32"].should eq(d("88"))

    credit = {"08.tax" => d("100"), "20" => d("300"), "26" => d("150")}
    Returns.totals!("fr_ca3", credit)
    credit["25"].should eq(d("200"))
    credit["27"].should eq(d("50"))
    credit["28"].should eq(d("0"))
  end

  it "totalise la CA12 : acomptes, solde à payer ou excédent" do
    amounts = {"08.tax" => d("1000"), "20" => d("300"), "ac" => d("500")}
    Returns.totals!("fr_ca12", amounts)
    amounts["28"].should eq(d("700"))
    amounts["sp"].should eq(d("200"))
    amounts["ex"].should eq(d("0"))
    amounts["ac"] = d("900")
    Returns.totals!("fr_ca12", amounts)
    amounts["sp"].should eq(d("0"))
    amounts["ex"].should eq(d("200"))
  end

  describe Partiduo::Vat::Be::Intervat do
    declarant = Partiduo::Vat::Be::Intervat::Party.new("BE0417497106", "Exemple SRL", "Rue Haute 12", "1000",
      "Bruxelles", "BE", "tva@exemple.be", "025555555")

    it "écrit la déclaration périodique : grilles non nulles, sans xx ni yy" do
      text = Partiduo::Vat::Be::Intervat.periodic(declarant, nil, "quarter", 1, 2026,
        [{"03", d("1000")}, {"54", d("210")}, {"xx", d("210")}, {"01", d("0")}, {"71", d("126.5")}], false, true)
      document = XML.parse(text)
      root = ReferentialSpec.present(document.first_element_child)
      root.name.should eq("VATConsignment")
      root.namespace.try(&.href).should eq("http://www.minfin.fgov.be/VATConsignment")
      text.should contain(%(xmlns="http://www.minfin.fgov.be/InputCommon"))
      text.should contain("<VATNumber>0417497106</VATNumber>")
      text.should contain("<ns2:Quarter>1</ns2:Quarter>")
      text.should contain("<ns2:Year>2026</ns2:Year>")
      text.should contain(%(<ns2:Amount GridNumber="3">1000.00</ns2:Amount>))
      text.should contain(%(<ns2:Amount GridNumber="54">210.00</ns2:Amount>))
      text.should contain(%(<ns2:Amount GridNumber="71">126.50</ns2:Amount>))
      text.should_not contain(%(GridNumber="xx"))
      text.should_not contain(%(GridNumber="1"))
      text.should contain("<ns2:ClientListingNihil>NO</ns2:ClientListingNihil>")
      text.should contain(%(<ns2:Ask Restitution="YES"/>))
      text.should_not contain("Representative")
    end

    it "écrit le listing des clients et le relevé intracommunautaire, avec le mandataire" do
      representative = Partiduo::Vat::Be::Intervat::Representative.new("0123456749", "TIN", "BE", "Fiduciaire SC",
        "Avenue 1", "1000", "Bruxelles", "BE", "fid@exemple.be", "02")
      listing = Partiduo::Vat::Be::Intervat.client_listing(declarant, representative, 2026, [
        Partiduo::Vat::Be::Intervat::Client.new("BE0417497106", d("1400"), d("261")),
        Partiduo::Vat::Be::Intervat::Client.new("BE0123456749", d("300.5"), d("63.1")),
      ])
      listing.should contain(%(<ns2:ClientListing VATAmountSum="324.10" TurnOverSum="1700.50" ClientsNbr="2" SequenceNumber="1">))
      listing.should contain("<ns2:Period>2026</ns2:Period>")
      listing.should contain(%(<ns2:CompanyVATNumber issuedBy="BE">0123456749</ns2:CompanyVATNumber>))
      listing.should contain(%(<RepresentativeID identificationType="TIN" issuedBy="BE">0123456749</RepresentativeID>))

      intra = Partiduo::Vat::Be::Intervat.intra_listing(declarant, nil, "month", 3, 2026, [
        Partiduo::Vat::Be::Intervat::Client.new("FR44732829320", d("2000"), code: "L"),
      ])
      intra.should contain(%(<ns2:IntraListing AmountSum="2000.00" ClientsNbr="1" SequenceNumber="1">))
      intra.should contain(%(<ns2:CompanyVATNumber issuedBy="FR">44732829320</ns2:CompanyVATNumber>))
      intra.should contain("<ns2:Code>L</ns2:Code>")
      intra.should contain("<ns2:Month>3</ns2:Month>")
    end
  end
end
