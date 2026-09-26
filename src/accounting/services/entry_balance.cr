# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Accounting
    # Règle d'équilibre d'une écriture, appliquée à l'identique par la requête
    # de contrôle (`check_entry`) et, au lot 2, par la commande `post_entry`.
    # Elle est doublée en base par une contrainte (ADR-001 § PL/pgSQL).
    #
    # Service interne : il n'est pas dans `Partiduo::Api` et peut changer.
    module EntryBalance
      MIN_LINES = 2

      # Nombre maximal de décimales d'un montant (colonnes `decimal(20, 4)`).
      MAX_DECIMALS = 4

      record Line, side : Symbol, amount : BigDecimal

      record Totals, debit : BigDecimal, credit : BigDecimal do
        def difference : BigDecimal
          debit - credit
        end

        def balanced? : Bool
          difference.zero?
        end
      end

      def self.totals(lines : Enumerable(Line)) : Totals
        debit = BigDecimal.new(0)
        credit = BigDecimal.new(0)
        lines.each do |line|
          line.side == :debit ? (debit += line.amount) : (credit += line.amount)
        end
        Totals.new(debit, credit)
      end

      # Erreurs par ligne (`lines[i].amount`) puis sur l'ensemble (`base`).
      def self.errors(lines : Array(Line)) : Array(Partiduo::Api::FieldError)
        errors = [] of Partiduo::Api::FieldError

        lines.each_with_index do |line, index|
          field = "lines[#{index}].amount"
          if line.amount <= 0
            errors << Partiduo::Api::FieldError.new(field, "accounting.errors.entry.amount_not_positive")
          elsif line.amount.scale > MAX_DECIMALS && line.amount != line.amount.round(MAX_DECIMALS)
            errors << Partiduo::Api::FieldError.new(
              field, "accounting.errors.entry.too_many_decimals", {"max" => MAX_DECIMALS.to_s}
            )
          end
        end

        if lines.size < MIN_LINES
          errors << Partiduo::Api::FieldError.base("accounting.errors.entry.too_few_lines", {"min" => MIN_LINES.to_s})
        end

        totals = totals(lines)
        unless totals.balanced?
          errors << Partiduo::Api::FieldError.base(
            "accounting.errors.entry.unbalanced", {"difference" => totals.difference.to_s}
          )
        end

        errors
      end
    end
  end
end
