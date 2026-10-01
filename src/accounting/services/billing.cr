# SPDX-License-Identifier: AGPL-3.0-or-later

require "log"

module Partiduo
  module Accounting
    # Écritures issues de la Facturation (ADR-006 D3), sans jamais citer ce
    # module : tout vient de la charge utile des événements (D-INV-010) et du
    # socle.
    #
    # * `invoice.issued` : vente au premier journal de ventes actif — compte
    #   de vente de l'article (celui de sa fiche, sinon le compte par défaut
    #   du journal, sinon le compte par défaut `sales`), TVA par taux, client
    #   au compte de sa fiche ; pièce = numéro de la facture. Les acomptes
    #   déduits sont extournés sur la facture finale (D-INT-004).
    # * `credit_note.issued` : même écriture en négatif, lettrée avec la
    #   ligne client de la facture créditée.
    # * `payment.recorded` : encaissement au journal financier (caisse pour
    #   un règlement en espèces), lettré avec la facture ;
    # * `payment.rejected` : contre-passation de l'encaissement rejeté
    #   (D-INV3-008) — son lettrage est défait (`payment.unmatched`), une
    #   écriture inverse est passée au même journal financier à la date du
    #   rejet et lettrée avec lui, les autres règlements de la facture sont
    #   relettrés ; frais bancaires au compte par défaut `bank_fees`.
    #
    # Référence de l'écriture (`source`) : `invoice:<id>`, `credit_note:<id>`,
    # `payment:<id>`, `payment_rejection:<id>` (frais : `…:fees`) ; une source déjà comptabilisée ne l'est pas deux fois
    # (index unique `accounting_entry_source`, migration 0004). Une écriture
    # extournée libère sa référence : l'événement redevient à comptabiliser
    # (D-2F-010).
    # Un échec ne bloque jamais la Facturation : l'événement reste dans le
    # journal du socle et figure dans l'historique à comptabiliser
    # (D-INT-003). Service interne.
    module Billing
      Log = ::Log.for("partiduo.accounting.billing")

      alias FieldError = Partiduo::Api::FieldError
      alias AccApi = Partiduo::Api::Accounting

      EVENTS = Partiduo::Events::JOURNALED

      # Issue d'un événement rejoué.
      record Outcome, event : Partiduo::Events::JournalEntry, source : String, entry_ids : Array(Int64),
        errors : Array(FieldError)

      # --- Abonné ------------------------------------------------------------------

      # Abonné de `invoice.issued`, `credit_note.issued` et `payment.recorded`.
      def self.on_event(event : Partiduo::Events::Event) : Nil
        result = post(Partiduo::Api::Actor.system, event.name, event.payload)
        if result.failure?
          Log.debug { "#{event.name} #{source_of(event.name, event.payload)} non comptabilisé : #{result.error_keys.join(", ")}" }
        end
      rescue ex
        # La Facturation ne dépend pas de la Comptabilité : l'événement reste
        # à comptabiliser (historique).
        Log.warn(exception: ex) { "#{event.name} #{source_of(event.name, event.payload)} non comptabilisé" }
      end

      # --- Historique ----------------------------------------------------------------

      # Référence de l'écriture d'un événement.
      def self.source_of(name : String, payload : Hash(String, String)) : String
        case name
        when "payment.recorded"   then "payment:#{payload["payment_id"]?}"
        when "payment.rejected"   then "payment_rejection:#{payload["rejection_id"]?}"
        when "credit_note.issued" then payload["source"]? || "credit_note:#{payload["credit_note_id"]?}"
        else                           payload["source"]? || "invoice:#{payload["invoice_id"]?}"
        end
      end

      # Écritures en vigueur (ni extourne, ni extournée) d'une ou plusieurs
      # références.
      def self.live_entries(sources : Array(String))
        Entry.filter(source__in: sources, reversal_of_id__isnull: true, reversed: false)
      end

      # La référence a-t-elle une écriture en vigueur ?
      def self.posted?(source : String) : Bool
        live_entries([source]).exists?
      end

      # Événements du journal du socle qui n'ont pas d'écriture en vigueur
      # (jamais comptabilisés, ou dont toutes les écritures sont extournées),
      # hors événements écartés.
      def self.pending(ids : Enumerable(Int64)? = nil) : Array(Partiduo::Events::JournalEntry)
        journal = Partiduo::Events.journal(EVENTS, ids)
        return journal if journal.empty?
        dismissed = BillingDismissal.filter(event_id__in: journal.map(&.id)).map(&.event_id!.to_i64).to_set
        journal = journal.reject { |event| dismissed.includes?(event.id) }
        return journal if journal.empty?
        sources = journal.map { |event| source_of(event.name, event.payload) }.uniq!
        posted = live_entries(sources).map(&.source.to_s).to_set
        seen = Set(String).new
        journal.select do |event|
          source = source_of(event.name, event.payload)
          !posted.includes?(source) && seen.add?(source)
        end
      end

      # Comptabilise les événements dans l'ordre, chacun dans son point de
      # sauvegarde : un échec n'empêche pas les suivants.
      def self.replay(actor : Partiduo::Api::Actor, events : Array(Partiduo::Events::JournalEntry)) : Array(Outcome)
        events.map do |event|
          source = source_of(event.name, event.payload)
          result = begin
            post(actor, event.name, event.payload)
          rescue ex : Partiduo::Api::Forbidden | Partiduo::Api::ModuleDisabled
            raise ex
          rescue ex
            Log.warn(exception: ex) { "#{event.name} #{source} non comptabilisé" }
            Partiduo::Api::Result(Array(Int64)).failure(FieldError.base("accounting.errors.billing.failed",
              {"source" => source}))
          end
          Outcome.new(event, source, result.value? || [] of Int64, result.errors)
        end
      end

      # --- Comptabilisation -------------------------------------------------------

      # Passe l'écriture d'un événement (identifiants des écritures créées ;
      # vide si la source est déjà comptabilisée, y compris par une
      # comptabilisation concurrente arrêtée par l'index unique).
      def self.post(actor : Partiduo::Api::Actor, name : String,
                    payload : Hash(String, String)) : Partiduo::Api::Result(Array(Int64))
        Partiduo::Api::Transaction.run do
          source = source_of(name, payload)
          next Partiduo::Api::Result(Array(Int64)).success([] of Int64) if posted?(source)
          case name
          when "invoice.issued", "credit_note.issued"
            post_document(actor, name, payload, source)
          when "payment.recorded"
            post_payment(actor, payload, source)
          when "payment.rejected"
            post_rejection(actor, payload, source)
          else
            raise ArgumentError.new("événement non comptabilisable : #{name}")
          end
        end
      rescue ex : PQ::PQError
        raise ex unless ex.message.to_s.includes?(SOURCE_INDEX)
        Partiduo::Api::Result(Array(Int64)).success([] of Int64)
      end

      # Index unique d'une référence en vigueur (migration accounting 0004).
      SOURCE_INDEX = "accounting_entry_source"

      private def self.post_document(actor : Partiduo::Api::Actor, name : String, payload : Hash(String, String),
                                     source : String) : Partiduo::Api::Result(Array(Int64))
        errors = [] of FieldError
        input = document_input(name, payload, source, errors)
        return Partiduo::Api::Result(Array(Int64)).failure(errors) if input.nil?
        result = AccApi.post_sale(actor, input)
        return Partiduo::Api::Result(Array(Int64)).failure(result.errors) if result.failure?
        entry = result.value!
        if name == "credit_note.issued"
          customer_id = payload["customer_card_id"]?.try(&.to_i64?)
          invoice = sale_entry("invoice:#{payload["invoice_id"]?}")
          match_open(actor, third_party_line(entry.id, customer_id), invoice.try { |found| third_party_line(found, customer_id) })
        end
        Partiduo::Api::Result(Array(Int64)).success([entry.id])
      end

      private def self.post_payment(actor : Partiduo::Api::Actor, payload : Hash(String, String),
                                    source : String) : Partiduo::Api::Result(Array(Int64))
        errors = [] of FieldError
        input = payment_input(payload, source, errors)
        return Partiduo::Api::Result(Array(Int64)).failure(errors) if input.nil?
        result = AccApi.post_financial(actor, input)
        return Partiduo::Api::Result(Array(Int64)).failure(result.errors) if result.failure?
        Partiduo::Api::Result(Array(Int64)).success(result.value!.map(&.id))
      end

      # Règlement rejeté (D-INV3-008) : l'encaissement — écriture `payment:<id>`
      # d'un règlement saisi, sinon la ligne de banque lettrée avec la
      # facture pour ce montant — est contre-passé à la date du rejet, au
      # même journal : délettrage (`payment.unmatched`), écriture inverse
      # lettrée avec lui, relettrage des autres règlements de la facture
      # (`payment.matched`) ; frais au compte `bank_fees`.
      private def self.post_rejection(actor : Partiduo::Api::Actor, payload : Hash(String, String),
                                      source : String) : Partiduo::Api::Result(Array(Int64))
        result = Partiduo::Api::Result(Array(Int64))
        errors = [] of FieldError
        customer = customer(payload["customer_card_id"]?, errors)
        date = parse_date(payload["rejected_on"]?)
        errors << FieldError.new("date", "accounting.errors.billing.date_missing") if date.nil?
        return result.failure(errors) unless errors.empty? && customer && date
        amount = decimal(payload["amount"]?)
        line = rejected_line(payload, customer.id, amount)
        return result.failure(FieldError.base("accounting.errors.billing.rejection.payment_not_found")) unless line
        entry = Entry.filter(id: line.entry_id).first!
        group = [] of EntryLine
        if matching_id = line.matching_id.try(&.as(Int).to_i64)
          group = EntryLine.filter(matching_id: matching_id).to_a
          Matchings.unmatch!(matching_id, actor)
        end
        number = payload["number"]?.to_s
        label = "#{I18n.t("accounting.billing.rejection_label")} #{number}".strip
        posted = AccApi.post_financial(actor, AccApi::FinancialInput.new(
          ledger_id: entry.ledger_id.as(Int).to_i64, date: date, source: source,
          lines: [AccApi::PaymentLineInput.new(amount: -amount, card: customer.code, label: label,
            match_line_ids: [line.pk!.as(Int64)])],
        ))
        return result.failure(posted.errors) if posted.failure?
        ids = posted.value!.map(&.id)
        rematch(actor, group.reject { |other| other.pk == line.pk })
        fees = decimal(payload["fees"]?)
        if fees > 0
          account = DefaultAccount.filter(code: "bank_fees").first.try(&.account)
          return result.failure(FieldError.base("accounting.errors.billing.rejection.no_fees_account")) unless account
          charged = AccApi.post_financial(actor, AccApi::FinancialInput.new(
            ledger_id: entry.ledger_id.as(Int).to_i64, date: date, source: "#{source}:fees",
            lines: [AccApi::PaymentLineInput.new(amount: -fees, account: account.number.to_s,
              label: "#{I18n.t("accounting.billing.rejection_fees_label")} #{number}".strip)],
          ))
          return result.failure(charged.errors) if charged.failure?
          ids.concat(charged.value!.map(&.id))
        end
        result.success(ids)
      end

      # Ligne du client de l'encaissement rejeté : celle de l'écriture
      # `payment:<id>` (règlement saisi dans la Facturation), sinon, parmi
      # les lignes de journaux financiers lettrées avec la facture, au crédit
      # du client, celle de ce montant — de la date du règlement de
      # préférence, la plus récente sinon.
      private def self.rejected_line(payload : Hash(String, String), customer_id : Int64, amount : BigDecimal) : EntryLine?
        account_id = CardAccount.filter(card_id: customer_id).first.try(&.account_id)
        if payload["source"]? == "manual"
          entry = live_entries(["payment:#{payload["payment_id"]?}"]).first || return
          return EntryLine.filter(entry_id: entry.pk).to_a.find { |line| line.card_id == customer_id && line.account_id == account_id }
        end
        invoice = sale_entry("invoice:#{payload["invoice_id"]?}") || return
        matching_id = third_party_line(invoice, customer_id).try(&.matching_id) || return
        financial = Ledger.filter(kind: "financial").map(&.pk!.as(Int64)).to_set
        candidates = EntryLine.filter(matching_id: matching_id, side: "credit").to_a.select do |line|
          entry = Entry.filter(id: line.entry_id).first
          entry && financial.includes?(entry.ledger_id.as(Int).to_i64) && (line.currency_amount || line.amount!) == amount
        end
        paid_on = parse_date(payload["paid_on"]?)
        candidates.max_by? do |line|
          entry = Entry.filter(id: line.entry_id).first!
          {entry.date == paid_on ? 1 : 0, line.pk!.as(Int64)}
        end
      end

      # Relettre ce qui reste d'un lettrage défait (autres règlements de la
      # facture), s'il y a encore un débit et un crédit.
      private def self.rematch(actor : Partiduo::Api::Actor, lines : Array(EntryLine)) : Nil
        return if lines.size < 2
        checked, errors = Matchings.validate(lines.map(&.pk!.as(Int64)))
        Matchings.match!(actor, checked) if errors.empty?
      end

      # --- Entrées ---------------------------------------------------------------------

      # Facture (ou facture d'acompte) et avoir de vente depuis la charge utile.
      def self.document_input(name : String, payload : Hash(String, String), source : String,
                              errors : Array(FieldError)) : AccApi::DocumentInput?
        credit = name == "credit_note.issued"
        ledger = sales_ledger
        if ledger.nil?
          errors << FieldError.base("accounting.errors.billing.no_sale_ledger")
          return
        end
        customer = customer(payload["customer_card_id"]?, errors)
        date = parse_date(payload["issue_date"]?)
        errors << FieldError.new("date", "accounting.errors.billing.date_missing") if date.nil?
        sign = credit ? BigDecimal.new(-1) : BigDecimal.new(1)

        lines = [] of AccApi::DocumentLineInput
        vat_by_rate = {} of String => BigDecimal
        json_rows(payload["sales"]?).each do |row|
          amount = decimal(row["amount"]?) * sign
          rate = rate_code(row["vat_rate_id"]?, errors)
          account, item = item_target(row["item_card_id"]?, ledger, errors)
          lines << AccApi::DocumentLineInput.new(amount: amount, item: item, account: account, vat_rate: rate)
        end
        json_rows(payload["vat"]?).each do |row|
          amount = decimal(row["amount"]?) * sign
          next if amount.zero?
          rate = rate_code(row["vat_rate_id"]?, errors) || next
          vat_by_rate[rate] = vat_by_rate.fetch(rate, BigDecimal.new(0)) + amount
        end
        deduct_deposits(payload["deposit_sources"]?, lines, vat_by_rate, errors) unless credit
        return unless errors.empty? && customer && date

        number = payload["number"]?.to_s
        AccApi::DocumentInput.new(
          ledger_id: ledger.pk!.as(Int64), date: date, third_party: customer.code,
          lines: assign_vat(lines, vat_by_rate, ledger), label: "#{number} #{customer.name}".strip,
          receipt: receipt_for(ledger, number, source), due_date: parse_date(payload["due_date"]?),
          currency_code: payload["currency"]?.presence, source: source,
        )
      end

      # Encaissement depuis la charge utile de `payment.recorded`.
      def self.payment_input(payload : Hash(String, String), source : String,
                             errors : Array(FieldError)) : AccApi::FinancialInput?
        ledger = financial_ledger(payload["method"]?.to_s)
        if ledger.nil?
          errors << FieldError.base("accounting.errors.billing.no_financial_ledger")
          return
        end
        customer = customer(payload["customer_card_id"]?, errors)
        date = parse_date(payload["paid_on"]?)
        errors << FieldError.new("date", "accounting.errors.billing.date_missing") if date.nil?
        amount = decimal(payload["amount"]?)
        return unless errors.empty? && customer && date

        # Lettrage avec la ligne client de la facture, si elle est comptabilisée
        # sur le compte du client.
        invoice = sale_entry("invoice:#{payload["invoice_id"]?}")
        line = invoice.try { |found| third_party_line(found, customer.id) }
        account = CardAccount.filter(card_id: customer.id).first.try(&.account_id)
        match = line && line.account_id == account ? [line.pk!.as(Int64)] : [] of Int64
        AccApi::FinancialInput.new(
          ledger_id: ledger.pk!.as(Int64), date: date, source: source,
          lines: [AccApi::PaymentLineInput.new(amount: amount, card: customer.code,
            label: payload["number"]?.to_s, match_line_ids: match)],
        )
      end

      # --- Outils ------------------------------------------------------------------------

      # Pièce de l'écriture : le numéro du document. S'il est déjà pris par
      # l'écriture *extournée* de la même référence (comptabilisation
      # refaite), `<numéro>-2`, `-3`… ; pris par une autre écriture (pièce
      # saisie à la main), il reste tel quel et l'événement reste proposé
      # (`receipt.taken`), à écarter au besoin (D-2F-010).
      def self.receipt_for(ledger : Ledger, number : String, source : String) : String?
        return if number.empty?
        taken = Entry.filter(ledger_id: ledger.pk, receipt: number).first
        return number if taken.nil? || taken.source != source || !taken.reversed
        (2..99).each do |index|
          candidate = "#{number}-#{index}"
          return candidate unless Entry.filter(ledger_id: ledger.pk, receipt: candidate).exists?
        end
        number
      end

      # Premier journal de ventes actif.
      def self.sales_ledger : Ledger?
        Ledger.filter(kind: "sale", enabled: true).order(:id).first
      end

      # Journal financier : la caisse (compte sous le compte par défaut
      # `cash`) pour un règlement en espèces, une banque sinon ; à défaut, le
      # premier journal financier actif.
      def self.financial_ledger(method : String) : Ledger?
        ledgers = Ledger.filter(kind: "financial", enabled: true).order(:id).to_a
        cash = DefaultAccount.filter(code: "cash").first.try(&.account).try(&.number).to_s
        is_cash = ->(ledger : Ledger) do
          number = Ledgers.account_of(ledger).try(&.number).to_s
          !cash.empty? && number.starts_with?(cash)
        end
        preferred = method == "cash" ? ledgers.find(&is_cash) : ledgers.find { |ledger| !is_cash.call(ledger) }
        preferred || ledgers.first?
      end

      # Fiche client, rattachée à son compte (la fiche créée pendant que la
      # Comptabilité était inactive n'en a pas encore, D-ACC-006).
      private def self.customer(id : String?, errors : Array(FieldError)) : Partiduo::Api::Cards::CardView?
        card = id.try(&.to_i64?).try { |value| CardAccounts.card(Partiduo::Api::Actor.system, value) }
        if card.nil?
          errors << FieldError.new("third_party", "accounting.errors.billing.customer_not_found", {"id" => id.to_s})
          return
        end
        CardAccounts.on_card_saved(card.id)
        card
      end

      # Compte de vente d'une part : celui de la fiche article (rattachée au
      # besoin), sinon le compte par défaut du journal, sinon `sales`.
      # Renvoie {compte, quick code de l'article}.
      private def self.item_target(id : String?, ledger : Ledger, errors : Array(FieldError)) : {String?, String?}
        if card_id = id.try(&.to_i64?)
          if card = CardAccounts.card(Partiduo::Api::Actor.system, card_id)
            CardAccounts.on_card_saved(card_id)
            account = CardAccount.filter(card_id: card_id).first.try(&.account)
            return {nil, card.code} if account && account.direct_use && card.enabled
          end
        end
        fallback = ledger.default_account || DefaultAccount.filter(code: "sales").first.try(&.account)
        if fallback.nil?
          errors << FieldError.new("lines", "accounting.errors.billing.no_sales_account")
          return {nil, nil}
        end
        {fallback.number.to_s, nil}
      end

      private def self.rate_code(id : String?, errors : Array(FieldError)) : String?
        rate_id = id.try(&.to_i64?)
        return if rate_id.nil?
        Partiduo::Api::Vat.rate(Partiduo::Api::Actor.system, rate_id).code
      rescue Partiduo::Api::NotFound
        errors << FieldError.new("lines", "accounting.errors.billing.vat_rate_not_found", {"id" => id.to_s})
        nil
      end

      # Acomptes déduits : les lignes de vente et de TVA de leur écriture sont
      # extournées sur la facture finale, dont le client ne porte plus que le
      # solde (TTC − acomptes).
      private def self.deduct_deposits(sources : String?, lines : Array(AccApi::DocumentLineInput),
                                       vat_by_rate : Hash(String, BigDecimal), errors : Array(FieldError)) : Nil
        sources.to_s.split(',').map(&.strip).reject(&.empty?).each do |source|
          entry = sale_entry(source)
          if entry.nil?
            errors << FieldError.base("accounting.errors.billing.deposit_not_posted", {"source" => source})
            next
          end
          third = third_party_line(entry, nil)
          EntryLine.filter(entry_id: entry.pk).order(:position).each do |line|
            next if third && line.pk == third.pk
            value = line.currency_amount || line.amount!
            signed = line.side == "credit" ? value : -value
            rate = line.vat_rate_id.try { |rate_id| rate_code(rate_id.to_s, errors) }
            if line.vat_role == "tax"
              next if rate.nil?
              vat_by_rate[rate] = vat_by_rate.fetch(rate, BigDecimal.new(0)) - signed
            else
              account = line.account!.number.to_s
              lines << AccApi::DocumentLineInput.new(amount: -signed, account: account,
                vat_rate: line.vat_role == "base" ? rate : nil, label: entry.receipt.to_s)
            end
          end
        end
      end

      # TVA de chaque taux portée par la première ligne du taux, zéro sur les
      # autres : l'écriture reprend exactement la TVA de la facture.
      private def self.assign_vat(lines : Array(AccApi::DocumentLineInput), vat_by_rate : Hash(String, BigDecimal),
                                  ledger : Ledger) : Array(AccApi::DocumentLineInput)
        remaining = vat_by_rate.dup
        result = lines.map do |line|
          rate = line.vat_rate
          next line if rate.nil?
          line.copy_with(vat_amount: remaining.delete(rate) || BigDecimal.new(0))
        end
        remaining.each do |rate, amount|
          account = ledger.default_account || DefaultAccount.filter(code: "sales").first.try(&.account)
          result << AccApi::DocumentLineInput.new(amount: BigDecimal.new(0), account: account.try(&.number).to_s,
            vat_rate: rate, vat_amount: amount)
        end
        result
      end

      # Écriture de vente en vigueur portant la référence `source`.
      def self.sale_entry(source : String) : Entry?
        sale_ids = Ledger.filter(kind: "sale").map(&.pk!.as(Int64))
        live_entries([source]).filter(ledger_id__in: sale_ids).order(:id).first
      end

      # Ligne du tiers d'une écriture de vente : la dernière ligne, hors
      # TVA, de la fiche du client (`Documents` la place en dernier).
      def self.third_party_line(entry : Entry | Int64, card_id : Int64?) : EntryLine?
        entry_id = entry.is_a?(Entry) ? entry.pk!.as(Int64) : entry
        lines = EntryLine.filter(entry_id: entry_id).order(:position).to_a
        candidates = lines.select { |line| line.vat_role.nil? && (card_id.nil? || line.card_id == card_id) }
        candidates.last? || lines.last?
      end

      # Lettre deux lignes d'un même compte si elles le permettent.
      private def self.match_open(actor : Partiduo::Api::Actor, first : EntryLine?, second : EntryLine?) : Nil
        return if first.nil? || second.nil? || first.account_id != second.account_id
        lines, errors = Matchings.validate([first.pk!.as(Int64), second.pk!.as(Int64)])
        Matchings.match!(actor, lines) if errors.empty?
      end

      private def self.json_rows(text : String?) : Array(Hash(String, String?))
        return [] of Hash(String, String?) if text.nil? || text.strip.empty?
        JSON.parse(text).as_a.map do |row|
          row.as_h.transform_values { |value| value.raw.nil? ? nil : (value.as_s? || value.to_s) }
        end
      end

      private def self.decimal(text : String?) : BigDecimal
        text.try(&.strip).presence.try { |value| BigDecimal.new(value) } || BigDecimal.new(0)
      end

      private def self.parse_date(text : String?) : Time?
        value = text.try(&.strip).presence
        value.try { |date| Time.parse_utc(date, "%Y-%m-%d") }
      rescue Time::Format::Error
        nil
      end
    end
  end
end
