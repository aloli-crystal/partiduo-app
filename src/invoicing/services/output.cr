# SPDX-License-Identifier: AGPL-3.0-or-later

require "pdf-a"
require "pdf-validate"

module Partiduo
  module Invoicing
    # Document produit (ADR-006 D5) : PDF/A-3 (ISO 19005-3, niveau B) par
    # `prod-crystal/pdf-a`, avec, pour les documents fiscaux, le XML CII
    # Factur-X embarqué (`/AF`, relation `Data`) et l'identification Factur-X
    # dans les métadonnées XMP (schéma d'extension déclaré, § 6.6.2.3). Le
    # fichier est contrôlé par `prod-crystal/pdf-validate` (profil
    # `pdf-a-3b`) avant d'être conservé : un PDF non conforme n'est jamais
    # enregistré.
    #
    # Polices : DejaVu Sans (licence libre, `data/fonts/`), embarquées dans
    # l'exécutable et incorporées en sous-ensemble dans chaque PDF.
    module Output
      alias Api = Partiduo::Api::Invoicing

      FONT_REGULAR = {{ read_file("#{__DIR__}/../../../data/fonts/DejaVuSans.ttf") }}
      FONT_BOLD    = {{ read_file("#{__DIR__}/../../../data/fonts/DejaVuSans-Bold.ttf") }}

      XML_NAME = "factur-x.xml"

      # Règles de `pdf-validate` 0.47.0 écartées : `pdfa3-6.6.4-pdfaid-part-2`
      # exige `pdfaid:part = 2` dans le profil PDF/A-3 (défaut du jeu de
      # règles, BLOCAGES B-INV-001) ; la partie 3 est vérifiée à part.
      IGNORED_RULES = %w[pdfa3-6.6.4-pdfaid-part-2]

      record Rendered, pdf : Bytes, xml : String?

      class ConformanceError < Exception
      end

      def self.filename(view : Api::DocumentView) : String
        "#{view.number || "draft-#{view.id}"}.pdf"
      end

      # `copy` : copie PDF d'une facture transmise par la plateforme agréée
      # (ADR-004 D9, `PdfCopy`) — bandeau « Copie » sur chaque page et pas de
      # XML Factur-X, pour qu'elle ne passe pas pour un second original.
      def self.render(view : Api::DocumentView, layout : Api::LayoutView?, copy : Bool = false) : Rendered
        xml = nil
        if view.fiscal? && !view.draft? && !copy
          credited = view.credited.try { |link| Documents.view(Documents.find(link.id)) }
          xml = FacturxXml.build(view, credited)
        end
        document = FacturxDocument.new
        I18n.with_locale(view.locale) do
          document.title = "#{I18n.t(view.kind_key)} #{view.number || I18n.t("invoicing.pdf.draft")}"
          document.author = view.seller.name
          document.subject = I18n.t(view.kind_key)
          document.creator = "Partiduo #{Partiduo::VERSION}"
          document.producer = "Partiduo #{Partiduo::VERSION}"
          document.lang = view.locale
          Renderer.new(document, view, layout, copy).draw
        end
        if xml
          document.attach_file(bytes: xml.to_slice, name: XML_NAME, description: "Factur-X", relationship: :data,
            mime_type: "text/xml")
          # Factur-X 1.0 : `INVOICE` pour tout document de facturation (380, 381, 386).
          document.facturx_type = "INVOICE"
        end
        bytes = document.to_slice
        failures = check(bytes)
        raise ConformanceError.new("PDF/A-3 non conforme : #{failures.join(", ")}") unless failures.empty?
        Rendered.new(bytes, xml)
      end

      # Règles PDF/A-3b en échec (hors règles écartées) ; vide si conforme.
      def self.check(bytes : Bytes) : Array(String)
        report = PDF::Validate.bytes(bytes, profile: "pdf-a-3b")
        report.fatal_failures.map(&.rule.id).reject { |id| IGNORED_RULES.includes?(id) }
      end

      # --- Formats ---------------------------------------------------------------

      def self.format_amount(value : BigDecimal, locale : String, currency : String? = nil) : String
        text = FacturxXml.format_decimal(value, 2)
        negative = text.starts_with?('-')
        integer, _, fraction = text.lchop('-').partition('.')
        thousands, decimal = case locale
                             when "en" then {",", "."}
                             when "nl" then {".", ","}
                             else           {" ", ","}
                             end
        grouped = integer.reverse.scan(/\d{1,3}/).map(&.[0]).join(thousands).reverse
        number = "#{negative ? "-" : ""}#{grouped}#{decimal}#{fraction}"
        return number unless currency
        symbol = currency == "EUR" ? "€" : currency
        locale == "en" ? "#{symbol}#{number}" : "#{number} #{symbol}"
      end

      def self.format_quantity(value : BigDecimal, locale : String) : String
        text = Calculator.plain(value)
        text = text.rchop(".0") if text.ends_with?(".0")
        locale == "en" ? text : text.tr(".", ",")
      end

      def self.format_percent(value : BigDecimal, locale : String) : String
        "#{format_quantity(value, locale)} %"
      end

      def self.format_date(value : Time?, locale : String) : String
        return "" unless value
        case locale
        when "en" then value.to_s("%Y-%m-%d")
        when "nl" then value.to_s("%d-%m-%Y")
        else           value.to_s("%d/%m/%Y")
        end
      end

      # Texte d'une mention dans la langue courante, dates et montants
      # présentés selon la langue du document.
      def self.mention_text(mention : Api::MentionView, view : Api::DocumentView) : String
        params = mention.params.to_h do |key, value|
          formatted = if key == "date" && value.matches?(/\A\d{4}-\d{2}-\d{2}\z/)
                        format_date(Time.parse_utc(value, "%Y-%m-%d"), view.locale)
                      elsif key.in?("amount", "capital")
                        format_amount(BigDecimal.new(value), view.locale)
                      elsif key == "rate"
                        format_quantity(BigDecimal.new(value), view.locale)
                      elsif key == "currency"
                        value == "EUR" ? "€" : value
                      else
                        value
                      end
          {key, formatted}
        end
        I18n.t(mention.key, params)
      end
    end

    # `PDF::A::Document` au profil PDF/A-3b qui ajoute aux métadonnées XMP
    # l'identification Factur-X (`fx:`) et la déclaration de son schéma
    # d'extension (`pdfaExtension`), exigées par Factur-X 1.0 et par
    # ISO 19005-3 § 6.6.2.3. La bibliothèque `pdf` n'offre pas d'entrée pour
    # des propriétés XMP propres : le flux XMP qu'elle produit est complété
    # au moment où le catalogue est construit.
    class FacturxDocument < PDF::A::Document
      FX_NAMESPACE = "urn:factur-x:pdfa:CrossIndustryDocument:invoice:1p0#"

      property facturx_type : String? = nil

      def initialize
        super(PDF::A::Profile::A_3B)
      end

      def catalog : PDF::Objects::Indirect
        fresh = @catalog.nil?
        catalog = super
        if fresh && (type = facturx_type)
          reference = catalog.value.as(PDF::Objects::Dictionary)["Metadata"].as(PDF::Objects::Reference)
          indirect = @objects.find! { |object| object.object_number == reference.object_number }
          stream = indirect.value.as(PDF::Objects::Stream)
          stream.data = String.new(stream.data).sub("</rdf:RDF>", facturx_xmp(type) + "</rdf:RDF>")
        end
        catalog
      end

      private def facturx_xmp(type : String) : String
        String.build do |io|
          io << %(<rdf:Description rdf:about="" xmlns:fx=") << FX_NAMESPACE << %(">\n)
          io << "<fx:DocumentType>" << type << "</fx:DocumentType>\n"
          io << "<fx:DocumentFileName>" << Output::XML_NAME << "</fx:DocumentFileName>\n"
          io << "<fx:Version>1.0</fx:Version>\n"
          io << "<fx:ConformanceLevel>EN 16931</fx:ConformanceLevel>\n"
          io << "</rdf:Description>\n"
          io << %(<rdf:Description rdf:about="" xmlns:pdfaExtension="http://www.aiim.org/pdfa/ns/extension/")
          io << %( xmlns:pdfaSchema="http://www.aiim.org/pdfa/ns/schema#")
          io << %( xmlns:pdfaProperty="http://www.aiim.org/pdfa/ns/property#">\n)
          io << "<pdfaExtension:schemas><rdf:Bag><rdf:li rdf:parseType=\"Resource\">\n"
          io << "<pdfaSchema:schema>Factur-X PDFA Extension Schema</pdfaSchema:schema>\n"
          io << "<pdfaSchema:namespaceURI>" << FX_NAMESPACE << "</pdfaSchema:namespaceURI>\n"
          io << "<pdfaSchema:prefix>fx</pdfaSchema:prefix>\n"
          io << "<pdfaSchema:property><rdf:Seq>\n"
          {
            "DocumentFileName" => "Name of the embedded XML invoice file",
            "DocumentType"     => "INVOICE",
            "Version"          => "The actual version of the Factur-X XML schema",
            "ConformanceLevel" => "The conformance level of the embedded Factur-X data",
          }.each do |name, description|
            io << %(<rdf:li rdf:parseType="Resource"><pdfaProperty:name>) << name << "</pdfaProperty:name>"
            io << "<pdfaProperty:valueType>Text</pdfaProperty:valueType>"
            io << "<pdfaProperty:category>external</pdfaProperty:category>"
            io << "<pdfaProperty:description>" << description << "</pdfaProperty:description></rdf:li>\n"
          end
          io << "</rdf:Seq></pdfaSchema:property>\n"
          io << "</rdf:li></rdf:Bag></pdfaExtension:schemas>\n"
          io << "</rdf:Description>\n"
        end
      end
    end
  end
end
