# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"
require "stumpy_png"

private alias Api = Partiduo::Api::Invoicing

private def d(text : String) : BigDecimal
  BigDecimal.new(text)
end

# Rapport de `pdf-validate` (profil PDF/A-3b) : règles fatales en échec, hors
# la règle écartée (B-INV-001).
private def pdfa3_failures(bytes : Bytes) : Array(String)
  report = PDF::Validate.bytes(bytes, profile: "pdf-a-3b")
  report.fatal_failures.map(&.rule.id) - Partiduo::Invoicing::Output::IGNORED_RULES
end

private def xmp(bytes : Bytes) : String
  text = String.new(bytes, "ISO-8859-1")
  text[text.index!("<x:xmpmeta")..text.index!("</x:xmpmeta>")]
end

private def facturx(bytes : Bytes) : {PDF::AttachedFile, XML::Node}
  files = PDF::AttachedFile.list(PDF::Reader.new(bytes))
  files.size.should eq(1)
  file = files.first
  {file, XML.parse(String.new(file.data))}
end

private def xpath(document : XML::Node, path : String) : String
  namespaces = {"rsm" => Partiduo::Invoicing::FacturxXml::NS_RSM, "ram" => Partiduo::Invoicing::FacturxXml::NS_RAM,
                "udt" => Partiduo::Invoicing::FacturxXml::NS_UDT, "qdt" => Partiduo::Invoicing::FacturxXml::NS_QDT}
  document.xpath_node(path, namespaces).try(&.content) || raise "absent : #{path}"
end

private def xpaths(document : XML::Node, path : String) : Array(String)
  namespaces = {"rsm" => Partiduo::Invoicing::FacturxXml::NS_RSM, "ram" => Partiduo::Invoicing::FacturxXml::NS_RAM,
                "udt" => Partiduo::Invoicing::FacturxXml::NS_UDT}
  document.xpath_nodes(path, namespaces).map(&.content)
end

private def pdf(id : Int64) : Bytes
  Api.document_pdf(InvoicingSpec.actor, id).content
end

private def png_logo : Bytes
  canvas = StumpyPNG::Canvas.new(40, 20, StumpyPNG::RGBA.from_hex("#1f5f73"))
  io = IO::Memory.new
  StumpyPNG.write(canvas, io)
  io.to_slice
end

