# SPDX-License-Identifier: AGPL-3.0-or-later

require "xml"

module Partiduo
  module Invoicing
    # XML CII (UN/CEFACT Cross Industry Invoice D16B) au profil EN 16931 de
    # Factur-X 1.0 (ADR-004, ADR-006 D5), embarqué dans le PDF/A-3. Type
    # 380 (facture), 381 (avoir, avec la facture d'origine en BT-25), 386
    # (facture d'acompte). L'application d'origine (`facturx.class.php`) émettait toujours
    # 380.
    #
    # Les éléments suivent l'ordre du schéma XSD ; les montants sont écrits
    # avec deux décimales (quatre pour les prix unitaires et quantités).
    module FacturxXml
      alias Api = Partiduo::Api::Invoicing

      GUIDELINE = "urn:cen.eu:en16931:2017"
      NS_RSM    = "urn:un:unece:uncefact:data:standard:CrossIndustryInvoice:100"
      NS_RAM    = "urn:un:unece:uncefact:data:standard:ReusableAggregateBusinessInformationEntity:100"
      NS_QDT    = "urn:un:unece:uncefact:data:standard:QualifiedDataType:100"
      NS_UDT    = "urn:un:unece:uncefact:data:standard:UnqualifiedDataType:100"

      # Codes UNTDID 4461 des moyens de paiement.
      PAYMENT_MEANS = {"transfer" => "58", "card" => "48", "cheque" => "20", "cash" => "10",
                       "direct_debit" => "59", "other" => "1"}

      def self.amount(value : BigDecimal) : String
        format_decimal(Calculator.round(value), 2)
      end

      def self.format_decimal(value : BigDecimal, digits : Int32) : String
        rounded = value.round(digits, mode: :ties_away)
        negative = rounded < 0
        text = Calculator.plain(rounded.abs)
        integer, _, fraction = text.partition('.')
        fraction = fraction.ljust(digits, '0')[0, digits]
        "#{negative ? "-" : ""}#{integer}.#{fraction}"
      end

      def self.date(value : Time) : String
        value.to_s("%Y%m%d")
      end

      # Identifiant légal : SIREN (schéma ICD 0002) en France, numéro
      # d'entreprise BCE (0208) en Belgique.
      def self.legal_id(party : Api::PartyView) : {String, String}?
        if party.siren.size == 9
          {party.siren, "0002"}
        elsif party.country_code == "BE" && (digits = party.vat_number.gsub(/[^0-9]/, "")).size == 10
          {digits, "0208"}
        end
      end

      # Cadre de facturation français (BT-23, règle BR-FR-08) d'après la
      # catégorie d'opération : dépôt d'une facture de biens (`B1`), de
      # services (`S1`) ou mixte (`M1`). Vendeur hors de France : aucun.
      CADRES = {"goods" => "B1", "services" => "S1", "mixed" => "M1"}

      def self.business_process(view : Api::DocumentView) : String?
        return unless view.seller.country_code == "FR"
        CADRES[view.operation_category]?
      end

      # Adresse électronique du vendeur (BT-34, obligatoire, règle
      # BR-FR-13) : son SIREN dans l'annuaire (schéma 0225), à défaut son
      # courriel (schéma EM).
      def self.seller_address(party : Api::PartyView) : {String, String}?
        if party.siren.size == 9
          {party.siren, "0225"}
        elsif !party.email.empty?
          {party.email, "EM"}
        end
      end

      def self.build(view : Api::DocumentView, credited : Api::DocumentView? = nil,
                     settings : Api::SettingsView = Configuration.settings) : String
        type_code = view.type_code || raise ArgumentError.new("document non fiscal : #{view.kind}")
        currency = view.currency_code
        XML.build(encoding: "UTF-8", indent: "  ") do |xml|
          xml.element("rsm:CrossIndustryInvoice", {"xmlns:rsm" => NS_RSM, "xmlns:qdt" => NS_QDT,
                                                   "xmlns:ram" => NS_RAM, "xmlns:udt" => NS_UDT}) do
            xml.element("rsm:ExchangedDocumentContext") do
              if code = business_process(view)
                xml.element("ram:BusinessProcessSpecifiedDocumentContextParameter") do
                  xml.element("ram:ID") { xml.text code }
                end
              end
              xml.element("ram:GuidelineSpecifiedDocumentContextParameter") do
                xml.element("ram:ID") { xml.text GUIDELINE }
              end
            end
            xml.element("rsm:ExchangedDocument") do
              xml.element("ram:ID") { xml.text view.number.to_s }
              xml.element("ram:TypeCode") { xml.text type_code }
              xml.element("ram:IssueDateTime") do
                xml.element("udt:DateTimeString", {"format" => "102"}) { xml.text date(view.issue_date || raise ArgumentError.new("document sans date d'émission")) }
              end
              notes(xml, view)
            end
            xml.element("rsm:SupplyChainTradeTransaction") do
              view.lines.select(&.priced?).each_with_index do |line, index|
                line_item(xml, line, index + 1, view)
              end
              agreement(xml, view)
              delivery(xml, view)
              settlement(xml, view, credited, settings, currency)
            end
          end
        end
      end

      # Notes (BG-1) : mentions obligatoires, sujet UNTDID 4451 (`PMD`
      # pénalités, `PMT` indemnité, `AAB` escompte, `REG` mentions légales,
      # `TXD` mentions fiscales).
      private def self.notes(xml : XML::Builder, view : Api::DocumentView) : Nil
        I18n.with_locale(view.locale) do
          view.mentions.each do |mention|
            subject = note_subject(mention.code)
            next unless subject
            xml.element("ram:IncludedNote") do
              xml.element("ram:Content") { xml.text Output.mention_text(mention, view) }
              xml.element("ram:SubjectCode") { xml.text subject }
            end
          end
          unless view.notes.empty?
            xml.element("ram:IncludedNote") { xml.element("ram:Content") { xml.text view.notes } }
          end
        end
      end

      private def self.note_subject(code : String) : String?
        return "PMD" if code.starts_with?("payment.late_penalties")
        return "PMT" if code == "payment.indemnity"
        return "AAB" if code.in?("payment.early_discount", "payment.no_early_discount")
        return "TXD" if code.starts_with?("special.") || code == "vat_on_debits"
        "REG" if code.starts_with?("seller.") || code.starts_with?("operation_category")
      end

      private def self.line_item(xml : XML::Builder, line : Api::LineView, index : Int32, view : Api::DocumentView) : Nil
        xml.element("ram:IncludedSupplyChainTradeLineItem") do
          xml.element("ram:AssociatedDocumentLineDocument") do
            xml.element("ram:LineID") { xml.text index.to_s }
          end
          xml.element("ram:SpecifiedTradeProduct") do
            if card_id = line.item_card_id
              code = Configuration.card(card_id).try(&.code)
              xml.element("ram:SellerAssignedID") { xml.text code } if code
            end
            xml.element("ram:Name") { xml.text line.description.lines.first? || line.description }
            if line.description.includes?('\n')
              xml.element("ram:Description") { xml.text line.description }
            end
          end
          xml.element("ram:SpecifiedLineTradeAgreement") do
            xml.element("ram:NetPriceProductTradePrice") do
              xml.element("ram:ChargeAmount") { xml.text format_decimal(line.unit_price, 4) }
            end
          end
          xml.element("ram:SpecifiedLineTradeDelivery") do
            xml.element("ram:BilledQuantity", {"unitCode" => line.unit_code}) { xml.text format_decimal(line.quantity, 4) }
          end
          xml.element("ram:SpecifiedLineTradeSettlement") do
            xml.element("ram:ApplicableTradeTax") do
              xml.element("ram:TypeCode") { xml.text "VAT" }
              xml.element("ram:CategoryCode") { xml.text line.vat_category }
              xml.element("ram:RateApplicablePercent") { xml.text format_decimal(line.vat_percent, 2) }
            end
            unless line.discount_amount.zero?
              xml.element("ram:SpecifiedTradeAllowanceCharge") do
                xml.element("ram:ChargeIndicator") { xml.element("udt:Indicator") { xml.text "false" } }
                if line.discount_kind == "percent"
                  xml.element("ram:CalculationPercent") { xml.text format_decimal(line.discount_value, 2) }
                  xml.element("ram:BasisAmount") { xml.text amount(line.gross_amount) }
                end
                xml.element("ram:ActualAmount") { xml.text amount(line.discount_amount) }
                xml.element("ram:ReasonCode") { xml.text "95" }
                xml.element("ram:Reason") { xml.text I18n.with_locale(view.locale) { I18n.t("invoicing.pdf.discount") } }
              end
            end
            xml.element("ram:SpecifiedTradeSettlementLineMonetarySummation") do
              xml.element("ram:LineTotalAmount") { xml.text amount(line.net_amount) }
            end
          end
        end
      end

      private def self.party(xml : XML::Builder, name : String, party : Api::PartyView, seller : Bool) : Nil
        xml.element(name) do
          xml.element("ram:Name") { xml.text party.name }
          if id = legal_id(party)
            xml.element("ram:SpecifiedLegalOrganization") do
              xml.element("ram:ID", {"schemeID" => id[1]}) { xml.text id[0] }
            end
          end
          xml.element("ram:PostalTradeAddress") do
            xml.element("ram:PostcodeCode") { xml.text party.postcode } unless party.postcode.empty?
            xml.element("ram:LineOne") { xml.text party.line1 } unless party.line1.empty?
            xml.element("ram:LineTwo") { xml.text party.line2 } unless party.line2.empty?
            xml.element("ram:CityName") { xml.text party.city } unless party.city.empty?
            xml.element("ram:CountryID") { xml.text party.country_code }
          end
          if seller
            if address = seller_address(party)
              xml.element("ram:URIUniversalCommunication") do
                xml.element("ram:URIID", {"schemeID" => address[1]}) { xml.text address[0] }
              end
            end
          elsif !seller && (siren = party.siren.presence)
            # Adresse électronique de l'annuaire (schéma 0225, ADR-004).
            address = [siren, party.siret.presence, party.routing_id.presence].compact.join('_')
            xml.element("ram:URIUniversalCommunication") do
              xml.element("ram:URIID", {"schemeID" => "0225"}) { xml.text address }
            end
          end
          unless party.vat_number.empty?
            xml.element("ram:SpecifiedTaxRegistration") do
              xml.element("ram:ID", {"schemeID" => "VA"}) { xml.text party.vat_number }
            end
          end
        end
      end

      private def self.agreement(xml : XML::Builder, view : Api::DocumentView) : Nil
        xml.element("ram:ApplicableHeaderTradeAgreement") do
          xml.element("ram:BuyerReference") { xml.text view.buyer_reference } unless view.buyer_reference.empty?
          party(xml, "ram:SellerTradeParty", view.seller, true)
          party(xml, "ram:BuyerTradeParty", view.customer, false)
          unless view.order_reference.empty?
            xml.element("ram:BuyerOrderReferencedDocument") do
              xml.element("ram:IssuerAssignedID") { xml.text view.order_reference }
            end
          end
        end
      end

      private def self.delivery(xml : XML::Builder, view : Api::DocumentView) : Nil
        xml.element("ram:ApplicableHeaderTradeDelivery") do
          if address = view.delivery_address
            xml.element("ram:ShipToTradeParty") do
              xml.element("ram:Name") { xml.text view.customer.name }
              xml.element("ram:PostalTradeAddress") do
                xml.element("ram:PostcodeCode") { xml.text address.postcode } unless address.postcode.empty?
                xml.element("ram:LineOne") { xml.text address.line1 } unless address.line1.empty?
                xml.element("ram:LineTwo") { xml.text address.line2 } unless address.line2.empty?
                xml.element("ram:CityName") { xml.text address.city } unless address.city.empty?
                xml.element("ram:CountryID") { xml.text address.country_code }
              end
            end
          end
          if delivered = view.delivery_date
            xml.element("ram:ActualDeliverySupplyChainEvent") do
              xml.element("ram:OccurrenceDateTime") do
                xml.element("udt:DateTimeString", {"format" => "102"}) { xml.text date(delivered) }
              end
            end
          end
        end
      end

      private def self.settlement(xml : XML::Builder, view : Api::DocumentView, credited : Api::DocumentView?,
                                  settings : Api::SettingsView, currency : String) : Nil
        xml.element("ram:ApplicableHeaderTradeSettlement") do
          unless view.structured_reference.empty?
            xml.element("ram:PaymentReference") { xml.text view.structured_reference }
          end
          xml.element("ram:InvoiceCurrencyCode") { xml.text currency }
          unless settings.iban.empty?
            xml.element("ram:SpecifiedTradeSettlementPaymentMeans") do
              xml.element("ram:TypeCode") { xml.text PAYMENT_MEANS["transfer"] }
              xml.element("ram:PayeePartyCreditorFinancialAccount") do
                xml.element("ram:IBANID") { xml.text settings.iban }
              end
              unless settings.bic.empty?
                xml.element("ram:PayeeSpecifiedCreditorFinancialInstitution") do
                  xml.element("ram:BICID") { xml.text settings.bic }
                end
              end
            end
          end
          tax_breakdown(xml, view)
          document_allowances(xml, view)
          xml.element("ram:SpecifiedTradePaymentTerms") do
            terms = view.mentions.select { |mention| mention.code.starts_with?("payment.") && mention.code != "payment.bank" }
            text = I18n.with_locale(view.locale) { terms.map { |mention| Output.mention_text(mention, view) }.join(". ") }
            xml.element("ram:Description") { xml.text text } unless text.empty?
            if due = view.due_date
              xml.element("ram:DueDateDateTime") do
                xml.element("udt:DateTimeString", {"format" => "102"}) { xml.text date(due) }
              end
            end
          end
          summation(xml, view.totals, currency)
          if credited
            xml.element("ram:InvoiceReferencedDocument") do
              xml.element("ram:IssuerAssignedID") { xml.text credited.number.to_s }
              if issued = credited.issue_date
                xml.element("ram:FormattedIssueDateTime") do
                  xml.element("qdt:DateTimeString", {"format" => "102"}) { xml.text date(issued) }
                end
              end
            end
          end
        end
      end

      private def self.tax_breakdown(xml : XML::Builder, view : Api::DocumentView) : Nil
        view.vat_breakdown.each do |group|
          xml.element("ram:ApplicableTradeTax") do
            xml.element("ram:CalculatedAmount") { xml.text amount(group.vat) }
            xml.element("ram:TypeCode") { xml.text "VAT" }
            reason = group.exemption_reason.presence || exemption_text(group, view)
            xml.element("ram:ExemptionReason") { xml.text reason } if reason
            xml.element("ram:BasisAmount") { xml.text amount(group.base) }
            xml.element("ram:CategoryCode") { xml.text group.category }
            unless group.exemption_code.empty?
              xml.element("ram:ExemptionReasonCode") { xml.text group.exemption_code }
            end
            if code = due_date_type_code(view, group)
              xml.element("ram:DueDateTypeCode") { xml.text code }
            end
            xml.element("ram:RateApplicablePercent") { xml.text format_decimal(group.percent, 2) }
          end
        end
      end

      private def self.document_allowances(xml : XML::Builder, view : Api::DocumentView) : Nil
        view.vat_breakdown.each do |group|
          next if group.allowance.zero?
          xml.element("ram:SpecifiedTradeAllowanceCharge") do
            xml.element("ram:ChargeIndicator") { xml.element("udt:Indicator") { xml.text "false" } }
            xml.element("ram:ActualAmount") { xml.text amount(group.allowance) }
            xml.element("ram:ReasonCode") { xml.text "95" }
            xml.element("ram:Reason") { xml.text I18n.with_locale(view.locale) { I18n.t("invoicing.pdf.global_discount") } }
            xml.element("ram:CategoryTradeTax") do
              xml.element("ram:TypeCode") { xml.text "VAT" }
              xml.element("ram:CategoryCode") { xml.text group.category }
              xml.element("ram:RateApplicablePercent") { xml.text format_decimal(group.percent, 2) }
            end
          end
        end
      end

      private def self.summation(xml : XML::Builder, totals : Api::TotalsView, currency : String) : Nil
        xml.element("ram:SpecifiedTradeSettlementHeaderMonetarySummation") do
          xml.element("ram:LineTotalAmount") { xml.text amount(totals.lines_total) }
          xml.element("ram:ChargeTotalAmount") { xml.text amount(BigDecimal.new(0)) }
          xml.element("ram:AllowanceTotalAmount") { xml.text amount(totals.discount_total) }
          xml.element("ram:TaxBasisTotalAmount") { xml.text amount(totals.total_net) }
          xml.element("ram:TaxTotalAmount", {"currencyID" => currency}) { xml.text amount(totals.total_vat) }
          xml.element("ram:GrandTotalAmount") { xml.text amount(totals.total_gross) }
          xml.element("ram:TotalPrepaidAmount") { xml.text amount(totals.prepaid) }
          xml.element("ram:DuePayableAmount") { xml.text amount(totals.payable) }
        end
      end

      # Motif d'exonération exigé pour E, AE, K, G, O quand le taux n'en
      # porte pas : le texte de la mention particulière.
      private def self.exemption_text(group : Api::VatBreakdownView, view : Api::DocumentView) : String?
        return unless group.category.in?("E", "AE", "K", "G", "O")
        mention = view.mentions.find(&.code.starts_with?("special."))
        mention.try { |item| I18n.with_locale(view.locale) { Output.mention_text(item, view) } }
      end

      # Exigibilité de la TVA (BT-8, codes UNTDID 2475) : 5 (date de la
      # facture) avec l'option pour les débits, 72 (date du paiement) pour
      # des services sans cette option.
      private def self.due_date_type_code(view : Api::DocumentView, group : Api::VatBreakdownView) : String?
        return unless group.category == "S" && view.seller.country_code == "FR"
        if view.vat_on_debits
          "5"
        elsif view.operation_category == "services"
          "72"
        end
      end
    end
  end
end
