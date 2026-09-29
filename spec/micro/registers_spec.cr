# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias Api = Partiduo::Api::Micro
private alias M = MicroSpec

# ADR-007 D1 : livre des recettes et registre des achats, natifs,
# chronologiques, intangibles (contre-passation datée), édités en PDF et CSV.
describe_module "MICRO", Api do
  it "charge natures et paramètres datés au provisionnement" do
    M.setup
    Api.natures(M.system, "receipt").map(&.category).sort!.should eq(%w[bnc sale_bic service_bic])
    Api.natures(M.system, "purchase").map(&.category).sort!.should eq(%w[goods other])
    Api.parameter_value(M.system, "rate.social.bnc", M.date("2025-06-30")).should eq(M.d("24.6"))
    Api.parameter_value(M.system, "rate.social.bnc", M.date("2026-01-01")).should eq(M.d("25.6"))
    Api.settings(M.system).default_nature_id.should eq(M.nature("SALE").id)
    # Un second chargement ne crée rien.
    Api.load_defaults(M.system).should eq(0)
  end

  it "inscrit une recette numérotée par année et publie micro.receipt.recorded" do
    M.setup
    ReferentialSpec.capture_events("micro.receipt.recorded") do |events|
      first = M.receipt("2026-09-10", "120.50", reference: "F-12")
      second = M.receipt("2026-09-11", "80", "SALE", vat_amount: M.d("0"))
      first.number.should eq("R2026-00001")
      second.number.should eq("R2026-00002")
      first.category.should eq("service_bic")
      first.net_amount.should eq(M.d("120.5"))
      first.origin.should eq("manual")
      first.locked.should be_false
      events.size.should eq(2)
      payload = events.first.payload
      payload["receipt_id"].should eq(first.id.to_s)
      payload["nature_code"].should eq("SERVICE")
      payload["category"].should eq("service_bic")
      payload["amount"].should eq("120.5")
      payload["origin"].should eq("manual")
      payload["date"].should eq("2026-09-10")
    end
    Api.receipts(M.system).map(&.number).should eq(%w[R2026-00001 R2026-00002])
  end

  it "refuse une saisie invalide, avec des messages traduits" do
    M.setup
    purchase_nature = M.nature("GOODS")
    result = Api.record_receipt(M.actor, M.receipt_input("2026-12-01", "-3", method: "bitcoin",
      nature_id: purchase_nature.id, card_id: 999_999_i64, attachment_id: 999_999_i64, reference: "x" * 101))
    result.failure?.should be_true
    result.error_keys.sort.should eq(%w[
      micro.errors.line.amount.not_positive micro.errors.line.attachment.unknown micro.errors.line.card.unknown
      micro.errors.line.date.future micro.errors.line.method.invalid micro.errors.line.nature.unknown
      micro.errors.line.too_long
    ].sort)
    ReferentialSpec.expect_translated(result)
    Api.record_receipt(M.actor, M.receipt_input(amount: "10.005")).error_keys.should eq(["micro.errors.line.amount.scale"])
    Api.record_receipt(M.actor, M.receipt_input(amount: "10", vat_amount: M.d("10")))
      .error_keys.should eq(["micro.errors.line.vat_amount.exceeds"])
    Api.check_receipt(M.actor, M.receipt_input).success?.should be_true
    Api.receipts(M.system).should be_empty
  end

  it "contre-passe une ligne à une date donnée, sans la modifier" do
    M.setup
    line = M.receipt("2026-09-10", "100")
    reversal = Api.reverse_receipt(M.actor, Api::ReverseInput.new(line.id, M.date("2026-09-20"))).value!
    reversal.amount.should eq(M.d("-100"))
    reversal.reversal_of_id.should eq(line.id)
    reversal.label.should eq("Annulation de #{line.number}")
    Api.receipt(M.system, line.id).reversed_by_id.should eq(reversal.id)
    again = Api.reverse_receipt(M.actor, Api::ReverseInput.new(line.id, M.date("2026-09-21")))
    again.error_keys.should eq(["micro.errors.line.reversal.already"])
    Api.reverse_receipt(M.actor, Api::ReverseInput.new(reversal.id, M.date("2026-09-21")))
      .error_keys.should eq(["micro.errors.line.reversal.is_reversal"])
    other = M.receipt("2026-09-15", "10")
    Api.reverse_receipt(M.actor, Api::ReverseInput.new(other.id, M.date("2026-09-14")))
      .error_keys.should eq(["micro.errors.line.reversal.before_line"])
  end

  it "rend une période close intangible : ni saisie, ni modification, correction dans une période ouverte" do
    M.setup
    line = M.receipt("2026-08-10", "100")
    M.close_period("2026-08-10")
    Api.receipt(M.system, line.id).locked.should be_true
    Api.record_receipt(M.actor, M.receipt_input("2026-08-20")).error_keys.should eq(["micro.errors.line.date.closed_period"])
    Api.reverse_receipt(M.actor, Api::ReverseInput.new(line.id, M.date("2026-08-31")))
      .error_keys.should eq(["micro.errors.line.date.closed_period"])
    Api.reverse_receipt(M.actor, Api::ReverseInput.new(line.id, M.date("2026-09-01"))).success?.should be_true
  end

  it "garde l'intangibilité en base (déclencheur, contraintes)" do
    M.setup
    line = M.receipt("2026-08-10", "100")
    InvoicingSpec.sql_error("UPDATE micro_receipt SET amount = 1 WHERE id = $1", line.id).to_s.should contain("intangible")
    InvoicingSpec.sql_error("DELETE FROM micro_receipt WHERE id = $1", line.id).to_s.should contain("intangible")
    M.close_period("2026-08-10")
    nature = M.nature("SERVICE").id
    sql = "INSERT INTO micro_receipt (number, date, nature_id, category, amount, vat_amount, method, party_name, label, " \
          "reference, origin, source, recorded_at) VALUES ($1, '2026-08-11', $2, 'service_bic', 5, 0, 'cash', '', '', '', " \
          "'manual', '', now())"
    InvoicingSpec.sql_error(sql, "X-1", nature).to_s.should contain("période close")
    InvoicingSpec.sql_error(sql.sub("'2026-08-11'", "'2026-09-11'").sub(", 5, 0,", ", -5, 0,"), "X-2", nature)
      .to_s.should contain("micro_receipt_amount_check")
  end

  it "tient le registre des achats et son récapitulatif annuel" do
    M.setup
    ReferentialSpec.capture_events("micro.purchase.recorded") do |events|
      M.purchase("2026-09-12", "40")
      M.purchase("2026-09-13", "15.20", "SUPPLIES")
      events.map(&.["purchase_id"]).size.should eq(2)
    end
    Api.purchases(M.system).map(&.number).should eq(%w[A2026-00001 A2026-00002])
    totals = Api.purchase_totals(M.system, 2026)
    totals.map { |row| {row.nature_code, row.amount} }.should eq([{"GOODS", M.d("40")}, {"SUPPLIES", M.d("15.2")}])
  end

  it "rattache une pièce jointe du socle" do
    M.setup
    stored = Partiduo::Api::Core.store_attachment(M.uploader, Partiduo::Api::Core::AttachmentInput.new("ticket.pdf",
      "application/pdf", IO::Memory.new("%PDF-1.4 ticket"))).value!
    line = M.purchase(attachment_id: stored.id)
    line.attachment_id.should eq(stored.id)
  end

  it "refuse la pièce jointe d'un autre sans droit de lecture des pièces jointes" do
    M.setup
    other = Partiduo::Api::Core.store_attachment(M.system, Partiduo::Api::Core::AttachmentInput.new("autre.pdf",
      "application/pdf", IO::Memory.new("%PDF-1.4 autre"))).value!
    input = M.receipt_input(attachment_id: other.id)
    Api.record_receipt(M.actor, input).error_keys.should eq(["micro.errors.line.attachment.unknown"])
    reader = Partiduo::Api::Actor.user(9_i64, M::PERMISSIONS + ["core.attachment.read"])
    Api.record_receipt(reader, input).value!.attachment_id.should eq(other.id)
  end

  it "édite le livre des recettes en CSV et en PDF" do
    M.setup
    M.receipt("2026-09-10", "100", party_name: "=cmd")
    M.receipt("2026-09-11", "50.25", "SALE")
    query = Api::RegisterQuery.new(from: M.date("2026-01-01"), to: M.date("2026-12-31"))
    csv = Api.export_receipts(M.system, query, Api::ExportFormat::Csv)
    csv.filename.should eq("livre-recettes.csv")
    text = String.new(csv.content)
    text.lines.size.should eq(3)
    text.should contain("'=cmd")
    text.should contain("50.25")
    pdf = Api.export_purchases(M.system, query, Api::ExportFormat::Pdf)
    String.new(pdf.content[0, 5]).should eq("%PDF-")
    receipts_pdf = Api.export_receipts(M.system, query, Api::ExportFormat::Pdf)
    receipts_pdf.content_type.should eq("application/pdf")
    receipts_pdf.content.size.should be > 1000
  end

  it "gère les natures : code figé une fois employée" do
    M.setup
    nature = Api.create_nature(M.actor, Api::NatureInput.new("cours", "Cours particuliers", "receipt", "bnc")).value!
    nature.code.should eq("COURS")
    Api.create_nature(M.actor, Api::NatureInput.new("COURS", "Doublon", "receipt", "goods"))
      .error_keys.sort.should eq(%w[micro.errors.nature.category.invalid micro.errors.nature.code.taken])
    M.receipt(nature: "COURS")
    Api.update_nature(M.actor, nature.id, Api::NatureInput.new("COURS", "Cours", "receipt", "service_bic"))
      .error_keys.should eq(["micro.errors.nature.in_use"])
    Api.update_nature(M.actor, nature.id, Api::NatureInput.new("COURS", "Cours", "receipt", "bnc", enabled: false))
      .value!.enabled.should be_false
    Api.record_receipt(M.actor, M.receipt_input(nature: "COURS")).error_keys.should eq(["micro.errors.line.nature.disabled"])
  end
end

describe "Module micro inactif (ADR-006 D2)" do
  it "refuse toute commande et toute requête" do
    with_active_modules("invoicing") do
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.receipts(M.system) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.thresholds(M.system, 2026) }
    end
  end

  it "exige les permissions du module" do
    with_active_modules("micro") do
      expect_raises(Partiduo::Api::Forbidden) { Api.receipts(actor_with) }
      expect_raises(Partiduo::Api::Forbidden) do
        Api.record_receipt(actor_with("micro.register.read"), Api::ReceiptInput.new(date: M.date("2026-09-01"),
          nature_id: 1_i64, amount: M.d("1"), method: "cash"))
      end
      expect_raises(Partiduo::Api::Forbidden) do
        Api.set_parameter(actor_with("micro.register.write"), Api::ParameterInput.new("alert.ratio", M.date("2026-01-01"), M.d("90")))
      end
    end
  end
end