# ADR-006 D5 : PDF/A-3 Factur-X (XML CII EN 16931 embarqué), contrôlé par
# `pdf-validate`.
describe_module "INVOICING", "Facturation — PDF/A-3 Factur-X" do
  it "produit une facture PDF/A-3 conforme, XML CII 380 embarqué et déclaré en XMP" do
    setup = InvoicingSpec.setup
    invoice = InvoicingSpec.issued(setup, global_discount_kind: "percent", global_discount_value: d("5"),
      lines: [InvoicingSpec.line(setup, "10", discount_kind: "percent", discount_value: d("10")),
              InvoicingSpec.line(setup, "3", item_card_id: setup.goods.id),
              InvoicingSpec.line(setup, "1", vat_rate_id: setup.rates["TR55"].id, unit_price: d("12.34"))])
    bytes = pdf(invoice.id)
    String.new(bytes[0, 8]).should start_with("%PDF-")
    pdfa3_failures(bytes).should eq([] of String)
    metadata = xmp(bytes)
    metadata.should contain("<pdfaid:part>3</pdfaid:part>")
    metadata.should contain("<fx:DocumentType>INVOICE</fx:DocumentType>")
    metadata.should contain("<fx:ConformanceLevel>EN 16931</fx:ConformanceLevel>")
    metadata.should contain("<pdfaSchema:prefix>fx</pdfaSchema:prefix>")

    file, xml = facturx(bytes)
    file.name.should eq("factur-x.xml")
    file.relationship.should eq("Data")
    String.new(file.data).should eq(String.new(Api.facturx_xml(InvoicingSpec.actor, invoice.id).content))
    xpath(xml, "//rsm:ExchangedDocumentContext/ram:GuidelineSpecifiedDocumentContextParameter/ram:ID")
      .should eq("urn:cen.eu:en16931:2017")
    xpath(xml, "//rsm:ExchangedDocument/ram:ID").should eq("F-2026-0001")
    xpath(xml, "//rsm:ExchangedDocument/ram:TypeCode").should eq("380")
    xpath(xml, "//ram:BuyerTradeParty/ram:SpecifiedLegalOrganization/ram:ID").should eq("443061841")
    xpath(xml, "//ram:SellerTradeParty/ram:SpecifiedTaxRegistration/ram:ID").should eq("FR44732829320")

    # Cohérence des montants (BR-CO-10, 13, 15, 16) et des groupes de TVA.
    summation = "//ram:SpecifiedTradeSettlementHeaderMonetarySummation"
    line_total = d(xpath(xml, "#{summation}/ram:LineTotalAmount"))
    allowances = d(xpath(xml, "#{summation}/ram:AllowanceTotalAmount"))
    basis = d(xpath(xml, "#{summation}/ram:TaxBasisTotalAmount"))
    tax = d(xpath(xml, "#{summation}/ram:TaxTotalAmount"))
    grand = d(xpath(xml, "#{summation}/ram:GrandTotalAmount"))
    xpaths(xml, "//ram:SpecifiedLineTradeSettlement/ram:SpecifiedTradeSettlementLineMonetarySummation/ram:LineTotalAmount")
      .sum(BigDecimal.new(0)) { |amount| d(amount) }.should eq(line_total)
    basis.should eq(line_total - allowances)
    grand.should eq(basis + tax)
    grand.should eq(invoice.totals.total_gross)
    xpaths(xml, "//ram:ApplicableHeaderTradeSettlement/ram:ApplicableTradeTax/ram:CalculatedAmount")
      .sum(BigDecimal.new(0)) { |amount| d(amount) }.should eq(tax)
    xpaths(xml, "//ram:ApplicableHeaderTradeSettlement/ram:SpecifiedTradeAllowanceCharge/ram:ActualAmount")
      .sum(BigDecimal.new(0)) { |amount| d(amount) }.should eq(allowances)
    xpaths(xml, "//rsm:ExchangedDocument/ram:IncludedNote/ram:SubjectCode").should contain("PMT")
  end

  it "produit un avoir 381 qui cite la facture d'origine, et une facture d'acompte 386" do
    setup = InvoicingSpec.setup
    invoice = InvoicingSpec.issued(setup)
    credit = Api.transform(InvoicingSpec.actor, invoice.id, Api::TransformInput.new("credit_note")).value!
    credit = InvoicingSpec.issue(credit.id, "2026-09-20")
    bytes = pdf(credit.id)
    pdfa3_failures(bytes).should eq([] of String)
    _, xml = facturx(bytes)
    xpath(xml, "//rsm:ExchangedDocument/ram:TypeCode").should eq("381")
    xpath(xml, "//ram:InvoiceReferencedDocument/ram:IssuerAssignedID").should eq("F-2026-0001")
    xpath(xml, "//ram:InvoiceReferencedDocument/ram:FormattedIssueDateTime/qdt:DateTimeString").should eq("20260915")
    d(xpath(xml, "//ram:GrandTotalAmount")).should eq(invoice.totals.total_gross)

    order = InvoicingSpec.issued(setup, "order")
    deposit = Api.transform(InvoicingSpec.actor, order.id,
      Api::TransformInput.new("deposit_invoice", deposit_percent: d("50"))).value!
    deposit_bytes = pdf(InvoicingSpec.issue(deposit.id, "2026-09-21").id)
    pdfa3_failures(deposit_bytes).should eq([] of String)
    xpath(facturx(deposit_bytes)[1], "//rsm:ExchangedDocument/ram:TypeCode").should eq("386")
  end

  it "produit un PDF/A-3 sans XML pour un devis et un aperçu de brouillon" do
    setup = InvoicingSpec.setup
    quote = InvoicingSpec.issued(setup, "quote")
    bytes = pdf(quote.id)
    pdfa3_failures(bytes).should eq([] of String)
    PDF::AttachedFile.list(PDF::Reader.new(bytes)).should be_empty
    expect_raises(Partiduo::Api::NotFound) { Api.facturx_xml(InvoicingSpec.actor, quote.id) }
    draft = InvoicingSpec.draft(setup)
    pdfa3_failures(pdf(draft.id)).should eq([] of String)
    Api.document_pdf(InvoicingSpec.actor, draft.id).filename.should eq("draft-#{draft.id}.pdf")
  end

  it "pagine une longue facture en restant conforme" do
    setup = InvoicingSpec.setup
    lines = (1..70).map do |index|
      Api::LineInput.new(kind: "free", description: "Prestation n° #{index} — description assez longue pour " \
                                                    "passer sur deux lignes dans la colonne des désignations",
        quantity: d("1"), unit_price: d("10.01"), vat_rate_id: InvoicingSpec.standard_rate(setup).id)
    end
    bytes = pdf(InvoicingSpec.issued(setup, lines: lines).id)
    PDF::Reader.new(bytes).page_count.should be > 2
    pdfa3_failures(bytes).should eq([] of String)
  end

  it "applique un modèle de mise en page (logo, couleurs, textes) sans toucher aux mentions" do
    setup = InvoicingSpec.setup
    plain = InvoicingSpec.issued(setup)
    logo = Partiduo::Api::Core.store_attachment(Partiduo::Api::Actor.system,
      Partiduo::Api::Core::AttachmentInput.new("logo.png", "image/png", IO::Memory.new(png_logo))).value!
    layout = Api.create_layout(InvoicingSpec.actor, Api::LayoutInput.new(name: "Maison", logo_attachment_id: logo.id,
      primary_color: "#8a2be2", header_text: "Artisan depuis 1998", footer_text: "Merci de votre confiance",
      is_default: true)).value!
    Api.create_layout(InvoicingSpec.actor, Api::LayoutInput.new(name: "Maison", primary_color: "rouge"))
      .error_keys.sort!.should eq(["invoicing.errors.layout.color", "invoicing.errors.layout.name.taken"])
    styled = InvoicingSpec.issued(setup)
    bytes = pdf(styled.id)
    pdfa3_failures(bytes).should eq([] of String)
    InvoicingSpec.codes(styled).should eq(InvoicingSpec.codes(plain))
    bytes.size.should_not eq(pdf(plain.id).size)
    Api.delete_layout(InvoicingSpec.actor, layout.id).success?.should be_true
  end
end
