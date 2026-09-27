# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Accounting
    # Extraits financiers, héritiers de `Acc_Ledger_Fin::insert` : chaque ligne
    # de l'extrait devient *une écriture* (banque contre contrepartie), avec
    # sa pièce ; un montant positif est une entrée en banque (banque au débit,
    # contrepartie au crédit), un montant négatif une sortie. La banque est la
    # fiche du journal (`jrn_def_bank`, D-ACC-010). Les lignes « concernées »
    # (`e_concerned`) sont lettrées avec la contrepartie. Service interne.
    module Financial
      alias FieldError = Partiduo::Api::FieldError
      alias Side = Partiduo::Api::Accounting::Side

      # Écriture d'une ligne et lignes à lettrer avec sa contrepartie.
      record Planned, draft : Posting::Draft, match_line_ids : Array(Int64)

      def self.build(input : Partiduo::Api::Accounting::FinancialInput, ledger : Ledger) : {Array(Planned), Array(FieldError)}
        errors = [] of FieldError
        unless ledger.kind == "financial"
          errors << FieldError.new("ledger_id", "accounting.errors.entry.ledger.not_financial", {"code" => ledger.code.to_s})
          return {[] of Planned, errors}
        end
        bank = bank(ledger, errors)
        errors << FieldError.base("accounting.errors.entry.no_items") if input.lines.empty?
        return {[] of Planned, errors} unless errors.empty? && bank

        planned = [] of Planned
        input.lines.each_with_index do |line, index|
          path = "lines[#{index}]"
          line_errors = [] of FieldError
          receipt = receipt(input, index)
          header = Posting.header(ledger, line.date || input.date, nil, receipt, input.currency_code,
            input.currency_rate, input.attachment_id, input.source, line_errors,
            date_field: line.date ? "#{path}.date" : "date", receipt_field: "receipt")
          amount_errors(line, path, line_errors)
          counterpart = counterpart(line, path, line_errors)
          match_errors(line, counterpart, path, line_errors) if counterpart
          errors.concat(line_errors.reject { |error| errors.includes?(error) })
          next unless line_errors.empty? && header && counterpart

          base = Posting.to_base(header, line.amount)
          currency = header.base_currency ? nil : line.amount
          label = line.label.strip
          lines = [
            Posting.signed_line(Side::Credit, base, currency, counterpart, label: label),
            Posting.signed_line(Side::Debit, base, currency, bank, label: label),
          ].compact
          planned << Planned.new(Posting::Draft.new(header, label, lines), line.match_line_ids.uniq)
        end
        {planned, errors}
      end

      # Pièce de la ligne : celle de l'extrait, suffixée du rang sur trois
      # chiffres s'il compte plusieurs lignes (`$e_pj.str_pad($idx, 3)`).
      private def self.receipt(input : Partiduo::Api::Accounting::FinancialInput, index : Int32) : String?
        receipt = input.receipt.try(&.strip).presence
        return if receipt.nil?
        input.lines.size == 1 ? receipt : "#{receipt}#{(index + 1).to_s.rjust(3, '0')}"
      end

      # Fiche Banque du journal et son compte.
      def self.bank(ledger : Ledger, errors : Array(FieldError)) : Posting::Target?
        card_id = ledger.bank_card_id.try(&.to_i64)
        account = Ledgers.account_of(ledger)
        if card_id.nil? || account.nil?
          errors << FieldError.new("ledger_id", "accounting.errors.ledger.bank_card.no_account", {"code" => ledger.code.to_s})
          return
        end
        code = begin
          Partiduo::Api::Cards.card(Partiduo::Api::Actor.system, card_id).code
        rescue Partiduo::Api::NotFound
          nil
        end
        Posting::Target.new(account, card_id, code)
      end

      private def self.amount_errors(line : Partiduo::Api::Accounting::PaymentLineInput, path : String,
                                     errors : Array(FieldError)) : Nil
        if line.amount.zero?
          errors << FieldError.new("#{path}.amount", "accounting.errors.entry.amount_zero")
        elsif !Posting.decimals_ok?(line.amount)
          errors << FieldError.new("#{path}.amount", "accounting.errors.entry.too_many_decimals",
            {"max" => EntryBalance::MAX_DECIMALS.to_s})
        end
      end

      private def self.counterpart(line : Partiduo::Api::Accounting::PaymentLineInput, path : String,
                                   errors : Array(FieldError)) : Posting::Target?
        if code = line.card.try(&.strip).presence
          Posting.card(code, "#{path}.card", errors)
        elsif number = line.account.try(&.strip).presence
          Posting.account(number, "#{path}.account", errors).try { |account| Posting::Target.new(account) }
        else
          errors << FieldError.new("#{path}.card", "accounting.errors.entry.counterpart_missing")
          nil
        end
      end

      # Lignes à lettrer : existantes et du compte de la contrepartie.
      private def self.match_errors(line : Partiduo::Api::Accounting::PaymentLineInput, counterpart : Posting::Target,
                                    path : String, errors : Array(FieldError)) : Nil
        line.match_line_ids.uniq.each do |id|
          found = EntryLine.filter(id: id).first
          if found.nil?
            errors << FieldError.new("#{path}.match_line_ids", "accounting.errors.matching.line_not_found", {"id" => id.to_s})
          elsif found.account_id != counterpart.account.pk
            errors << FieldError.new("#{path}.match_line_ids", "accounting.errors.matching.different_accounts")
          end
        end
      end
    end
  end
end
