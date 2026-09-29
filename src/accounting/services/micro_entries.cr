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
    # une référence déjà comptabilisée ne l'est pas deux fois. Un échec
    # d'inscription ne bloque jamais le registre (la republication le
    # rattrape).
    #
    # Ligne modifiée ou supprimée dans une période ouverte
    # (`micro.*.updated`, `micro.*.deleted`, D-MIC2-003) : les écritures en
    # vigueur de la référence sont extournées (la Comptabilité ne modifie ni
    # ne supprime une écriture passée, D-ACC-015) et, pour une modification,
    # la nouvelle écriture est passée sous la même référence — rien ne
    # change si elle serait identique. Si l'extourne ou la nouvelle écriture
    # est impossible alors que la ligne avait une écriture, l'abonné lève
    # `Partiduo::Events::Refused` : la modification ou la suppression est
    # refusée, registre et comptabilité ne divergent jamais. Service interne.
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

      # Abonné de `micro.receipt.updated`, `micro.receipt.deleted`,
      # `micro.purchase.updated` et `micro.purchase.deleted` : refuse
      # l'opération (`Refused`) plutôt que de laisser registre et
      # comptabilité diverger.
      def self.on_change(event : Partiduo::Events::Event) : Nil
        result = change(Partiduo::Api::Actor.system, event.name, event.payload)
        raise Partiduo::Events::Refused.new(result.errors) if result.failure?
      end

      # Remplace (modification) ou extourne (suppression) l'écriture d'une
      # ligne ; identifiant de la nouvelle écriture, `nil` s'il n'y en a pas.
      def self.change(actor : Partiduo::Api::Actor, name : String,
                      payload : Hash(String, String)) : Partiduo::Api::Result(Int64?)
        receipt = name.starts_with?("micro.receipt.")
        updated = name.ends_with?(".updated")
        source = receipt ? "micro:receipt:#{payload["receipt_id"]}" : "micro:purchase:#{payload["purchase_id"]}"
        live = Billing.live_entries([source]).order(:id).to_a
        wanted = updated && !(receipt && payload["origin"]? != "manual")
        return Partiduo::Api::Result(Int64?).success(nil) if wanted && unchanged?(actor, receipt, payload, source, live)

        Partiduo::Api::Transaction.run do
          if failure = cancel_all(actor, live)
            next Partiduo::Api::Result(Int64?).failure(failure)
          end
          next Partiduo::Api::Result(Int64?).success(nil) unless wanted
          posted = post_entry(actor, receipt, payload, source)
          if posted.failure? && live.empty?
            # Ligne jamais comptabilisée (paramétrage absent) : même état
            # qu'avant la modification, que la republication rattrapera.
            Log.warn { "#{name} #{payload} non comptabilisé : #{posted.error_keys.join(", ")}" }
            next Partiduo::Api::Result(Int64?).success(nil)
          end
          posted
        end
      end

      # Extourne les écritures ; erreurs de la première refusée, sinon `nil`.
      private def self.cancel_all(actor : Partiduo::Api::Actor, entries : Array(Entry)) : Array(FieldError)?
        entries.each do |entry|
          cancelled = AccApi.cancel_entry(actor, AccApi::CancelEntryInput.new(entry.pk!.as(Int64)))
          return cancelled.errors if cancelled.failure?
        end
        nil
      end

      # Une seule écriture en vigueur, déjà celle que la ligne demande.
      private def self.unchanged?(actor : Partiduo::Api::Actor, receipt : Bool, payload : Hash(String, String),
                                  source : String, live : Array(Entry)) : Bool
        return false unless live.size == 1
        input, _ = entry_input(actor, receipt, payload, source)
        !input.nil? && same?(live.first, input)
      end

      # L'écriture en vigueur est-elle déjà celle que la ligne demande
      # (journal, date, libellé, pièce jointe, comptes, sens et montants) ?
      private def self.same?(entry : Entry, input : AccApi::EntryInput) : Bool
        ledger_id = entry.ledger_id.as(Int).to_i64
        attachment_id = entry.attachment_id.try(&.to_i64)
        return false unless ledger_id == input.ledger_id && entry.date == input.date
        return false unless entry.label.to_s == input.label && attachment_id == input.attachment_id
        current = entry.lines.map { |line| {line.account!.number.to_s, line.side.to_s, line.amount!} }.sort!
        wanted = input.lines.map { |line| {line.account, line.side.code, line.amount} }.sort!
        current == wanted
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
        input, errors = entry_input(actor, receipt, payload, source)
        return Partiduo::Api::Result(Int64?).failure(errors) unless input
        result = AccApi.post_entry(actor, input)
        return Partiduo::Api::Result(Int64?).failure(result.errors) if result.failure?
        Partiduo::Api::Result(Int64?).success(result.value!.id)
      end

      # Écriture demandée par une ligne, ou les erreurs qui l'empêchent (les
      # comptes proposés par le régime sont créés au plan s'ils manquent).
      private def self.entry_input(actor : Partiduo::Api::Actor, receipt : Bool, payload : Hash(String, String),
                                   source : String) : {AccApi::EntryInput?, Array(FieldError)}
        errors = [] of FieldError
        ledger = Billing.financial_ledger(payload["method"]?.to_s)
        bank = ledger.try { |found| Ledgers.account_of(found) }
        errors << FieldError.base("accounting.errors.micro.no_financial_ledger") if ledger.nil? || bank.nil?
        counterpart = account(payload["nature_code"]?.to_s, payload["category"]?.to_s, receipt, actor, errors)
        date = parse_date(payload["date"]?)
        errors << FieldError.new("date", "accounting.errors.billing.date_missing") if date.nil?
        vat = decimal(payload["vat_amount"]?)
        vat_account = vat.zero? ? nil : account("", receipt ? "vat" : "vat_deductible", receipt, actor, errors)
        return {nil, errors} unless errors.empty? && ledger && bank && counterpart && date

        lines = entry_lines(receipt, decimal(payload["amount"]?), vat, bank.number.to_s, counterpart, vat_account)
        input = AccApi::EntryInput.new(ledger_id: ledger.pk!.as(Int64), date: date, lines: lines, label: label(payload),
          attachment_id: payload["attachment_id"]?.try(&.to_i64?), source: source)
        {input, errors}
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
