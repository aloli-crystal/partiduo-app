# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Invoicing
    # Conditions de paiement d'un document (maquette « Nouvelle facture » :
    # 30 jours, 45 jours fin de mois, à réception ; BLOCAGES B-FIN-001).
    #
    # * vide : délai des paramètres, jours nets, sans mention particulière
    #   (comportement antérieur) ;
    # * `net` : émission + délai ;
    # * `end_of_month` : émission + délai, puis fin de ce mois (« 45 jours fin
    #   de mois », L441-10 du Code de commerce) ;
    # * `on_receipt` : échéance à l'émission.
    #
    # Délai du document vide : celui des paramètres. DECISIONS D-R5-003.
    module PaymentTerms
      alias Api = Partiduo::Api::Invoicing
      alias FieldError = Partiduo::Api::FieldError

      def self.errors(input : Api::DocumentInput) : Array(FieldError)
        errors = [] of FieldError
        terms = input.payment_terms.presence
        days = input.payment_terms_days
        if terms && !Api::PAYMENT_TERMS.includes?(terms)
          errors << Documents.error("payment_terms", "document.payment_terms.invalid")
        end
        if days
          if !(0..Api::MAX_PAYMENT_DAYS).includes?(days)
            errors << Documents.error("payment_terms_days", "document.payment_terms_days.range",
              {"max" => Api::MAX_PAYMENT_DAYS.to_s})
          elsif terms == "on_receipt"
            errors << Documents.error("payment_terms_days", "document.payment_terms_days.on_receipt")
          end
        end
        errors
      end

      # Délai retenu : celui du document, sinon celui des paramètres.
      def self.days(document : Document) : Int32
        document.payment_terms_days.try(&.to_i32) || Configuration.settings.payment_terms_days
      end

      # Échéance d'une facture émise le `issue_date`.
      def self.due_date(document : Document, issue_date : Time) : Time
        case document.payment_terms.to_s
        when "on_receipt"
          issue_date
        when "end_of_month"
          end_of_month(issue_date + days(document).days)
        else
          issue_date + days(document).days
        end
      end

      # Mention des conditions (`payment.terms.net`…), `nil` sans condition.
      def self.mention(terms : String, days : Int32) : {String, Hash(String, String)}?
        case terms
        when "on_receipt"          then {"payment.terms.on_receipt", {} of String => String}
        when "net", "end_of_month" then {"payment.terms.#{terms}", {"days" => days.to_s}}
        end
      end

      private def self.end_of_month(date : Time) : Time
        Time.utc(date.year, date.month, Time.days_in_month(date.year, date.month))
      end
    end
  end
end
