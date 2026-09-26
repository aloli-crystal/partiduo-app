# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    # Contrat du module Comptabilité.
    #
    # Exemple minimal de *requête de contrôle* (ADR-005 D2) : l'interface
    # l'appelle pour afficher l'équilibre en direct ; elle applique la même
    # règle que la future commande `post_entry` (lot 2).
    module Accounting
      MODULE_CODE = "ACCOUNTING"

      enum Side
        Debit
        Credit
      end

      # Entrée : une ligne telle que saisie. Montant en `BigDecimal`, jamais en `Float`.
      record EntryLineInput, account : String, side : Side, amount : BigDecimal

      record CheckEntryInput, lines : Array(EntryLineInput)

      # Vue : totaux de l'écriture contrôlée.
      record EntryCheckView, total_debit : BigDecimal, total_credit : BigDecimal, difference : BigDecimal do
        def balanced? : Bool
          difference.zero?
        end
      end

      def self.check_entry(actor : Actor, input : CheckEntryInput) : Result(EntryCheckView)
        Guard.authorize!(actor, "accounting.entry.post", module_code: MODULE_CODE)

        lines = input.lines.map do |line|
          Partiduo::Accounting::EntryBalance::Line.new(line.side.debit? ? :debit : :credit, line.amount)
        end
        errors = Partiduo::Accounting::EntryBalance.errors(lines)
        input.lines.each_with_index do |line, index|
          if line.account.strip.empty?
            errors.unshift(FieldError.new("lines[#{index}].account", "accounting.errors.entry.account_missing"))
          end
        end
        return Result(EntryCheckView).failure(errors) unless errors.empty?

        totals = Partiduo::Accounting::EntryBalance.totals(lines)
        Result(EntryCheckView).success(EntryCheckView.new(totals.debit, totals.credit, totals.difference))
      end
    end
  end
end
