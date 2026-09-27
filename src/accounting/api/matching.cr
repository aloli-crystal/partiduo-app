# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    # Contrat du module Comptabilité — lettrage (`Lettering`) et consultation
    # d'un compte ou d'un tiers (ADR-005 D9).
    module Accounting
      # --- Lettrage --------------------------------------------------------------

      # Lettre des lignes d'un même compte, au débit et au crédit ; une ligne
      # déjà lettrée y amène son lettrage entier. Publie `payment.matched`
      # quand un paiement (journal financier) est lettré avec une facture
      # (journal d'achats ou de ventes) — clés supplémentaires `entry_ids` et
      # `sources` (ADR-004 D5).
      def self.match_lines(actor : Actor, line_ids : Array(Int64)) : Result(MatchingView)
        Guard.authorize!(actor, "accounting.matching.write", module_code: MODULE_CODE)
        Transaction.run do
          lines, errors = Partiduo::Accounting::Matchings.validate(line_ids)
          next Result(MatchingView).failure(errors) unless errors.empty?
          ensure_lines_readable!(actor, lines)
          matching = Partiduo::Accounting::Matchings.match!(actor, lines)
          Result(MatchingView).success(matching_view(matching))
        end
      end

      # Requête de contrôle de `match_lines`.
      def self.check_matching(actor : Actor, line_ids : Array(Int64)) : Result(Nil)
        Guard.authorize!(actor, "accounting.matching.write", module_code: MODULE_CODE)
        lines, errors = Partiduo::Accounting::Matchings.validate(line_ids)
        return Result(Nil).failure(errors) unless errors.empty?
        ensure_lines_readable!(actor, lines)
        Result(Nil).success(nil)
      end

      # Délettre : les lignes du lettrage redeviennent ouvertes.
      def self.unmatch(actor : Actor, matching_id : Int64) : Result(Nil)
        Guard.authorize!(actor, "accounting.matching.write", module_code: MODULE_CODE)
        Transaction.run do
          matching = Partiduo::Accounting::Matching.filter(id: matching_id).lock.first ||
                     raise NotFound.new("matching", matching_id)
          ensure_lines_readable!(actor, matching.lines.to_a)
          Partiduo::Accounting::Matchings.unmatch!(matching_id, actor)
          Result(Nil).success(nil)
        end
      end

      def self.matching(actor : Actor, id : Int64) : MatchingView
        Guard.authorize!(actor, "accounting.entry.read", module_code: MODULE_CODE)
        matching = Partiduo::Accounting::Matching.filter(id: id).first || raise NotFound.new("matching", id)
        ensure_lines_readable!(actor, matching.lines.to_a)
        matching_view(matching)
      end

      # --- Consultation d'un compte ou d'un tiers ------------------------------

      # Synthèse (solde, reste dû, échu, balance âgée) et mouvements (solde
      # progressif, lettre) d'un compte ou d'une fiche, dans les journaux
      # visibles de l'acteur. `NotFound` si le compte ou la fiche n'existe
      # pas ; `ArgumentError` si ni l'un ni l'autre n'est donné.
      def self.account_statement(actor : Actor, query : StatementQuery) : AccountStatementView
        Guard.authorize!(actor, "accounting.entry.read", module_code: MODULE_CODE)
        ledger_ids = readable_ledger_ids(actor)
        if code = query.card.try(&.strip).presence
          card = Partiduo::Api::Cards.card_by_code(Actor.system, code) || raise NotFound.new("card", code)
          account = Partiduo::Accounting::CardAccount.filter(card_id: card.id).first.try(&.account)
          rows = Partiduo::Accounting::EntryQueries.statement_rows(nil, card.id, ledger_ids, query.date_to)
          Partiduo::Accounting::EntryQueries.statement(rows, query, account.try { |found| account_view(found) }, card)
        elsif number = query.account.try(&.strip).presence
          normalized = Partiduo::Accounting::Chart.normalize(number)
          account = Partiduo::Accounting::Account.filter(number: normalized).first || raise NotFound.new("account", normalized)
          rows = Partiduo::Accounting::EntryQueries.statement_rows(account.pk!.as(Int64), nil, ledger_ids, query.date_to)
          Partiduo::Accounting::EntryQueries.statement(rows, query, account_view(account), nil)
        else
          raise ArgumentError.new("account_statement : compte ou fiche attendu")
        end
      end

      # Reste dû et échu de toutes les fiches `kind` (`customer` ou
      # `supplier`) en une requête agrégée, au jour `as_of` (défaut : date
      # du jour de l'instance). Tableau de bord (D-2F-005).
      def self.party_balances(actor : Actor, kind : String, as_of : Time? = nil) : PartyBalancesView
        Guard.authorize!(actor, "accounting.entry.read", module_code: MODULE_CODE)
        card_ids = Partiduo::Api::Cards.card_ids(Actor.system, Partiduo::Api::Cards::CardQuery.new(kind: kind, enabled: nil))
        day = Partiduo::Accounting::Posting.day(as_of || Partiduo::Config.today)
        totals = Partiduo::Accounting::EntryQueries.party_balances(card_ids, readable_ledger_ids(actor), day)
        zero = BigDecimal.new(0)
        worst = totals.max_by? { |(_, values)| values[1].abs }
        worst = nil if worst && worst[1][1].zero?
        card = worst.try { |(card_id, _)| Partiduo::Api::Cards.card(Actor.system, card_id) }
        PartyBalancesView.new(
          kind: kind, cards: totals.size, remaining: totals.values.sum(zero, &.[0]),
          overdue: totals.values.sum(zero, &.[1]), worst_card_code: card.try(&.code),
          worst_card_name: card.try(&.name), worst_overdue: worst.try(&.[1][1]) || zero,
        )
      end

      private def self.matching_view(matching : Partiduo::Accounting::Matching) : MatchingView
        lines = matching.lines.order(:id).to_a
        entries = Partiduo::Accounting::Entry.filter(id__in: lines.map(&.entry_id.as(Int).to_i64).uniq!).to_a
          .index_by(&.pk!.as(Int64))
        ledgers = Partiduo::Accounting::Ledger.filter(id__in: entries.values.map(&.ledger_id.as(Int).to_i64).uniq!).to_a
          .index_by(&.pk!.as(Int64))
        difference = BigDecimal.new(0)
        views = lines.map do |line|
          entry = entries[line.entry_id.as(Int).to_i64]
          ledger = ledgers[entry.ledger_id.as(Int).to_i64]
          side = Side.from_code(line.side.to_s)
          difference += side.debit? ? line.amount! : -line.amount!
          MatchingLineView.new(
            line_id: line.pk!.as(Int64), entry_id: entry.pk!.as(Int64), ledger_code: ledger.code.to_s,
            ledger_kind: LedgerKind.from_code(ledger.kind.to_s), date: entry.date!, receipt: entry.receipt,
            label: line.label.to_s.presence || entry.label.to_s, side: side, amount: line.amount!,
          )
        end
        account = matching.account!
        id = matching.pk!.as(Int64)
        MatchingView.new(
          id: id, code: Partiduo::Accounting::Matchings.code(id), account_id: account.pk!.as(Int64),
          account_number: account.number.to_s, lines: views, difference: difference,
          created_at: matching.created_at || Time.utc,
        )
      end
    end
  end
end
