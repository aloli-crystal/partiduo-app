# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Invoicing
    # Mentions obligatoires (ADR-006 D5), *générées* à partir du document,
    # de la société, du client et des paramètres — jamais laissées au modèle
    # de mise en page, qui ne peut ni les retirer ni les modifier.
    #
    # Chaque mention a un code stable (`payment.indemnity`), une clé i18n et
    # des paramètres : dates en ISO (`AAAA-MM-JJ`), montants et taux en
    # décimal canonique (`40.00`, `12.5`), formatés par qui les affiche.
    #
    # Sources : art. 242 nonies A de l'annexe II du CGI et L441-9 du Code de
    # commerce (France : identités, SIREN du client, catégorie d'opération,
    # option pour les débits, adresse de livraison, escompte, pénalités,
    # indemnité forfaitaire de 40 €) ; art. 5 de l'arrêté royal n° 1 et loi
    # du 2 août 2002 (Belgique : numéro d'entreprise, communication
    # structurée, intérêts et indemnité).
    module Mentions
      alias Api = Partiduo::Api::Invoicing
      alias Mention = Api::MentionView

      INDEMNITY = BigDecimal.new("40.00")

      # Mentions particulières selon le motif d'exonération (VATEX) ou la
      # catégorie UNCL5305 du groupe de TVA.
      SPECIAL_BY_EXEMPTION = {
        "VATEX-FR-FRANCHISE" => "franchise",
        "VATEX-EU-AE"        => "reverse_charge",
        "VATEX-EU-IC"        => "intra_community",
        "VATEX-EU-G"         => "export",
      }
      SPECIAL_BY_CATEGORY = {"AE" => "reverse_charge", "K" => "intra_community", "G" => "export", "E" => "exempt",
                             "O" => "not_subject", "Z" => "zero_rated"}

      record Context,
        kind : String,
        regime : String,
        seller : Api::PartyView,
        customer : Api::PartyView,
        number : String?,
        issue_date : Time?,
        delivery_date : Time?,
        due_date : Time?,
        validity_date : Time?,
        operation_category : String,
        vat_on_debits : Bool,
        delivery_address : Api::AddressView?,
        vat_breakdown : Array(Api::VatBreakdownView),
        credited_number : String?,
        credited_date : Time?,
        deductions : Array(Api::DeductionView),
        structured_reference : String,
        settings : Api::SettingsView,
        currency_code : String,
        payment_terms : String = "",
        payment_terms_days : Int32 = 30,
        billing_period_start : Time? = nil,
        billing_period_end : Time? = nil,
        delivery_note_numbers : Array(String) = [] of String,
        return_note_numbers : Array(String) = [] of String,
        return_reason : String = ""

      def self.iso(date : Time?) : String
        date.try(&.to_s("%Y-%m-%d")) || ""
      end

      def self.amount(value : BigDecimal) : String
        Calculator.round(value).to_s
      end

      def self.build(context : Context) : Array(Mention)
        mentions = [] of Mention
        add = ->(code : String, params : Hash(String, String)) do
          mentions << Mention.new(code, "invoicing.mentions.#{code}", params)
          nil
        end
        seller_mentions(context, add)
        customer_mentions(context, add)
        date_mentions(context, add)
        fiscal_mentions(context, add) if Api::FISCAL_KINDS.includes?(context.kind)
        return_mentions(context, add)
        mentions
      end

      private def self.customer_mentions(context : Context, add) : Nil
        customer = context.customer
        add.call("customer.siren", {"siren" => customer.siren}) unless customer.siren.empty?
        add.call("customer.vat_number", {"vat_number" => customer.vat_number}) unless customer.vat_number.empty?
        if (address = context.delivery_address) && differs?(address, customer)
          add.call("delivery_address", {"address" => address.lines.join(", ")})
        end
      end

      private def self.date_mentions(context : Context, add) : Nil
        add.call("dates.issue", {"date" => iso(context.issue_date)}) if context.issue_date
        if (from = context.billing_period_start) && (upto = context.billing_period_end)
          # Facture récapitulative : livraisons de la période (D-INV2-003).
          add.call("dates.delivery_period", {"from" => iso(from), "to" => iso(upto)})
        elsif context.kind.in?("invoice", "deposit_invoice", "credit_note", "delivery_note") && context.delivery_date
          add.call("dates.delivery", {"date" => iso(context.delivery_date)})
        end
        if context.kind == "quote" && context.validity_date
          add.call("quote.validity", {"date" => iso(context.validity_date)})
        end
        terms_mention(context, add) if context.kind.in?("quote", "order")
      end

      # Retours de marchandises (D-INV3-001 à D-INV3-005) : date et motif du
      # bon de retour ; bons de retour déduits d'une facture ou crédités par
      # un avoir ; livraisons imputées d'un avoir récapitulatif.
      private def self.return_mentions(context : Context, add) : Nil
        if context.kind == "return_note"
          add.call("dates.return", {"date" => iso(context.delivery_date)}) if context.delivery_date
          add.call("return_note.reason.#{context.return_reason}", {} of String => String) unless context.return_reason.empty?
        end
        unless context.return_note_numbers.empty?
          code = context.kind == "credit_note" ? "credited" : "deducted"
          add.call("return_notes.#{code}", {"numbers" => context.return_note_numbers.join(", ")})
        end
        if context.kind == "credit_note" && !context.delivery_note_numbers.empty?
          add.call("delivery_notes.offset", {"numbers" => context.delivery_note_numbers.join(", ")})
        end
      end

      private def self.fiscal_mentions(context : Context, add) : Nil
        none = {} of String => String
        category = context.operation_category
        add.call("operation_category.#{category}", none) unless category.empty?
        add.call("vat_on_debits", none) if context.vat_on_debits && context.regime == "fr"
        special_mentions(context, add)
        if context.kind == "credit_note"
          add.call("credit_note.reference", {"number" => context.credited_number.to_s,
                                             "date"   => iso(context.credited_date)})
        end
        add.call("deposit.invoice", none) if context.kind == "deposit_invoice"
        if context.kind == "invoice" && context.delivery_note_numbers.size >= 2
          # Facture récapitulative (art. 289-I-3 du CGI ; en Belgique,
          # facture périodique) : bons de livraison regroupés.
          add.call("delivery_notes.summary.#{context.regime}", {"numbers" => context.delivery_note_numbers.join(", ")})
        end

        context.deductions.each do |deduction|
          add.call("deposit.deducted", {"number" => deduction.deposit_number, "amount" => amount(deduction.amount),
                                        "currency" => context.currency_code})
        end
        payment_mentions(context, add) unless context.kind == "credit_note"
      end

      private def self.seller_mentions(context : Context, add) : Nil
        seller = context.seller
        if (capital = seller.share_capital) && !seller.legal_form.empty?
          add.call("seller.legal_form_capital", {"legal_form" => seller.legal_form, "capital" => amount(capital),
                                                 "currency" => context.currency_code})
        elsif !seller.legal_form.empty?
          add.call("seller.legal_form", {"legal_form" => seller.legal_form})
        end
        add.call("seller.rcs.#{context.regime}", {"rcs" => seller.rcs}) unless seller.rcs.empty?
        if context.regime == "fr"
          add.call("seller.siren", {"siren" => seller.siren}) unless seller.siren.empty?
        elsif !seller.vat_number.empty?
          add.call("seller.enterprise_number", {"number" => enterprise_number(seller.vat_number)})
        end
        add.call("seller.vat_number", {"vat_number" => seller.vat_number}) unless seller.vat_number.empty?
      end

      private def self.special_mentions(context : Context, add) : Nil
        seen = Set(String).new
        context.vat_breakdown.each do |group|
          code = SPECIAL_BY_EXEMPTION[group.exemption_code]? || SPECIAL_BY_CATEGORY[group.category]?
          next unless code
          next unless seen.add?(code)
          params = {"reason" => group.exemption_reason}
          add.call("special.#{code}.#{context.regime}", params)
        end
      end

      private def self.payment_mentions(context : Context, add) : Nil
        settings = context.settings
        add.call("dates.due", {"date" => iso(context.due_date)}) if context.due_date
        terms_mention(context, add)
        unless context.structured_reference.empty?
          add.call("payment.structured_reference", {"reference" => context.structured_reference})
        end
        unless settings.iban.empty?
          add.call("payment.bank", {"iban" => settings.iban, "bic" => settings.bic})
        end
        if (rate = settings.early_discount_rate) && rate > 0
          add.call("payment.early_discount", {"rate" => Calculator.plain(rate),
                                              "days" => (settings.early_discount_days || 0).to_s})
        else
          add.call("payment.no_early_discount", {} of String => String)
        end
        if rate = settings.late_penalty_rate
          add.call("payment.late_penalties", {"rate" => Calculator.plain(rate)})
        else
          add.call("payment.late_penalties_legal.#{context.regime}", {} of String => String)
        end
        if context.customer.professional?
          add.call("payment.indemnity", {"amount" => amount(INDEMNITY), "currency" => "EUR"})
        end
      end

      # Conditions de paiement choisies sur le document (D-R5-003).
      private def self.terms_mention(context : Context, add) : Nil
        PaymentTerms.mention(context.payment_terms, context.payment_terms_days).try do |(code, params)|
          add.call(code, params)
        end
      end

      # Numéro d'entreprise belge (BCE) déduit du numéro de TVA : `0417.497.106`.
      def self.enterprise_number(vat_number : String) : String
        digits = vat_number.gsub(/[^0-9]/, "")
        return vat_number unless digits.size == 10
        "#{digits[0, 4]}.#{digits[4, 3]}.#{digits[7, 3]}"
      end

      def self.differs?(address : Api::AddressView, customer : Api::PartyView) : Bool
        normalize = ->(text : String) { text.downcase.gsub(/\s+/, " ").strip }
        {address.line1, address.line2, address.postcode, address.city}.map { |part| normalize.call(part) } !=
          {customer.line1, customer.line2, customer.postcode, customer.city}.map { |part| normalize.call(part) }
      end
    end
  end
end
