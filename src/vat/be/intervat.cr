# SPDX-License-Identifier: AGPL-3.0-or-later

require "xml"

module Partiduo
  module Vat
    module Be
      # Fichiers XML à déposer sur Intervat (SPF Finances), repris des classes
      # `Declaration_XML`, `Declaration_Period`, `Client` et
      # `Client_Intracom` de l'extension TVA d'origine : déclaration
      # périodique (`VATConsignment`), listing annuel des clients assujettis
      # (`ClientListingConsignment`), relevé intracommunautaire
      # (`IntraConsignment`). Encodage UTF-8 pour les trois (l'application d'origine écrivait
      # le listing en ISO 8859-1, D-TVA-008).
      module Intervat
        COMMON_NS  = "http://www.minfin.fgov.be/InputCommon"
        VAT_NS     = "http://www.minfin.fgov.be/VATConsignment"
        LISTING_NS = "http://www.minfin.fgov.be/ClientListingConsignment"
        INTRA_NS   = "http://www.minfin.fgov.be/IntraConsignment"

        # Déclarant (`Declarant`) : la société du socle.
        record Party,
          vat_number : String,
          name : String,
          street : String,
          postcode : String,
          city : String,
          country_code : String,
          email : String,
          phone : String

        # Mandataire (`Representative`), facultatif.
        record Representative,
          identifier : String,
          identification_type : String,
          issued_by : String,
          name : String,
          street : String,
          postcode : String,
          city : String,
          country_code : String,
          email : String,
          phone : String

        # Client du listing (`Client`) ou du relevé (`IntraClient`) : numéro
        # de TVA complet (`BE0417497106`, `FR44732829320`), code du relevé,
        # montant et TVA.
        record Client, vat_number : String, amount : BigDecimal, vat : BigDecimal = BigDecimal.new(0), code : String = ""

        # Numéro sans le préfixe de pays (`issuedBy` porte le pays).
        def self.national_number(vat_number : String) : String
          normalized = vat_number.upcase.gsub(/[^A-Z0-9]/, "")
          normalized.starts_with?(/[A-Z]{2}/) ? normalized[2..] : normalized
        end

        def self.country(vat_number : String) : String
          normalized = vat_number.upcase.gsub(/[^A-Z0-9]/, "")
          normalized[0, 2]
        end

        def self.amount(value : BigDecimal) : String
          text = value.round(2, mode: :ties_away).to_s
          integer, _, fraction = text.partition('.')
          "#{integer}.#{fraction.ljust(2, '0')[0, 2]}"
        end

        # Déclaration périodique : grilles non nulles (sauf `xx`, `yy`),
        # `ClientListingNihil`, `Ask Restitution`.
        def self.periodic(declarant : Party, representative : Representative?, periodicity : String, number : Int32,
                          year : Int32, amounts : Array({String, BigDecimal}), client_listing_nihil : Bool,
                          ask_restitution : Bool) : String
          XML.build(encoding: "UTF-8", indent: "  ") do |xml|
            xml.element("ns2", "VATConsignment", VAT_NS, {"xmlns" => COMMON_NS, "VATDeclarationsNbr" => "1"}) do
              representative.try { |value| representative(xml, value) }
              xml.element("ns2", "VATDeclaration", nil, {"SequenceNumber" => "1"}) do
                declarant(xml, declarant)
                period(xml, periodicity, number, year)
                xml.element("ns2", "Data", nil) do
                  amounts.each do |(code, value)|
                    grid = Periodic.grid_number(code)
                    next if grid.nil? || value.zero?
                    xml.element("ns2", "Amount", nil, {"GridNumber" => grid}) { xml.text amount(value) }
                  end
                end
                xml.element("ns2", "ClientListingNihil", nil) { xml.text(client_listing_nihil ? "YES" : "NO") }
                xml.element("ns2", "Ask", nil, {"Restitution" => ask_restitution ? "YES" : "NO"})
              end
            end
          end
        end

        # Listing annuel des clients assujettis belges.
        def self.client_listing(declarant : Party, representative : Representative?, year : Int32,
                                clients : Array(Client)) : String
          XML.build(encoding: "UTF-8", indent: "  ") do |xml|
            xml.element("ns2", "ClientListingConsignment", LISTING_NS, {"xmlns" => COMMON_NS, "ClientListingsNbr" => "1"}) do
              representative.try { |value| representative(xml, value) }
              attributes = {
                "VATAmountSum"   => amount(clients.sum(BigDecimal.new(0), &.vat)),
                "TurnOverSum"    => amount(clients.sum(BigDecimal.new(0), &.amount)),
                "ClientsNbr"     => clients.size.to_s,
                "SequenceNumber" => "1",
              }
              xml.element("ns2", "ClientListing", nil, attributes) do
                declarant(xml, declarant)
                xml.element("ns2", "Period", nil) { xml.text year.to_s }
                clients.each_with_index(1) do |client, index|
                  xml.element("ns2", "Client", nil, {"SequenceNumber" => index.to_s}) do
                    xml.element("ns2", "CompanyVATNumber", nil, {"issuedBy" => "BE"}) { xml.text national_number(client.vat_number) }
                    xml.element("ns2", "TurnOver", nil) { xml.text amount(client.amount) }
                    xml.element("ns2", "VATAmount", nil) { xml.text amount(client.vat) }
                  end
                end
              end
            end
          end
        end

        # Relevé intracommunautaire (mensuel ou trimestriel).
        def self.intra_listing(declarant : Party, representative : Representative?, periodicity : String, number : Int32,
                               year : Int32, clients : Array(Client)) : String
          XML.build(encoding: "UTF-8", indent: "  ") do |xml|
            xml.element("ns2", "IntraConsignment", INTRA_NS, {"xmlns" => COMMON_NS, "IntraListingsNbr" => "1"}) do
              representative.try { |value| representative(xml, value) }
              attributes = {
                "AmountSum"      => amount(clients.sum(BigDecimal.new(0), &.amount)),
                "ClientsNbr"     => clients.size.to_s,
                "SequenceNumber" => "1",
              }
              xml.element("ns2", "IntraListing", nil, attributes) do
                declarant(xml, declarant)
                period(xml, periodicity, number, year)
                clients.each_with_index(1) do |client, index|
                  xml.element("ns2", "IntraClient", nil, {"SequenceNumber" => index.to_s}) do
                    xml.element("ns2", "CompanyVATNumber", nil, {"issuedBy" => country(client.vat_number)}) do
                      xml.text national_number(client.vat_number)
                    end
                    xml.element("ns2", "Code", nil) { xml.text client.code }
                    xml.element("ns2", "Amount", nil) { xml.text amount(client.amount) }
                  end
                end
              end
            end
          end
        end

        private def self.declarant(xml : XML::Builder, party : Party) : Nil
          xml.element("ns2", "Declarant", nil) do
            xml.element("VATNumber") { xml.text national_number(party.vat_number) }
            xml.element("Name") { xml.text party.name }
            xml.element("Street") { xml.text party.street }
            xml.element("PostCode") { xml.text party.postcode }
            xml.element("City") { xml.text party.city }
            xml.element("CountryCode") { xml.text party.country_code }
            xml.element("EmailAddress") { xml.text party.email }
            xml.element("Phone") { xml.text party.phone }
          end
        end

        private def self.representative(xml : XML::Builder, party : Representative) : Nil
          xml.element("ns2", "Representative", nil) do
            xml.element("RepresentativeID", {"identificationType" => party.identification_type, "issuedBy" => party.issued_by}) do
              xml.text party.identifier
            end
            xml.element("Name") { xml.text party.name }
            xml.element("Street") { xml.text party.street }
            xml.element("PostCode") { xml.text party.postcode }
            xml.element("City") { xml.text party.city }
            xml.element("CountryCode") { xml.text party.country_code }
            xml.element("EmailAddress") { xml.text party.email }
            xml.element("Phone") { xml.text party.phone }
          end
        end

        # `Period` : `Month` ou `Quarter`, puis `Year` (`build_periode`).
        private def self.period(xml : XML::Builder, periodicity : String, number : Int32, year : Int32) : Nil
          xml.element("ns2", "Period", nil) do
            case periodicity
            when "month"   then xml.element("ns2", "Month", nil) { xml.text number.to_s }
            when "quarter" then xml.element("ns2", "Quarter", nil) { xml.text number.to_s }
            end
            xml.element("ns2", "Year", nil) { xml.text year.to_s }
          end
        end
      end
    end
  end
end
