# SPDX-License-Identifier: AGPL-3.0-or-later

require "log"
require "yaml"

module Partiduo
  module Accounting
    # Écritures du module liberal (ADR-007 D6), par les seuls événements
    # `liberal.receipt.recorded`, `liberal.expense.recorded` et
    # `liberal.asset.recorded` (ADR-006 D3 : la Comptabilité ne cite pas ce
    # module). Écriture de trésorerie au journal financier du mode de
    # règlement (caisse pour les espèces, banque sinon, comme
    # `Billing.financial_ledger`), en partie double :
    #
    # * recette : banque au débit, compte de la rubrique au crédit ;
    # * dépense : compte de la rubrique au débit, banque au crédit ;
    # * immobilisation acquise : compte d'immobilisation au débit, banque au
    #   crédit ; contre-passée : sens inversés ;
    # * cession : banque au débit, produit de cession au crédit (prix nul :
    #   pas d'écriture) ; la sortie de l'actif et les amortissements restent
    #   aux écritures d'inventaire du comptable (DECISIONS D-LIB-003) ;
    # * contre-passation (montant négatif) : sens inversés.
    #
    # Tenue toutes taxes comprises (DECISIONS D-LIB-009) : recettes et
    # dépenses passées TTC, sans TVA collectée ni déductible ; la TVA reversée
    # (rubrique `vat_paid`) est une charge (6358 en France, 640 en Belgique),
    # jamais un compte de TVA de classe 4.
    #
    # Compte, par ordre : paramétrage de la nature (`LiberalAccount` de clé
    # `<NATURE>`), de la rubrique (`<rubrique>`) ou de la catégorie
    # (`asset_<catégorie>`, `disposal`), puis compte proposé par le régime
    # (`data/liberal_accounts.yml`, créé au plan s'il manque, au libellé reçu
    # dans la charge utile). Une recette issue de la Facturation (`origin`
    # différent de `manual`) est ignorée : sa facture et son encaissement ont
    # déjà leurs écritures (D-INT-001, comme D-MIC-004).
    #
    # Référence : `liberal:receipt:<id>`, `liberal:expense:<id>`,
    # `liberal:asset:<id>`, `liberal:disposal:<id>` ; une référence déjà
    # comptabilisée ne l'est pas deux fois. Un échec ne bloque jamais le
    # registre. Service interne.
    module LiberalEntries
      Log = ::Log.for("partiduo.accounting.liberal")

      alias FieldError = Partiduo::Api::FieldError
      alias AccApi = Partiduo::Api::Accounting
      alias Result = Partiduo::Api::Result

      DEFAULTS = YAML.parse({{ read_file("#{__DIR__}/../data/liberal_accounts.yml") }})

      def self.on_event(event : Partiduo::Events::Event) : Nil
        result = post(Partiduo::Api::Actor.system, event.name, event.payload)
        if result.failure?
          Log.warn { "#{event.name} #{event.payload} non comptabilisé : #{result.error_keys.join(", ")}" }
        end
      rescue ex
        Log.warn(exception: ex) { "#{event.name} #{event.payload} non comptabilisé" }
      end

      # Passe l'écriture d'un événement ; identifiant de l'écriture créée,
      # `nil` si l'événement n'en demande pas ou est déjà passé.
      def self.post(actor : Partiduo::Api::Actor, name : String, payload : Hash(String, String)) : Result(Int64?)
        none = Result(Int64?).success(nil)
        case name
        when "liberal.receipt.recorded"
          return none unless payload["origin"]? == "manual"
          source = "liberal:receipt:#{payload["receipt_id"]}"
          keys = {payload["nature_code"]?.to_s, payload["heading"]?.to_s}
          debit = false
        when "liberal.expense.recorded"
          source = "liberal:expense:#{payload["expense_id"]}"
          keys = {payload["nature_code"]?.to_s, payload["heading"]?.to_s}
          debit = true
        when "liberal.asset.recorded"
          if payload["operation"]? == "disposal"
            source = "liberal:disposal:#{payload["disposal_id"]}"
            keys = {"", "disposal"}
            debit = false
            return none if decimal(payload["amount"]?).zero?
          else
            source = "liberal:asset:#{payload["asset_id"]}"
            keys = {"", "asset_#{payload["category"]?}"}
            debit = true
          end
        else
          return none
        end
        return none if Billing.posted?(source)
        Partiduo::Api::Transaction.run { post_entry(actor, payload, source, keys, debit) }
      end

      private def self.post_entry(actor : Partiduo::Api::Actor, payload : Hash(String, String), source : String,
                                  keys : {String, String}, debit : Bool) : Result(Int64?)
        errors = [] of FieldError
        ledger = Billing.financial_ledger(payload["method"]?.to_s)
        bank = ledger.try { |found| Ledgers.account_of(found) }
        errors << FieldError.base("accounting.errors.liberal.no_financial_ledger") if ledger.nil? || bank.nil?
        label = account_label(payload, keys[1])
        counterpart = account(keys, label, actor, errors)
        date = parse_date(payload["date"]?)
        errors << FieldError.new("date", "accounting.errors.billing.date_missing") if date.nil?
        return Result(Int64?).failure(errors) unless errors.empty? && ledger && bank && counterpart && date

        lines = entry_lines(decimal(payload["amount"]?), debit, counterpart, bank.number.to_s)
        input = AccApi::EntryInput.new(ledger_id: ledger.pk!.as(Int64), date: date, lines: lines, label: entry_label(payload),
          attachment_id: payload["attachment_id"]?.try(&.to_i64?), source: source)
        result = AccApi.post_entry(actor, input)
        return Result(Int64?).failure(result.errors) if result.failure?
        Result(Int64?).success(result.value!.id)
      end

      # Libellé d'un compte à créer : celui de la rubrique ou de la catégorie
      # reçu dans la charge utile ; produit de cession : libellé propre (pas
      # celui de la catégorie de l'immobilisation cédée).
      private def self.account_label(payload : Hash(String, String), key : String) : String
        return I18n.t("accounting.liberal.disposal_account_label") if key == "disposal"
        payload["heading_label"]?.presence || payload["category_label"]?.presence || key
      end

      # Contrepartie au débit (`debit`) ou au crédit, banque en face ;
      # montant négatif (contre-passation) : sens inversés.
      def self.entry_lines(amount : BigDecimal, debit : Bool, counterpart : String,
                           bank : String) : Array(AccApi::EntryLineInput)
        side = (debit ^ (amount < 0)) ? AccApi::Side::Debit : AccApi::Side::Credit
        [AccApi::EntryLineInput.new(account: counterpart, side: side, amount: amount.abs),
         AccApi::EntryLineInput.new(account: bank, side: side.opposite, amount: amount.abs)]
      end

      # Libellé : numéro de la ligne, tiers, désignation (200 caractères au plus).
      private def self.entry_label(payload : Hash(String, String)) : String
        text = [payload["number"]?, payload["party_name"]?, payload["label"]?].compact.map(&.strip).reject(&.empty?).join(" ")
        text.size > 200 ? text[0, 200] : text
      end

      # Numéro du compte de la contrepartie (voir l'en-tête).
      def self.account(keys : {String, String}, label : String, actor : Partiduo::Api::Actor,
                       errors : Array(FieldError)) : String?
        keys.each do |key|
          next if key.empty?
          if found = LiberalAccount.filter(key: key).first.try(&.account)
            return found.number.to_s
          end
        end
        regime = Partiduo::Api::Core.settings(Partiduo::Api::Actor.system).tax_regime
        if number = DEFAULTS[regime]?.try(&.[keys[1]]?).try(&.as_s)
          return number if Account.filter(number: number).exists?
          created = AccApi.create_account(actor, AccApi::AccountInput.new(number: number, label: label[0, Math.min(label.size, 100)]))
          return created.value!.number if created.success?
        end
        errors << FieldError.new("account", "accounting.errors.liberal.no_account", {"key" => keys[1]})
        nil
      rescue Partiduo::Api::NotFound
        errors << FieldError.new("account", "accounting.errors.liberal.no_account", {"key" => keys[1]})
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
