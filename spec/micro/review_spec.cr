# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias Api = Partiduo::Api::Micro
private alias M = MicroSpec

# Clôture du lot G (relecture) : « À traiter » borné pour une activité
# reprise, pages de registre plafonnées, totaux par agrégat, TVA déductible
# des achats, libellés et noms de fichiers traduits.
describe_module "MICRO", Api do
  it "ne remonte pas au-delà de l'année précédente les échéances d'une activité reprise" do
    M.setup(activity_started_on: M.date("2015-03-01"))
    items = Api.todo(M.system, M.date("2026-09-27")).select(&.kind.==("declaration"))
    # 2025 (quatre trimestres) et 2026 (deux trimestres échus) au plus.
    items.size.should eq(6)
    items.min_of { |item| item.params["from"] }.should eq("2025-01-01")
  end

  it "plafonne une page de registre et refuse une pagination négative" do
    M.setup
    M.receipt("2026-09-10", "100")
    Api.receipts(M.system, Api::RegisterQuery.new(limit: 1_000_000)).size.should eq(1)
    expect_raises(ArgumentError) { Api.receipts(M.system, Api::RegisterQuery.new(limit: -1)) }
    expect_raises(ArgumentError) { Api.purchases(M.system, Api::RegisterQuery.new(offset: -5)) }
  end

  it "totalise un registre et le récapitule par nature sans charger les lignes" do
    M.setup
    M.receipt("2026-09-10", "120", vat_amount: M.d("20"))
    line = M.receipt("2026-09-11", "30", "SALE")
    Api.reverse_receipt(M.actor, Api::ReverseInput.new(line.id, M.date("2026-09-12"))).value!
    M.receipt("2025-12-31", "999")
    year = Api::RegisterQuery.new(from: M.date("2026-01-01"), to: M.date("2026-12-31"))
    total = Api.receipts_total(M.system, year)
    {total.count, total.amount, total.vat_amount, total.net_amount}.should eq({3, M.d("120"), M.d("20"), M.d("100")})
    Api.receipt_totals(M.system, 2026).map { |row| {row.nature_code, row.amount, row.count} }
      .should eq([{"SALE", M.d("0"), 2}, {"SERVICE", M.d("120"), 1}])
    Api.purchases_total(M.system, year).count.should eq(0)
  end

  it "inscrit la TVA déductible d'un achat, la contre-passe et la récapitule" do
    M.setup
    line = M.purchase("2026-09-12", "120", vat_amount: M.d("20"))
    line.vat_amount.should eq(M.d("20"))
    line.net_amount.should eq(M.d("100"))
    reversal = Api.reverse_purchase(M.actor, Api::ReverseInput.new(line.id, M.date("2026-09-13"))).value!
    reversal.vat_amount.should eq(M.d("-20"))
    M.purchase("2026-09-14", "60", vat_amount: M.d("10"))
    totals = Api.purchase_totals(M.system, 2026).find! { |row| row.nature_code == "GOODS" }
    {totals.amount, totals.vat_amount, totals.net_amount}.should eq({M.d("60"), M.d("10"), M.d("50")})
    input = Api::PurchaseInput.new(date: M.date("2026-09-14"), nature_id: M.nature("GOODS").id, amount: M.d("10"),
      method: "card", vat_amount: M.d("10"))
    Api.record_purchase(M.actor, input).error_keys.should eq(["micro.errors.line.vat_amount.exceeds"])
    Api.record_purchase(M.actor, input.copy_with(vat_amount: M.d("-1"))).error_keys
      .should eq(["micro.errors.line.vat_amount.invalid"])
  end

  it "nomme les éditions et l'annulation dans la langue courante" do
    M.setup
    line = M.receipt("2026-09-10", "100")
    I18n.with_locale("en") do
      Api.export_receipts(M.system, Api::RegisterQuery.new, Api::ExportFormat::Csv).filename.should eq("receipts-book.csv")
      Api.export_purchases(M.system, Api::RegisterQuery.new, Api::ExportFormat::Csv).filename.should eq("purchase-register.csv")
      Api.reverse_receipt(M.actor, Api::ReverseInput.new(line.id, M.date("2026-09-10"))).value!.label
        .should eq("Cancellation of #{line.number}")
    end
  end
end
