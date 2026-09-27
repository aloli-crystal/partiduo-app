# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Accounting
    # Factures et avoirs d'achat et de vente, héritiers de
    # `Acc_Ledger_Purchase::insert` et `Acc_Ledger_Sale::insert` : une ligne
    # par article (compte de la fiche, hors taxe), la TVA ventilée par taux sur
    # les comptes du taux (`tva_rate.tva_poste`, D-ACC-009), la contrepartie
    # toutes taxes comprises sur le compte du tiers. TVA autoliquidée
    # (`tva_both_side`) : passée au débit (déductible) *et* au crédit
    # (collectée), hors du montant du tiers.
    #
    # Non repris (D-ACC-012) : dépenses et TVA non déductibles, part privée,
    # autres taxes (`acc_other_tax`), paiement immédiat (`e_mp`), stock,
    # analytique. Service interne.
    module Documents
      alias FieldError = Partiduo::Api::FieldError
      alias Side = Partiduo::Api::Accounting::Side
      alias LedgerKind = Partiduo::Api::Accounting::LedgerKind

      # Montant en devise de l'écriture puis en devise de tenue.
      record Amount, currency : BigDecimal, base : BigDecimal

      # Ligne d'article et sa TVA, montants signés dans la devise de l'écriture.
      record ItemLine, index : Int32, target : Posting::Target, amount : BigDecimal, vat : BigDecimal,
        rate : Partiduo::Api::Vat::RateView?, label : String, quantity : BigDecimal?

      def self.build(input : Partiduo::Api::Accounting::DocumentInput, ledger : Ledger) : {Posting::Draft?, Array(FieldError)}
        errors = [] of FieldError
        kind = LedgerKind.from_code(ledger.kind.to_s)
        unless kind.purchase? || kind.sale?
          errors << FieldError.new("ledger_id", "accounting.errors.entry.ledger.not_document", {"code" => ledger.code.to_s})
          return {nil, errors}
        end

        header = Posting.header(ledger, input.date, input.due_date, input.receipt, input.currency_code,
          input.currency_rate, input.attachment_id, input.source, errors)
        third_party = third_party(input.third_party, errors)
        items = items(input, ledger, kind, errors)
        errors.concat(vat_account_errors(input, ledger))
        errors << FieldError.base("accounting.errors.entry.no_items") if errors.empty? && items.empty?
        return {nil, errors} unless errors.empty? && header && third_party

        {draft(header, kind, third_party, items, input.label.strip), errors}
      end

      private def self.third_party(code : String, errors : Array(FieldError)) : Posting::Target?
        if code.strip.empty?
          errors << FieldError.new("third_party", "accounting.errors.entry.third_party.required")
          return
        end
        Posting.card(code, "third_party", errors)
      end

      private def self.items(input : Partiduo::Api::Accounting::DocumentInput, ledger : Ledger, kind : LedgerKind,
                             errors : Array(FieldError)) : Array(ItemLine)
        items = [] of ItemLine
        input.lines.each_with_index do |line, index|
          path = "lines[#{index}]"
          amount = line_amount(line, path, errors)
          next if amount.nil?
          rate = vat_rate(line, kind, path, errors)
          vat = vat_amount(line, amount, rate, path, errors)
          next if vat.nil?
          # Ligne vide (`e_march<i>` sans quantité) : ignorée.
          next if amount.zero? && vat.zero?
          target = line_target(line, ledger, path, errors)
          next if target.nil?
          items << ItemLine.new(index, target, amount, vat, rate, line.label.strip, line.quantity)
        end
        items
      end

      # Hors taxe : `quantity × unit_price` arrondi au centime, sinon `amount`.
      private def self.line_amount(line : Partiduo::Api::Accounting::DocumentLineInput, path : String,
                                   errors : Array(FieldError)) : BigDecimal?
        if unit_price = line.unit_price
          quantity = line.quantity || BigDecimal.new(1)
          unless Posting.decimals_ok?(unit_price) && Posting.decimals_ok?(quantity)
            errors << FieldError.new("#{path}.unit_price", "accounting.errors.entry.too_many_decimals",
              {"max" => EntryBalance::MAX_DECIMALS.to_s})
            return
          end
          return (unit_price * quantity).round(2, mode: :ties_away)
        end
        unless Posting.decimals_ok?(line.amount)
          errors << FieldError.new("#{path}.amount", "accounting.errors.entry.too_many_decimals",
            {"max" => EntryBalance::MAX_DECIMALS.to_s})
          return
        end
        line.amount
      end

      private def self.vat_rate(line : Partiduo::Api::Accounting::DocumentLineInput, kind : LedgerKind, path : String,
                                errors : Array(FieldError)) : Partiduo::Api::Vat::RateView?
        code = line.vat_rate.try(&.strip).presence
        return if code.nil?
        rate = Partiduo::Api::Vat.rate_by_code(Partiduo::Api::Actor.system, code)
        if rate.nil?
          errors << FieldError.new("#{path}.vat_rate", "accounting.errors.entry.vat_rate.not_found", {"code" => code.upcase})
        elsif !rate.enabled
          errors << FieldError.new("#{path}.vat_rate", "accounting.errors.entry.vat_rate.disabled", {"code" => rate.code})
          return
        end
        rate
      end

      # TVA saisie, sinon calculée (`Acc_Compute::compute_vat`).
      private def self.vat_amount(line : Partiduo::Api::Accounting::DocumentLineInput, amount : BigDecimal,
                                  rate : Partiduo::Api::Vat::RateView?, path : String,
                                  errors : Array(FieldError)) : BigDecimal?
        if given = line.vat_amount
          unless Posting.decimals_ok?(given)
            errors << FieldError.new("#{path}.vat_amount", "accounting.errors.entry.too_many_decimals",
              {"max" => EntryBalance::MAX_DECIMALS.to_s})
            return
          end
          if rate.nil? && !given.zero?
            errors << FieldError.new("#{path}.vat_rate", "accounting.errors.entry.vat_rate.required")
            return
          end
          return given
        end
        rate ? rate.tax_on(amount) : BigDecimal.new(0)
      end

      # Compte de la ligne : saisi, sinon celui de la fiche article, sinon le
      # compte par défaut du journal.
      private def self.line_target(line : Partiduo::Api::Accounting::DocumentLineInput, ledger : Ledger, path : String,
                                   errors : Array(FieldError)) : Posting::Target?
        item = line.item.try(&.strip).presence
        card = item ? Posting.card(item, "#{path}.item", errors) : nil
        return if item && card.nil?
        if number = line.account.try(&.strip).presence
          account = Posting.account(number, "#{path}.account", errors)
          return account.try { |found| Posting::Target.new(found, card.try(&.card_id), card.try(&.card_code)) }
        end
        return card if card
        if default = ledger.default_account
          return Posting::Target.new(default)
        end
        errors << FieldError.new("#{path}.account", "accounting.errors.entry.account_missing")
        nil
      end

      # Comptes de TVA d'un taux : déductible (achats), collecté (ventes) ;
      # les deux pour un taux autoliquidé.
      private def self.vat_accounts(rate : Partiduo::Api::Vat::RateView) : {Account?, Account?}
        row = VatRateAccount.filter(vat_rate_id: rate.id).first
        {row.try(&.deductible_account), row.try(&.collected_account)}
      end

      private def self.draft(header : Posting::Header, kind : LedgerKind, third_party : Posting::Target,
                             items : Array(ItemLine), label : String) : Posting::Draft?
        # Côté de l'article : débit à l'achat, crédit à la vente.
        item_side = kind.purchase? ? Side::Debit : Side::Credit
        lines = [] of Posting::DraftLine
        total = BigDecimal.new(0) # signé, côté article, en devise de tenue
        total_currency = BigDecimal.new(0)
        excluding = BigDecimal.new(0)
        vat_by_rate = {} of Int64 => {Partiduo::Api::Vat::RateView, BigDecimal}

        items.each do |item|
          base = Posting.to_base(header, item.amount)
          total += base
          total_currency += item.amount
          excluding += base
          currency = header.base_currency ? nil : item.amount
          Posting.signed_line(item_side, base, currency, item.target, label: item.label,
            vat_rate_id: item.rate.try(&.id), vat_rate_code: item.rate.try(&.code),
            vat_role: item.rate ? "base" : nil, quantity: item.quantity, input_index: item.index).try { |line| lines << line }
          if rate = item.rate
            previous = vat_by_rate[rate.id]?.try(&.[1]) || BigDecimal.new(0)
            vat_by_rate[rate.id] = {rate, previous + item.vat}
          end
        end

        vat_total, vat_currency_total = vat_lines(header, kind, vat_by_rate, lines)
        total += vat_total
        total_currency += vat_currency_total

        Posting.signed_line(item_side.opposite, total, header.base_currency ? nil : total_currency, third_party,
          label: label).try { |line| lines << line }
        draft = Posting::Draft.new(header, label, lines)
        draft.excluding_vat = excluding
        draft.vat = vat_total
        draft.document_total = total_currency
        draft
      end

      # Lignes de TVA, une par taux (`$tva[$idx_tva]`) ; renvoie la TVA qui
      # s'ajoute au tiers (hors autoliquidation), en devise de tenue et en
      # devise de l'écriture.
      private def self.vat_lines(header : Posting::Header, kind : LedgerKind,
                                 vat_by_rate : Hash(Int64, {Partiduo::Api::Vat::RateView, BigDecimal}),
                                 lines : Array(Posting::DraftLine)) : {BigDecimal, BigDecimal}
        item_side = kind.purchase? ? Side::Debit : Side::Credit
        total = BigDecimal.new(0)
        total_currency = BigDecimal.new(0)
        vat_by_rate.each_value do |(rate, vat_currency)|
          next if vat_currency.zero?
          vat = Posting.to_base(header, vat_currency)
          currency = header.base_currency ? nil : vat_currency
          deductible, collected = vat_accounts(rate)
          options = {vat_rate_id: rate.id, vat_rate_code: rate.code, vat_role: "tax"}
          # Comptes vérifiés par `vat_account_errors`.
          if rate.reverse_charge
            # Autoliquidation : TVA due et déductible, sans effet sur le tiers.
            deductible = deductible || raise "compte de TVA déductible absent (#{rate.code})"
            collected = collected || raise "compte de TVA collectée absent (#{rate.code})"
            Posting.signed_line(Side::Debit, vat, currency, Posting::Target.new(deductible), **options).try { |line| lines << line }
            Posting.signed_line(Side::Credit, vat, currency, Posting::Target.new(collected), **options).try { |line| lines << line }
          else
            account = (kind.purchase? ? deductible : collected) || raise "compte de TVA absent (#{rate.code})"
            Posting.signed_line(item_side, vat, currency, Posting::Target.new(account), **options).try { |line| lines << line }
            total += vat
            total_currency += vat_currency
          end
        end
        {total, total_currency}
      end

      # Comptes de TVA manquants, contrôlés avant la construction des lignes.
      def self.vat_account_errors(input : Partiduo::Api::Accounting::DocumentInput, ledger : Ledger) : Array(FieldError)
        errors = [] of FieldError
        kind = LedgerKind.from_code(ledger.kind.to_s)
        input.lines.each_with_index do |line, index|
          code = line.vat_rate.try(&.strip).presence
          next if code.nil?
          rate = Partiduo::Api::Vat.rate_by_code(Partiduo::Api::Actor.system, code)
          next if rate.nil? || (rate.rate.zero? && (line.vat_amount.nil? || line.vat_amount.try(&.zero?)))
          deductible, collected = vat_accounts(rate)
          missing = if rate.reverse_charge
                      deductible.nil? || collected.nil?
                    else
                      (kind.purchase? ? deductible : collected).nil?
                    end
          if missing
            errors << FieldError.new("lines[#{index}].vat_rate", "accounting.errors.entry.vat_rate.no_account", {"code" => rate.code})
          end
        end
        errors
      end
    end
  end
end
