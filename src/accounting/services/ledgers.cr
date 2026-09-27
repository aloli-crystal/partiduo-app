# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Accounting
    # Règles des journaux, héritières de `Acc_Ledger::verify_ledger`,
    # `save_new`, `update` et `delete_ledger`. Service interne.
    module Ledgers
      alias FieldError = Partiduo::Api::FieldError
      alias LedgerKind = Partiduo::Api::Accounting::LedgerKind

      MAX_NAME        = 100
      MAX_CODE        =  10
      MAX_PREFIX      =  20
      MAX_PADDING     =  20
      CODE_FORMAT     = /\A[A-Z0-9]+\z/
      CURRENCY_FORMAT = /\A[A-Z]{3}\z/

      # Initiale du code attribué (`substr(jrn_def_type, 0, 1)`).
      INITIALS = {LedgerKind::Purchase => 'A', LedgerKind::Sale => 'V', LedgerKind::Financial => 'F', LedgerKind::Misc => 'O'}

      record Values, name : String, kind : LedgerKind, code : String?, description : String, enabled : Bool,
        default_account : Account?, receipt_prefix : String, receipt_padding : Int32,
        next_receipt_number : Int64?, currency_code : String, bank_card_id : Int64?

      # `actor` : l'appelant, pour vérifier la devise auprès du socle.
      def self.validate(actor : Partiduo::Api::Actor, input : Partiduo::Api::Accounting::LedgerInput,
                        current : Ledger? = nil) : {Values?, Array(FieldError)}
        errors = [] of FieldError
        current_id = current.try(&.pk)
        name = input.name.strip
        code = input.code.try(&.strip.upcase).presence
        prefix = input.receipt_prefix.strip
        currency = input.currency_code.try(&.strip.upcase).presence || base_currency(actor)

        name_errors(name, current_id, errors)
        code_errors(code, current_id, errors) if code
        account = input.kind.financial? ? nil : default_account(input, errors)
        bank_card_id = input.kind.financial? ? bank_card(input, errors) : nil
        numbering_errors(input, prefix, errors)
        currency_errors(actor, currency, errors)
        used_errors(input, currency, current, errors) if current

        return {nil, errors} unless errors.empty?
        {Values.new(name, input.kind, code, input.description.strip, input.enabled, account, prefix,
          input.receipt_padding, input.next_receipt_number, currency, bank_card_id), errors}
      end

      # Journal mouvementé : ni son type ni sa devise ne changent (D-ACC-004).
      private def self.used_errors(input : Partiduo::Api::Accounting::LedgerInput, currency : String, current : Ledger,
                                   errors : Array(FieldError)) : Nil
        return unless used?(current)
        if input.kind.code != current.kind
          errors << FieldError.new("kind", "accounting.errors.ledger.kind.in_use")
        end
        if currency != current.currency_code
          errors << FieldError.new("currency_code", "accounting.errors.ledger.currency_code.in_use")
        end
      end

      # Le journal porte-t-il des écritures ?
      def self.used?(ledger : Ledger) : Bool
        Entry.filter(ledger_id: ledger.pk).exists?
      end

      # Devise de tenue du dossier (`Partiduo::Api::Core.base_currency`), la
      # devise d'un journal qui n'en précise pas ; `EUR` si le socle n'en a pas.
      def self.base_currency(actor : Partiduo::Api::Actor) : String
        Partiduo::Api::Core.base_currency(actor).code
      rescue Partiduo::Api::NotFound
        "EUR"
      end

      # Fiche Banque d'un journal financier (`Acc_Ledger::verify_ledger` :
      # `jrn_def_bank` retrouvée par quick code), de nature `bank`, rattachée
      # à un compte utilisable directement — le compte du journal.
      private def self.bank_card(input : Partiduo::Api::Accounting::LedgerInput, errors : Array(FieldError)) : Int64?
        code = input.bank_card.try(&.strip).presence
        if code.nil?
          errors << FieldError.new("bank_card", "accounting.errors.ledger.bank_card.required")
          return
        end
        card = Partiduo::Api::Cards.card_by_code(Partiduo::Api::Actor.system, code)
        if card.nil?
          errors << FieldError.new("bank_card", "accounting.errors.ledger.bank_card.not_found", {"code" => code})
          return
        end
        unless card.kind == "bank"
          errors << FieldError.new("bank_card", "accounting.errors.ledger.bank_card.not_bank", {"code" => card.code})
          return
        end
        account = CardAccount.filter(card_id: card.id).first.try(&.account)
        if account.nil?
          errors << FieldError.new("bank_card", "accounting.errors.ledger.bank_card.no_account", {"code" => card.code})
        elsif !account.direct_use
          errors << FieldError.new("bank_card", "accounting.errors.ledger.bank_card.not_direct_use",
            {"code" => card.code, "number" => account.number.to_s})
        end
        card.id
      end

      # Compte d'un journal : celui de sa fiche Banque pour un journal
      # financier (déduit, pas stocké), sinon son compte par défaut.
      def self.account_of(ledger : Ledger) : Account?
        if card_id = ledger.bank_card_id
          CardAccount.filter(card_id: card_id).first.try(&.account)
        else
          ledger.default_account
        end
      end

      private def self.name_errors(name : String, current_id, errors : Array(FieldError)) : Nil
        if name.empty?
          errors << FieldError.new("name", "accounting.errors.ledger.name.blank")
        elsif name.size > MAX_NAME
          errors << FieldError.new("name", "accounting.errors.ledger.name.too_long", {"max" => MAX_NAME.to_s})
        elsif Ledger.filter(name: name).exclude(id: current_id).exists?
          errors << FieldError.new("name", "accounting.errors.ledger.name.taken")
        end
      end

      private def self.code_errors(code : String, current_id, errors : Array(FieldError)) : Nil
        if code.size > MAX_CODE || !code.matches?(CODE_FORMAT)
          errors << FieldError.new("code", "accounting.errors.ledger.code.invalid", {"max" => MAX_CODE.to_s})
        elsif Ledger.filter(code: code).exclude(id: current_id).exists?
          errors << FieldError.new("code", "accounting.errors.ledger.code.taken", {"code" => code})
        end
      end

      # Compte par défaut (facultatif) : existant et utilisable directement.
      private def self.default_account(input : Partiduo::Api::Accounting::LedgerInput,
                                       errors : Array(FieldError)) : Account?
        number = Chart.normalize(input.default_account || "")
        return if number.empty?
        account = Account.filter(number: number).first
        if account.nil?
          errors << FieldError.new("default_account", "accounting.errors.ledger.default_account.not_found", {"number" => number})
        elsif !account.direct_use
          errors << FieldError.new("default_account", "accounting.errors.ledger.default_account.not_direct_use", {"number" => number})
        end
        account
      end

      private def self.numbering_errors(input : Partiduo::Api::Accounting::LedgerInput, prefix : String,
                                        errors : Array(FieldError)) : Nil
        if prefix.size > MAX_PREFIX
          errors << FieldError.new("receipt_prefix", "accounting.errors.ledger.receipt_prefix.too_long", {"max" => MAX_PREFIX.to_s})
        end
        unless 0 <= input.receipt_padding <= MAX_PADDING
          errors << FieldError.new("receipt_padding", "accounting.errors.ledger.receipt_padding.invalid", {"max" => MAX_PADDING.to_s})
        end
        if (next_number = input.next_receipt_number) && next_number < 1
          errors << FieldError.new("next_receipt_number", "accounting.errors.ledger.next_receipt_number.invalid")
        end
      end

      private def self.currency_errors(actor : Partiduo::Api::Actor, currency : String, errors : Array(FieldError)) : Nil
        if !currency.matches?(CURRENCY_FORMAT)
          errors << FieldError.new("currency_code", "accounting.errors.ledger.currency_code.invalid")
        elsif !currency_known?(actor, currency)
          errors << FieldError.new("currency_code", "accounting.errors.ledger.currency_code.unknown", {"code" => currency})
        end
      end

      # Devise déclarée au socle (`Partiduo::Api::Core.currency`).
      def self.currency_known?(actor : Partiduo::Api::Actor, code : String) : Bool
        Partiduo::Api::Core.currency(actor, code)
        true
      rescue Partiduo::Api::NotFound
        false
      end

      def self.assign(ledger : Ledger, values : Values) : Ledger
        ledger.name = values.name
        ledger.kind = values.kind.code
        ledger.code = values.code || ledger.code.presence || generate_code(values.kind)
        ledger.description = values.description
        ledger.enabled = values.enabled
        ledger.default_account = values.default_account
        ledger.receipt_prefix = values.receipt_prefix
        ledger.receipt_padding = values.receipt_padding
        ledger.currency_code = values.currency_code
        ledger.bank_card_id = values.bank_card_id
        if next_number = values.next_receipt_number
          ledger.last_receipt_number = next_number - 1
        end
        ledger
      end

      # `Acc_Ledger::save_new` : initiale du type suivie du rang du journal
      # parmi ceux du même type, en base 36 sur deux caractères ; le rang est
      # augmenté jusqu'à trouver un code libre.
      def self.generate_code(kind : LedgerKind) : String
        rank = Ledger.filter(kind: kind.code).count + 1
        loop do
          code = "#{INITIALS[kind]}#{rank.to_s(36).upcase.rjust(2, '0')}"
          return code unless Ledger.filter(code: code).exists?
          rank += 1
        end
      end

      # Journaux visibles d'un acteur : ceux sur lesquels il a un droit de
      # lecture ou d'écriture (`Noalyss_user::get_ledger`) ; tous pour qui
      # administre les journaux (`accounting.ledger.write`).
      def self.access(actor : Partiduo::Api::Actor, ledger_id : Int64) : Partiduo::Api::Accounting::LedgerAccess
        Partiduo::Api::Accounting::LedgerAccess.from_code(Partiduo::Api::Auth.ledger_access(actor, ledger_id))
      end

      def self.visible?(actor : Partiduo::Api::Actor, access : Partiduo::Api::Accounting::LedgerAccess) : Bool
        access.readable? || actor.can?("accounting.ledger.write")
      end
    end

    # Numérotation des pièces d'un journal (`jrn_def_pj_pref`,
    # `jrn_def_pj_padding`, séquence `s_jrn_pj<id>` de NOALYSS). Le compteur
    # est une colonne du journal, verrouillée par `SELECT … FOR UPDATE` puis
    # incrémentée dans la transaction de l'écriture : une écriture annulée ne
    # consomme pas de numéro (pas de séquence PostgreSQL, convention C3).
    module Receipts
      def self.format(prefix : String, padding : Int32, number : Int64) : String
        "#{prefix}#{number.to_s.rjust(padding, '0')}"
      end

      # Réserve le numéro de pièce suivant. À appeler dans la transaction de
      # la commande qui l'utilise (saisie d'écriture, lot 2).
      def self.take!(ledger_id : Int64) : String
        receipt = nil
        Marten::DB::Connection.default.transaction do
          ledger = Ledger.filter(id: ledger_id).lock.first || raise Partiduo::Api::NotFound.new("ledger", ledger_id)
          number = ledger.last_receipt_number!.to_i64 + 1
          ledger.last_receipt_number = number
          ledger.save!
          receipt = format(ledger.receipt_prefix.to_s, ledger.receipt_padding!.to_i32, number)
        end
        receipt || raise "numérotation des pièces interrompue"
      end
    end
  end
end
