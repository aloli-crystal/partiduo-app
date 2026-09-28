# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias Api = Partiduo::Api::Liberal
private alias L = LiberalSpec
private alias Core = Partiduo::Api::Core

# Lot L (tests) : pièces jointes (règle de D-MIC-015 reprise), chargement
# des données par défaut dans une autre langue, republication des
# événements et charge utile de `liberal.asset.recorded`.

private def stored(actor : Partiduo::Api::Actor, name : String) : Core::AttachmentView
  Core.store_attachment(actor, Core::AttachmentInput.new(name, "application/pdf", IO::Memory.new("%PDF-1.4 #{name}"))).value!
end

describe_module "LIBERAL", Api do
  it "rattache la pièce jointe déposée par l'acteur, refuse celle d'un autre sans droit de lecture" do
    L.setup
    own = stored(Partiduo::Api::Actor.user(9_i64, ["core.attachment.write"]), "ticket.pdf")
    L.expense(attachment_id: own.id).attachment_id.should eq(own.id)

    other = stored(L.system, "autre.pdf")
    Api.record_expense(L.actor, L.input("2026-09-01", "10", "OFFICE", attachment_id: other.id)).error_keys
      .should eq(["liberal.errors.line.attachment.unknown"])
    Api.check_asset(L.actor, Api::AssetInput.new(label: "Table", category: "furniture", acquired_on: L.date("2026-09-01"),
      amount: L.d("500"), duration_years: 5, method: "card", attachment_id: other.id)).error_keys
      .should eq(["liberal.errors.line.attachment.unknown"])
    reader = Partiduo::Api::Actor.user(9_i64, L::PERMISSIONS + ["core.attachment.read"])
    Api.record_expense(reader, L.input("2026-09-01", "10", "OFFICE", attachment_id: other.id)).value!
      .attachment_id.should eq(other.id)
  end

  it "charge natures et table en anglais, sans doubler ce qui existe" do
    ReferentialSpec.fiscal_year(2026)
    Api.natures(L.system).should be_empty
    created = Api.load_defaults(L.system, "en")
    created.should be > Api::HEADINGS.size
    Api.natures(L.system).size.should eq(Api::HEADINGS.size)
    Api.natures(L.system).find!(&.code.==("RENT")).label
      .should eq(I18n.with_locale("en") { I18n.t("liberal.headings.rent") })
    Api.settings(L.system).default_nature_id.should eq(L.nature("RECEIPTS").id)
    # Langue inconnue : français, et rien de neuf.
    Api.load_defaults(L.system, "xx").should eq(0)
  end

  it "republie dans l'ordre les lignes, les immobilisations et les cessions, charge utile complète" do
    L.setup
    L.receipt("2026-09-10", "100")
    asset = L.asset("2026-04-01", "1200", 3, category: "equipment", party_name: "Fournisseur")
    Api.dispose_asset(L.actor, Api::DisposalInput.new(asset.id, L.date("2026-09-01"), L.d("900"), "cheque", "ACTE-1")).value!
    ReferentialSpec.capture_events("liberal.asset.recorded") do |events|
      ReferentialSpec.capture_events("liberal.receipt.recorded") do |receipts|
        Api.republish(L.actor).should eq(3)
        receipts.size.should eq(1)
      end
      events.map(&.payload["operation"]).should eq(%w[acquisition disposal])
      disposal = events.last.payload
      {L.d(disposal["amount"]), disposal["method"], disposal["reference"], disposal["date"]}
        .should eq({L.d("900"), "cheque", "ACTE-1", "2026-09-01"})
      disposal["disposal_id"].should_not be_empty
      acquisition = events.first.payload
      {L.d(acquisition["amount"]), acquisition["category"], acquisition["party_name"], acquisition["disposal_id"]}
        .should eq({L.d("1200"), "equipment", "Fournisseur", ""})
    end
  end
end
