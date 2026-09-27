# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Invoicing
    # Paramètres de la Facturation (ligne unique, créée à la première
    # écriture) et lecture du socle : société, fiches, taux de TVA. Le socle
    # est lu par son contrat avec l'acteur système : la Facturation en fige
    # une copie sur chaque document émis.
    module Configuration
      alias Api = Partiduo::Api::Invoicing

      # Comptes de l'export au comptable, par régime (plans de NOALYSS :
      # `mod2` en France, `mod1` en Belgique), quand les paramètres n'en
      # indiquent pas.
      DEFAULT_ACCOUNTS = {
        "fr" => {customer: "411000", sales: "706000", vat: "445710", bank: "512000"},
        "be" => {customer: "400000", sales: "700000", vat: "451000", bank: "550000"},
      }

      def self.system : Partiduo::Api::Actor
        Partiduo::Api::Actor.system
      end

      def self.record : Settings?
        Settings.all.first
      end

      def self.settings : Api::SettingsView
        view(record || Settings.new)
      end

      def self.view(row : Settings) : Api::SettingsView
        Api::SettingsView.new(
          payment_terms_days: row.payment_terms_days!.to_i32,
          quote_validity_days: row.quote_validity_days!.to_i32,
          late_penalty_rate: row.late_penalty_rate,
          early_discount_rate: row.early_discount_rate,
          early_discount_days: row.early_discount_days.try(&.to_i32),
          vat_on_debits: row.vat_on_debits!,
          default_operation_category: row.default_operation_category!,
          iban: row.iban.to_s,
          bic: row.bic.to_s,
          sender_email: row.sender_email.to_s,
          sender_name: row.sender_name.to_s,
          reminder1_days: row.reminder1_days!.to_i32,
          reminder2_days: row.reminder2_days!.to_i32,
          reminder3_days: row.reminder3_days!.to_i32,
          penalty_from_level: row.penalty_from_level!.to_i32,
          reminder_subject: row.reminder_subject.to_s,
          reminder_body: row.reminder_body.to_s,
          sales_journal_code: row.sales_journal_code!,
          bank_journal_code: row.bank_journal_code!,
          customer_account: row.customer_account.to_s,
          sales_account: row.sales_account.to_s,
          vat_account: row.vat_account.to_s,
          bank_account: row.bank_account.to_s,
        )
      end

      def self.errors(input : Api::SettingsInput) : Array(Partiduo::Api::FieldError)
        terms_errors(input) + contact_errors(input) + reminder_errors(input) + export_errors(input)
      end

      private def self.error(field : String, code : String, params = {} of String => String) : Partiduo::Api::FieldError
        Partiduo::Api::FieldError.new(field, "invoicing.errors.settings.#{code}", params)
      end

      private def self.terms_errors(input : Api::SettingsInput) : Array(Partiduo::Api::FieldError)
        errors = [] of Partiduo::Api::FieldError
        errors << error("payment_terms_days", "days", {"max" => "365"}) unless (0..365).includes?(input.payment_terms_days)
        errors << error("quote_validity_days", "days", {"max" => "365"}) unless (1..365).includes?(input.quote_validity_days)
        {"late_penalty_rate" => input.late_penalty_rate, "early_discount_rate" => input.early_discount_rate}.each do |field, rate|
          errors << error(field, "rate") if rate && (rate < 0 || rate > 100 || Calculator.scale(rate) > 4)
        end
        if (days = input.early_discount_days) && !(0..365).includes?(days)
          errors << error("early_discount_days", "days", {"max" => "365"})
        end
        unless Api::OPERATION_CATEGORIES.includes?(input.default_operation_category)
          errors << error("default_operation_category", "operation_category")
        end
        errors
      end

      private def self.contact_errors(input : Api::SettingsInput) : Array(Partiduo::Api::FieldError)
        errors = [] of Partiduo::Api::FieldError
        iban = input.iban.gsub(/\s/, "").upcase
        errors << error("iban", "iban") unless iban.empty? || Partiduo::Core::Identifiers.valid_iban?(iban)
        bic = input.bic.gsub(/\s/, "").upcase
        errors << error("bic", "bic") unless bic.empty? || Partiduo::Core::Identifiers.valid_bic?(bic)
        unless input.sender_email.empty? || Mail.valid_address?(input.sender_email)
          errors << error("sender_email", "email")
        end
        errors
      end

      private def self.reminder_errors(input : Api::SettingsInput) : Array(Partiduo::Api::FieldError)
        errors = [] of Partiduo::Api::FieldError
        days = [input.reminder1_days, input.reminder2_days, input.reminder3_days]
        if days.any? { |day| !(1..365).includes?(day) } || days != days.sort || days.uniq.size != 3
          errors << error("reminder1_days", "reminder_days")
        end
        errors << error("penalty_from_level", "penalty_level") unless (0..3).includes?(input.penalty_from_level)
        errors
      end

      private def self.export_errors(input : Api::SettingsInput) : Array(Partiduo::Api::FieldError)
        errors = [] of Partiduo::Api::FieldError
        {"sales_journal_code" => input.sales_journal_code, "bank_journal_code" => input.bank_journal_code}.each do |field, code|
          errors << error(field, "journal_code") unless code.matches?(/\A[A-Z0-9]{1,8}\z/)
        end
        {"customer_account" => input.customer_account, "sales_account" => input.sales_account,
         "vat_account" => input.vat_account, "bank_account" => input.bank_account}.each do |field, account|
          errors << error(field, "account") unless account.matches?(/\A[0-9A-Z]{0,20}\z/)
        end
        errors
      end

      def self.save!(input : Api::SettingsInput) : Api::SettingsView
        row = Settings.all.lock.first || Settings.new
        row.payment_terms_days = input.payment_terms_days
        row.quote_validity_days = input.quote_validity_days
        row.late_penalty_rate = input.late_penalty_rate
        row.early_discount_rate = input.early_discount_rate
        row.early_discount_days = input.early_discount_days
        row.vat_on_debits = input.vat_on_debits
        row.default_operation_category = input.default_operation_category
        row.iban = input.iban.gsub(/\s/, "").upcase
        row.bic = input.bic.gsub(/\s/, "").upcase
        row.sender_email = input.sender_email.strip
        row.sender_name = input.sender_name.strip
        row.reminder1_days = input.reminder1_days
        row.reminder2_days = input.reminder2_days
        row.reminder3_days = input.reminder3_days
        row.penalty_from_level = input.penalty_from_level
        row.reminder_subject = input.reminder_subject.strip
        row.reminder_body = input.reminder_body
        row.sales_journal_code = input.sales_journal_code
        row.bank_journal_code = input.bank_journal_code
        row.customer_account = input.customer_account
        row.sales_account = input.sales_account
        row.vat_account = input.vat_account
        row.bank_account = input.bank_account
        row.save!
        view(row)
      end

      # --- Socle -------------------------------------------------------------------

      def self.company : Partiduo::Api::Core::SettingsView
        Partiduo::Api::Core.settings(system)
      end

      def self.regime : String
        company.tax_regime
      end

      def self.accounts : NamedTuple(customer: String, sales: String, vat: String, bank: String)
        defaults = DEFAULT_ACCOUNTS.fetch(regime, DEFAULT_ACCOUNTS["fr"])
        current = settings
        {
          customer: current.customer_account.presence || defaults[:customer],
          sales:    current.sales_account.presence || defaults[:sales],
          vat:      current.vat_account.presence || defaults[:vat],
          bank:     current.bank_account.presence || defaults[:bank],
        }
      end

      def self.card(id : Int64) : Partiduo::Api::Cards::CardView?
        Partiduo::Api::Cards.card(system, id)
      rescue Partiduo::Api::NotFound
        nil
      end

      def self.rate(id : Int64) : Partiduo::Api::Vat::RateView?
        Partiduo::Api::Vat.rate(system, id)
      rescue Partiduo::Api::NotFound
        nil
      end

      def self.base_currency : String
        Partiduo::Api::Core.base_currency(system).code
      rescue Partiduo::Api::NotFound
        "EUR"
      end

      def self.currency_decimals(code : String) : Int32?
        Partiduo::Api::Core.currency(system, code).decimals
      rescue Partiduo::Api::NotFound
        nil
      end

      # Vendeur : la société du socle.
      def self.seller_party : Api::PartyView
        company = self.company
        Api::PartyView.new(
          name: company.company_name, code: "", legal_form: company.legal_form, share_capital: company.share_capital,
          rcs: company.rcs, siren: company.siren.gsub(/\s/, ""), siret: "", vat_number: company.vat_number,
          line1: [company.street_number, company.street].reject(&.empty?).join(" "), line2: "",
          postcode: company.postcode, city: company.city, country_code: company.country_code,
          email: company.email, phone: company.phone, routing_id: "",
        )
      end

      # Client : fiche du socle et son adresse principale.
      def self.customer_party(card : Partiduo::Api::Cards::CardView) : Api::PartyView
        address = card.address
        Api::PartyView.new(
          name: card.name, code: card.code, legal_form: "", share_capital: nil, rcs: "", siren: card.siren,
          siret: card.siret, vat_number: card.vat_number, line1: address.try(&.line1).to_s,
          line2: address.try(&.line2).to_s, postcode: address.try(&.postcode).to_s, city: address.try(&.city).to_s,
          country_code: address.try(&.country_code) || company.country_code, email: card.email, phone: card.phone,
          routing_id: card.routing_id,
        )
      end

      def self.party_json(party : Api::PartyView) : JSON::Any
        JSON.parse({
          "name" => party.name, "code" => party.code, "legal_form" => party.legal_form,
          "share_capital" => party.share_capital.try(&.to_s), "rcs" => party.rcs, "siren" => party.siren,
          "siret" => party.siret, "vat_number" => party.vat_number, "line1" => party.line1, "line2" => party.line2,
          "postcode" => party.postcode, "city" => party.city, "country_code" => party.country_code,
          "email" => party.email, "phone" => party.phone, "routing_id" => party.routing_id,
        }.to_json)
      end

      def self.party_from_json(json : JSON::Any) : Api::PartyView
        text = ->(key : String) { json[key]?.try(&.as_s?) || "" }
        Api::PartyView.new(
          name: text.call("name"), code: text.call("code"), legal_form: text.call("legal_form"),
          share_capital: json["share_capital"]?.try(&.as_s?).try { |value| BigDecimal.new(value) },
          rcs: text.call("rcs"), siren: text.call("siren"), siret: text.call("siret"),
          vat_number: text.call("vat_number"), line1: text.call("line1"), line2: text.call("line2"),
          postcode: text.call("postcode"), city: text.call("city"), country_code: text.call("country_code"),
          email: text.call("email"), phone: text.call("phone"), routing_id: text.call("routing_id"),
        )
      end

      def self.address_json(address : Api::AddressView) : JSON::Any
        JSON.parse({"line1" => address.line1, "line2" => address.line2, "postcode" => address.postcode,
                    "city" => address.city, "country_code" => address.country_code}.to_json)
      end

      def self.address_from_json(json : JSON::Any?) : Api::AddressView?
        return unless json && json.as_h?
        text = ->(key : String) { json[key]?.try(&.as_s?) || "" }
        Api::AddressView.new(text.call("line1"), text.call("line2"), text.call("postcode"), text.call("city"),
          text.call("country_code"))
      end
    end
  end
end
