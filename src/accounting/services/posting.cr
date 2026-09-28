# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Accounting
    # Création d'une écriture : contrôle de l'en-tête (journal, période,
    # pièce, devise), résolution des comptes et des fiches, puis écriture en
    # base. Héritier de `Acc_Ledger::verify_operation`, `Acc_Ledger::save`,
    # `Acc_Operation::insert_jrnx` / `insert_jrn` et de `comptaproc.insert_jrnx`.
    #
    # C'est le *seul* chemin d'écriture (`create!`), appelé par le contrat
    # (`post_entry`, `post_purchase`, `post_sale`, `post_financial`,
    # `cancel_entry`) ; les requêtes de contrôle appellent les mêmes règles
    # sans écrire. Service interne.
    module Posting
      alias FieldError = Partiduo::Api::FieldError
      alias Side = Partiduo::Api::Accounting::Side

      MAX_RECEIPT =  40
      MAX_SOURCE  = 100

      # En-tête résolu d'une écriture.
      record Header,
        ledger : Ledger,
        date : Time,
        period_id : Int64,
        due_date : Time?,
        receipt : String?,
        currency_code : String,
        currency_rate : BigDecimal,
        base_currency : Bool,
        decimals : Int32,
        attachment_id : Int64?,
        source : String

      # Ligne prête à écrire : montant en devise de tenue, positif.
      record DraftLine,
        account : Account,
        side : Side,
        amount : BigDecimal,
        currency_amount : BigDecimal? = nil,
        card_id : Int64? = nil,
        card_code : String? = nil,
        label : String = "",
        vat_rate_id : Int64? = nil,
        vat_rate_code : String? = nil,
        vat_role : String? = nil,
        quantity : BigDecimal? = nil,
        input_index : Int32? = nil

      # Écriture prête à écrire.
      class Draft
        getter header : Header
        getter label : String
        getter lines : Array(DraftLine)
        property reversal_of_id : Int64? = nil
        property excluding_vat : BigDecimal = BigDecimal.new(0)
        property vat : BigDecimal = BigDecimal.new(0)
        # Facture d'achat ou de vente : toutes taxes comprises dans la devise
        # de l'écriture, signé côté article (négatif pour un avoir).
        property document_total : BigDecimal? = nil

        def initialize(@header : Header, @label : String, @lines : Array(DraftLine))
        end

        def total(side : Side) : BigDecimal
          lines.select { |line| line.side == side }.sum(BigDecimal.new(0), &.amount)
        end
      end

      # Compte ou fiche résolus pour une ligne.
      record Target, account : Account, card_id : Int64? = nil, card_code : String? = nil

      # Date sans heure (minuit UTC, convention C1).
      def self.day(time : Time) : Time
        Time.utc(time.year, time.month, time.day)
      end

      # --- En-tête ---------------------------------------------------------------

      # Journal où l'acteur peut écrire (`check_jrn` = `W`) ; `NotFound` s'il
      # n'existe pas, `Forbidden` sans droit d'écriture.
      def self.writable_ledger(actor : Partiduo::Api::Actor, ledger_id : Int64) : Ledger
        ledger = Ledger.filter(id: ledger_id).first || raise Partiduo::Api::NotFound.new("ledger", ledger_id)
        unless Ledgers.access(actor, ledger_id).writable?
          raise Partiduo::Api::Forbidden.new("accounting.entry.post")
        end
        ledger
      end

      # Contrôles de l'en-tête (`verify_operation` : date, période fermée,
      # devise et cours ; `update_receipt` : pièce unique dans le journal).
      def self.header(ledger : Ledger, date : Time, due_date : Time?, receipt : String?,
                      currency_code : String?, currency_rate : BigDecimal?, attachment_id : Int64?,
                      source : String, errors : Array(FieldError), date_field : String = "date",
                      receipt_field : String = "receipt") : Header?
        day = Posting.day(date)
        errors << FieldError.new("ledger_id", "accounting.errors.entry.ledger.disabled") unless ledger.enabled
        period_id = period_errors(day, errors, date_field)
        receipt = receipt_errors(ledger, receipt, receipt_field, errors)
        source = source.strip
        reference_errors(source, attachment_id, errors)
        code, rate, base = currency(ledger, currency_code, currency_rate, day, errors)

        return unless errors.empty? && period_id
        Header.new(
          ledger: ledger, date: day, period_id: period_id, due_date: due_date.try { |value| Posting.day(value) },
          receipt: receipt, currency_code: code, currency_rate: rate, base_currency: base,
          decimals: base_currency.try(&.decimals) || 2, attachment_id: attachment_id, source: source,
        )
      end

      # Pièce saisie (nettoyée) : longueur, unique dans le journal.
      private def self.receipt_errors(ledger : Ledger, receipt : String?, field : String,
                                      errors : Array(FieldError)) : String?
        value = receipt.to_s.strip.presence
        return if value.nil?
        if value.size > MAX_RECEIPT
          errors << FieldError.new(field, "accounting.errors.entry.receipt.too_long", {"max" => MAX_RECEIPT.to_s})
        elsif Entry.filter(ledger_id: ledger.pk, receipt: value).exists?
          errors << FieldError.new(field, "accounting.errors.entry.receipt.taken", {"receipt" => value})
        end
        value
      end

      private def self.reference_errors(source : String, attachment_id : Int64?, errors : Array(FieldError)) : Nil
        if source.size > MAX_SOURCE
          errors << FieldError.new("source", "accounting.errors.entry.source.too_long", {"max" => MAX_SOURCE.to_s})
        end
        if attachment_id && !attachment_exists?(attachment_id)
          errors << FieldError.new("attachment_id", "accounting.errors.entry.attachment.not_found")
        end
      end

      # Devise de l'écriture (celle du journal par défaut) et cours : 1 pour
      # la devise de tenue, sinon le cours saisi ou celui du socle à la date.
      private def self.currency(ledger : Ledger, currency_code : String?, currency_rate : BigDecimal?, day : Time,
                                errors : Array(FieldError)) : {String, BigDecimal, Bool}
        system = Partiduo::Api::Actor.system
        code = currency_code.try(&.strip.upcase).presence || ledger.currency_code.to_s
        currency = begin
          Partiduo::Api::Core.currency(system, code)
        rescue Partiduo::Api::NotFound
          errors << FieldError.new("currency_code", "accounting.errors.ledger.currency_code.unknown", {"code" => code})
          return {code, BigDecimal.new(1), true}
        end
        return {code, BigDecimal.new(1), true} if currency.base
        rate = currency_rate || Partiduo::Api::Core.rate_on(system, code, day) || BigDecimal.new(0)
        if rate <= 0
          errors << FieldError.new("currency_rate", "accounting.errors.entry.currency_rate.missing", {"code" => code})
        end
        {code, rate, false}
      end

      # Période ouverte contenant la date (`find_periode`, `is_closed`).
      def self.period_errors(day : Time, errors : Array(FieldError), field : String = "date") : Int64?
        period = Partiduo::Api::Core.period_for(Partiduo::Api::Actor.system, day)
        if period.nil?
          errors << FieldError.new(field, "accounting.errors.entry.date.no_period", {"date" => day.to_s("%Y-%m-%d")})
          return
        end
        if period.closed? || Partiduo::Api::Core.fiscal_year(Partiduo::Api::Actor.system, period.fiscal_year_id).closed?
          errors << FieldError.new(field, "accounting.errors.entry.date.period_closed", {"date" => day.to_s("%Y-%m-%d")})
          return
        end
        period.id
      end

      def self.base_currency : Partiduo::Api::Core::CurrencyView?
        Partiduo::Api::Core.base_currency(Partiduo::Api::Actor.system)
      rescue Partiduo::Api::NotFound
        nil
      end

      private def self.attachment_exists?(id : Int64) : Bool
        Partiduo::Api::Core.attachment(Partiduo::Api::Actor.system, id)
        true
      rescue Partiduo::Api::NotFound
        false
      end

      # --- Comptes et fiches ---------------------------------------------------

      # Compte existant et utilisable directement (`pcm_direct_use`).
      def self.account(number : String, field : String, errors : Array(FieldError)) : Account?
        normalized = Chart.normalize(number)
        account = Account.filter(number: normalized).first
        if account.nil?
          errors << FieldError.new(field, "accounting.errors.entry.account.not_found", {"number" => normalized})
        elsif !account.direct_use
          errors << FieldError.new(field, "accounting.errors.entry.account.not_direct_use", {"number" => normalized})
          return
        end
        account
      end

      # Fiche active rattachée à un compte utilisable (`verify_operation` :
      # « fiche plus utilisée », « pas de poste comptable »).
      def self.card(code : String, field : String, errors : Array(FieldError)) : Target?
        card = Partiduo::Api::Cards.card_by_code(Partiduo::Api::Actor.system, code.strip)
        if card.nil?
          errors << FieldError.new(field, "accounting.errors.entry.card.not_found", {"code" => code.strip.upcase})
          return
        end
        unless card.enabled
          errors << FieldError.new(field, "accounting.errors.entry.card.disabled", {"code" => card.code})
          return
        end
        account = CardAccount.filter(card_id: card.id).first.try(&.account)
        if account.nil?
          errors << FieldError.new(field, "accounting.errors.entry.card.no_account", {"code" => card.code})
          return
        end
        unless account.direct_use
          errors << FieldError.new(field, "accounting.errors.entry.account.not_direct_use", {"number" => account.number.to_s})
          return
        end
        Target.new(account, card.id, card.code)
      end

      # Montant saisi : au plus quatre décimales (colonnes `decimal(20, 4)`).
      def self.decimals_ok?(amount : BigDecimal) : Bool
        amount.scale <= EntryBalance::MAX_DECIMALS || amount == amount.round(EntryBalance::MAX_DECIMALS)
      end

      # Montant en devise de tenue : montant ÷ cours, arrondi aux décimales
      # de la devise de tenue (`bcdiv` puis `round(…, 2)`).
      def self.to_base(header : Header, amount : BigDecimal) : BigDecimal
        return amount if header.base_currency
        (amount / header.currency_rate).round(header.decimals, mode: :ties_away)
      end

      # Ligne signée (montant négatif : sens inversé, `insert_jrnx`) ; `nil`
      # pour un montant nul.
      def self.signed_line(side : Side, amount : BigDecimal, currency_amount : BigDecimal?, target : Target,
                           **options) : DraftLine?
        return if amount.zero?
        real_side = amount < 0 ? side.opposite : side
        DraftLine.new(account: target.account, side: real_side, amount: amount.abs,
          currency_amount: currency_amount.try(&.abs), card_id: target.card_id, card_code: target.card_code)
          .copy_with(**options)
      end

      # --- Écriture générique (`Acc_Ledger::save`) ------------------------------

      def self.generic(actor : Partiduo::Api::Actor, input : Partiduo::Api::Accounting::EntryInput,
                       ledger : Ledger) : {Draft?, Array(FieldError)}
        errors = [] of FieldError
        header = header(ledger, input.date, input.due_date, input.receipt, input.currency_code,
          input.currency_rate, input.attachment_id, input.source, errors)
        line_errors = line_errors(input.lines)
        targets = input.lines.map_with_index do |line, index|
          target(line, "lines[#{index}]", line_errors)
        end
        errors.concat(line_errors)
        return {nil, errors} unless errors.empty? && header

        lines = input.lines.zip(targets.compact).map_with_index do |(line, target), index|
          DraftLine.new(account: target.account, side: line.side, amount: to_base(header, line.amount),
            currency_amount: header.base_currency ? nil : line.amount, card_id: target.card_id,
            card_code: target.card_code, label: line.label.strip, input_index: index)
        end
        balance_rounding!(lines)
        {Draft.new(header, input.label.strip, lines), errors}
      end

      # Règles d'équilibre et de montant (`EntryBalance`), puis compte ou fiche
      # manquant (`account_missing`).
      def self.line_errors(lines : Array(Partiduo::Api::Accounting::EntryLineInput)) : Array(FieldError)
        balance_lines = lines.map { |line| EntryBalance::Line.new(line.side.debit? ? :debit : :credit, line.amount) }
        errors = EntryBalance.errors(balance_lines)
        lines.each_with_index do |line, index|
          if line.account.strip.empty? && line.card.try(&.strip).presence.nil?
            errors.unshift(FieldError.new("lines[#{index}].account", "accounting.errors.entry.account_missing"))
          end
        end
        errors
      end

      private def self.target(line : Partiduo::Api::Accounting::EntryLineInput, path : String,
                              errors : Array(FieldError)) : Target?
        if code = line.card.try(&.strip).presence
          target = card(code, "#{path}.card", errors)
          return target if target.nil? || line.account.strip.empty?
          # Compte et fiche donnés : le compte l'emporte, la fiche est citée.
          account(line.account, "#{path}.account", errors).try { |found| Target.new(found, target.card_id, target.card_code) }
        elsif !line.account.strip.empty?
          account(line.account, "#{path}.account", errors).try { |found| Target.new(found) }
        end
      end

      # Écart d'arrondi de conversion en devise de tenue reporté sur la plus
      # grande ligne du côté le plus faible (l'application d'origine passe une ligne
      # « différence de change », D-ACC-013).
      def self.balance_rounding!(lines : Array(DraftLine)) : Nil
        debit = lines.select(&.side.debit?).sum(BigDecimal.new(0), &.amount)
        credit = lines.select(&.side.credit?).sum(BigDecimal.new(0), &.amount)
        difference = debit - credit
        return if difference.zero?
        side = difference > 0 ? Side::Credit : Side::Debit
        index = lines.each_index.select { |i| lines[i].side == side }.max_by? { |i| lines[i].amount }
        return if index.nil?
        lines[index] = lines[index].copy_with(amount: lines[index].amount + difference.abs)
      end

      # --- Enregistrement ------------------------------------------------------

      # Écrit l'écriture et ses lignes dans la transaction ouverte, réserve la
      # pièce si elle n'est pas donnée, calcule le code interne et publie
      # `entry.posted`.
      def self.create!(actor : Partiduo::Api::Actor, draft : Draft) : Entry
        header = draft.header
        ledger_id = header.ledger.pk!.as(Int64)
        receipt = header.receipt || free_receipt!(ledger_id)
        entry = Entry.new(
          ledger: header.ledger, period_id: header.period_id, date: header.date, due_date: header.due_date,
          label: draft.label, receipt: receipt, amount: draft.total(Side::Debit),
          currency_code: header.currency_code, currency_rate: header.currency_rate,
          reversal_of_id: draft.reversal_of_id, attachment_id: header.attachment_id, source: header.source,
          created_by_id: actor.user_id,
        )
        entry.save!
        id = entry.pk!.as(Int64)
        entry.internal_code = internal_code(header.ledger, id)
        entry.save!
        draft.lines.each_with_index do |line, position|
          EntryLine.new(
            entry: entry, position: position, account: line.account, card_id: line.card_id,
            side: line.side.code, amount: line.amount, currency_amount: line.currency_amount, label: line.label,
            vat_rate_id: line.vat_rate_id, vat_role: line.vat_role, quantity: line.quantity,
            input_index: line.input_index,
          ).save!
        end
        payload = {"entry_id" => id.to_s, "ledger_code" => header.ledger.code.to_s}
        draft.reversal_of_id.try { |original| payload["reversal_of"] = original.to_s }
        header.source.presence.try { |source| payload["source"] = source }
        verify_balance!
        Partiduo::Events.publish("entry.posted", payload, actor_user_id: actor.user_id)
        entry
      end

      # Nombre de numéros essayés avant d'abandonner (`update_receipt` : `$limit`).
      RECEIPT_ATTEMPTS = 100

      # Numéro de pièce suivant du journal encore libre : un numéro déjà pris
      # par une pièce saisie est sauté (`Acc_Operation::update_receipt`,
      # « try another seq »), D-TST-001.
      private def self.free_receipt!(ledger_id : Int64) : String
        RECEIPT_ATTEMPTS.times do
          receipt = Receipts.take!(ledger_id)
          return receipt unless Entry.filter(ledger_id: ledger_id, receipt: receipt).exists?
        end
        raise "aucun numéro de pièce libre dans le journal #{ledger_id}"
      end

      # Joue aussitôt les contrôles différés de l'équilibre
      # (`accounting_entry_balance`) : une écriture déséquilibrée lève une
      # exception dans la commande, qui annule sa transaction, au lieu d'un
      # `COMMIT` en échec (B-ACC-002). Les contrôles restent différés pour la
      # suite de la transaction.
      def self.verify_balance! : Nil
        Marten::DB::Connection.default.open do |db|
          db.exec("SET CONSTRAINTS accounting_entry_balance, accounting_entry_line_balance IMMEDIATE")
          db.exec("SET CONSTRAINTS accounting_entry_balance, accounting_entry_line_balance DEFERRED")
        end
      end

      # Code interne (`compute_internal_code` : initiale du code du journal et
      # numéro hexadécimal sur six chiffres).
      def self.internal_code(ledger : Ledger, id : Int64) : String
        "#{ledger.code.to_s[0]? || 'X'}#{id.to_s(16).upcase.rjust(6, '0')}"
      end
    end
  end
end
