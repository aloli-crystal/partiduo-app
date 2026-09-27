# SPDX-License-Identifier: AGPL-3.0-or-later

require "log"
require "yaml"

module Partiduo
  module Accounting
    # Écritures des registres de la micro-entreprise (ADR-007 D2), par les
    # seuls événements `micro.receipt.recorded` et `micro.purchase.recorded`
    # (ADR-006 D3 : la Comptabilité ne cite pas ce module). Écriture de
    # trésorerie au journal financier du mode de règlement (caisse pour les
    # espèces, banque sinon, comme `Billing.financial_ledger`) :
    #
    # * recette : banque au débit du montant encaissé, produit au crédit du
    #   hors taxe, TVA collectée au crédit de la TVA ;
    # * achat : charge (hors taxe) et TVA déductible au débit, banque au
    #   crédit ;
    # * contre-passation (montant négatif) : mêmes comptes, sens inversés.
    #
    # Compte de la contrepartie, par ordre : paramétrage de la nature
    # (`MicroAccount` de clé `<NATURE>`), de la catégorie (`<catégorie>`),
    # puis compte proposé par le régime
    # (`data/micro_accounts.yml`, créé au plan s'il manque). Une recette
    # issue de la Facturation (`origin` différent de `manual`) est ignorée :
    # sa facture et son encaissement ont déjà leurs écritures (D-INT-001) ;
    # sa contre-passation saisie à la main (remboursement) porte l'origine
    # `manual` et passe donc son écriture (D-MIC-011).
    #
    # Référence de l'écriture : `micro:receipt:<id>`, `micro:purchase:<id>` ;
    # une référence déjà comptabilisée ne l'est pas deux fois. Un échec ne
    # bloque jamais le registre. Service interne.
    module MicroEntries
      Log = ::Log.for("partiduo.accounting.micro")

      alias FieldError = Partiduo::Api::FieldError
      alias AccApi = Partiduo::Api::Accounting

      DEFAULTS = YAML.parse({{ read_file("#{__DIR__}/../data/micro_accounts.yml") }})

      def self.on_event(event : Partiduo::Events::Event) : Nil
        result = post(Partiduo::Api::Actor.system, event.name, event.payload)
        if result.failure?
          Log.warn { "#{event.name} #{event.payload} non comptabilisé : #{result.error_keys.join(", ")}" }
        end
      rescue ex
        Log.warn(exception: ex) { "#{event.name} #{event.payload} non comptabilisé" }
      end

      # Passe l'écriture d'une ligne de registre ; identifiant de l'écriture
      # créée, `nil` si la ligne n'en demande pas ou est déjà passée.
      def self.post(actor : Partiduo::Api::Actor, name : String,
                    payload : Hash(String, String)) : Partiduo::Api::Result(Int64?)
        receipt = name == "micro.receipt.recorded"
        return Partiduo::Api::Result(Int64?).success(nil) if receipt && payload["origin"]? != "manual"
        source = receipt ? "micro:receipt:#{payload["receipt_id"]}" : "micro:purchase:#{payload["purchase_id"]}"
        return Partiduo::Api::Result(Int64?).success(nil) if Billing.posted?(source)

        Partiduo::Api::Transaction.run { post_entry(actor, receipt, payload, source) }
      end

      private def self.post_entry(actor : Partiduo::Api::Actor, receipt : Bool, payload : Hash(String, String),
                                  source : String) : Partiduo::Api::Result(Int64?)
        errors = [] of FieldError
        ledger = Billing.financial_ledger(payload["method"]?.to_s)
        bank = ledger.try { |found| Ledgers.account_of(found) }
        errors << FieldError.base("accounting.errors.micro.no_financial_ledger") if ledger.nil? || bank.nil?
        counterpart = account(payload["nature_code"]?.to_s, payload["category"]?.to_s, receipt, actor, errors)
        date = parse_date(payload["date"]?)
        errors << FieldError.new("date", "accounting.errors.billing.date_missing") if date.nil?
        vat = decimal(payload["vat_amount"]?)
        vat_account = vat.zero? ? nil : account("", receipt ? "vat" : "vat_deductible", receipt, actor, errors)
        unless errors.empty? && ledger && bank && counterpart && date
          return Partiduo::Api::Result(Int64?).failure(errors)
        end

        lines = entry_lines(receipt, decimal(payload["amount"]?), vat, bank.number.to_s, counterpart, vat_account)
        input = AccApi::EntryInput.new(ledger_id: ledger.pk!.as(Int64), date: date, lines: lines, label: label(payload),
          attachment_id: payload["attachment_id"]?.try(&.to_i64?), source: source)
        result = AccApi.post_entry(actor, input)
        return Partiduo::Api::Result(Int64?).failure(result.errors) if result.failure?
        Partiduo::Api::Result(Int64?).success(result.value!.id)
      end

      # Libellé : numéro de la ligne, tiers, désignation (200 caractères au plus).
      private def self.label(payload : Hash(String, String)) : String
        text = [payload["number"]?, payload["party_name"]?, payload["label"]?].compact.map(&.strip).reject(&.empty?).join(" ")
        text.size > 200 ? text[0, 200] : text
      end

      # Lignes de l'écriture ; montant négatif (contre-passation) : sens inversés.
      def self.entry_lines(receipt : Bool, amount : BigDecimal, vat : BigDecimal, bank : String, counterpart : String,
                           vat_account : String?) : Array(AccApi::EntryLineInput)
        side = ->(side : AccApi::Side) { amount < 0 ? side.opposite : side }
        total = amount.abs
        if receipt
          lines = [AccApi::EntryLineInput.new(account: bank, side: side.call(AccApi::Side::Debit), amount: total),
                   AccApi::EntryLineInput.new(account: counterpart, side: side.call(AccApi::Side::Credit), amount: total - vat.abs)]
          if vat_account && !vat.zero?
            lines << AccApi::EntryLineInput.new(account: vat_account, side: side.call(AccApi::Side::Credit), amount: vat.abs)
          end
          lines
        else
          lines = [AccApi::EntryLineInput.new(account: counterpart, side: side.call(AccApi::Side::Debit), amount: total - vat.abs)]
          if vat_account && !vat.zero?
            lines << AccApi::EntryLineInput.new(account: vat_account, side: side.call(AccApi::Side::Debit), amount: vat.abs)
          end
          lines << AccApi::EntryLineInput.new(account: bank, side: side.call(AccApi::Side::Credit), amount: total)
        end
      end

      # Numéro du compte de la contrepartie (voir l'en-tête).
      def self.account(nature_code : String, category : String, receipt : Bool, actor : Partiduo::Api::Actor,
                       errors : Array(FieldError)) : String?
        {nature_code, category}.each do |key|
          next if key.empty?
          if found = MicroAccount.filter(key: key).first.try(&.account)
            return found.number.to_s
          end
        end
        regime = Partiduo::Api::Core.settings(Partiduo::Api::Actor.system).tax_regime
        number = DEFAULTS[regime]?.try(&.[category]?).try(&.as_s)
        if number
          return number if Account.filter(number: number).exists?
          created = AccApi.create_account(actor, AccApi::AccountInput.new(number: number,
            label: I18n.t("accounting.micro.accounts.#{category}")))
          return created.value!.number if created.success?
        end
        if receipt && !category.starts_with?("vat")
          if sales = DefaultAccount.filter(code: "sales").first.try(&.account)
            return sales.number.to_s
          end
        end
        errors << FieldError.new("account", "accounting.errors.micro.no_account", {"category" => category})
        nil
      rescue Partiduo::Api::NotFound
        errors << FieldError.new("account", "accounting.errors.micro.no_account", {"category" => category})
        nil
      end

      private def self.decimal(text : String?) : BigDecimal
        text.try(&.strip).presence.try { |value| BigDecimal.new(value) } || BigDecimal.new(0)
      end

      private def self.parse_date(text : String?) : Time?
        text.try(&.strip).presence.try { |value| Time.parse_utc(value, "%Y-%m-%d") }
      rescue Time::Format::Error
        nil
      end
    end
  end
end
