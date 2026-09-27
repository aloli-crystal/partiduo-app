# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    # Contrat du module Comptabilité — écritures (lot 2) : saisie par un seul
    # service (`post_entry` et ses variantes achats, ventes, financier),
    # requêtes de contrôle (`check_*`) appliquant les mêmes règles sans
    # écrire, annulation par extourne, recherche et consultation. Types dans
    # `entry_types.cr` ; lettrage et relevé dans `matching.cr`.
    #
    # Toute écriture passe par ces commandes ; PostgreSQL refuse en outre une
    # écriture déséquilibrée, hors exercice ou dans une période close
    # (migration accounting 0003, D-ACC-011).
    module Accounting
      MODULE_CODE = "ACCOUNTING"

      # --- Requêtes de contrôle ------------------------------------------------

      # Équilibre seul des lignes saisies (retour instantané de l'interface) :
      # montants, nombre de lignes, compte ou fiche présent.
      def self.check_entry(actor : Actor, input : CheckEntryInput) : Result(EntryCheckView)
        Guard.authorize!(actor, "accounting.entry.post", module_code: MODULE_CODE)
        errors = Partiduo::Accounting::Posting.line_errors(input.lines)
        return Result(EntryCheckView).failure(errors) unless errors.empty?

        lines = input.lines.map do |line|
          Partiduo::Accounting::EntryBalance::Line.new(line.side.debit? ? :debit : :credit, line.amount)
        end
        totals = Partiduo::Accounting::EntryBalance.totals(lines)
        Result(EntryCheckView).success(EntryCheckView.new(totals.debit, totals.credit, totals.difference))
      end

      # Règles complètes de `post_entry`, sans écrire.
      def self.check_entry(actor : Actor, input : EntryInput) : Result(EntryDraftView)
        Guard.authorize!(actor, "accounting.entry.post", module_code: MODULE_CODE)
        ledger = Partiduo::Accounting::Posting.writable_ledger(actor, input.ledger_id)
        draft, errors = Partiduo::Accounting::Posting.generic(actor, input, ledger)
        draft ? Result(EntryDraftView).success(draft_view(draft)) : Result(EntryDraftView).failure(errors)
      end

      # Règles de `post_purchase` / `post_sale`, sans écrire : lignes
      # calculées (TVA ventilée) et totaux.
      def self.check_document(actor : Actor, input : DocumentInput) : Result(EntryDraftView)
        Guard.authorize!(actor, "accounting.entry.post", module_code: MODULE_CODE)
        ledger = Partiduo::Accounting::Posting.writable_ledger(actor, input.ledger_id)
        draft, errors = Partiduo::Accounting::Documents.build(input, ledger)
        draft ? Result(EntryDraftView).success(draft_view(draft)) : Result(EntryDraftView).failure(errors)
      end

      # Règles de `post_financial`, sans écrire : une écriture par ligne.
      def self.check_financial(actor : Actor, input : FinancialInput) : Result(Array(EntryDraftView))
        Guard.authorize!(actor, "accounting.entry.post", module_code: MODULE_CODE)
        ledger = Partiduo::Accounting::Posting.writable_ledger(actor, input.ledger_id)
        planned, errors = Partiduo::Accounting::Financial.build(input, ledger)
        return Result(Array(EntryDraftView)).failure(errors) unless errors.empty?
        Result(Array(EntryDraftView)).success(planned.map { |plan| draft_view(plan.draft) })
      end

      # --- Commandes -----------------------------------------------------------

      # Enregistre une écriture saisie ligne à ligne (`Acc_Ledger::save`),
      # dans tout journal où l'acteur peut écrire ; publie `entry.posted`.
      def self.post_entry(actor : Actor, input : EntryInput) : Result(EntryView)
        Guard.authorize!(actor, "accounting.entry.post", module_code: MODULE_CODE)
        Transaction.run do
          ledger = Partiduo::Accounting::Posting.writable_ledger(actor, input.ledger_id)
          draft, errors = Partiduo::Accounting::Posting.generic(actor, input, ledger)
          next Result(EntryView).failure(errors) if draft.nil?
          entry = Partiduo::Accounting::Posting.create!(actor, draft)
          Result(EntryView).success(entry_views([entry]).first)
        end
      end

      # Facture ou avoir d'achat (`Acc_Ledger_Purchase::insert`).
      def self.post_purchase(actor : Actor, input : DocumentInput) : Result(EntryView)
        post_document(actor, input, LedgerKind::Purchase)
      end

      # Facture ou avoir de vente (`Acc_Ledger_Sale::insert`).
      def self.post_sale(actor : Actor, input : DocumentInput) : Result(EntryView)
        post_document(actor, input, LedgerKind::Sale)
      end

      # Extrait financier (`Acc_Ledger_Fin::insert`) : une écriture par ligne,
      # lettrée avec les lignes `match_line_ids` de sa ligne.
      def self.post_financial(actor : Actor, input : FinancialInput) : Result(Array(EntryView))
        Guard.authorize!(actor, "accounting.entry.post", module_code: MODULE_CODE)
        Transaction.run do
          ledger = Partiduo::Accounting::Posting.writable_ledger(actor, input.ledger_id)
          planned, errors = Partiduo::Accounting::Financial.build(input, ledger)
          next Result(Array(EntryView)).failure(errors) unless errors.empty?
          entries = [] of Partiduo::Accounting::Entry
          failure = nil
          planned.each_with_index do |plan, index|
            entry = Partiduo::Accounting::Posting.create!(actor, plan.draft)
            entries << entry
            next if plan.match_line_ids.empty?
            counterpart = entry.lines.order(:position).first!
            lines, match_errors = Partiduo::Accounting::Matchings.validate([counterpart.pk!.as(Int64)] + plan.match_line_ids)
            unless match_errors.empty?
              failure = match_errors.map { |error| FieldError.new("lines[#{index}].match_line_ids", error.key, error.params) }
              break
            end
            ensure_lines_readable!(actor, lines)
            Partiduo::Accounting::Matchings.match!(actor, lines)
          end
          next Result(Array(EntryView)).failure(failure) if failure
          Result(Array(EntryView)).success(entry_views(entries))
        end
      end

      # Annule une écriture par extourne (`Acc_Ledger::reverse`) ; publie
      # `entry.posted` pour l'extourne puis `entry.cancelled` pour l'écriture
      # annulée (clé supplémentaire `reversal_entry_id`).
      def self.cancel_entry(actor : Actor, input : CancelEntryInput) : Result(EntryView)
        Guard.authorize!(actor, "accounting.entry.cancel", module_code: MODULE_CODE)
        Transaction.run do
          entry = Partiduo::Accounting::Entry.filter(id: input.entry_id).lock.first ||
                  raise NotFound.new("entry", input.entry_id)
          Partiduo::Accounting::Posting.writable_ledger(actor, entry.ledger_id.as(Int).to_i64)
          draft, errors = Partiduo::Accounting::Reversals.build(entry, input)
          next Result(EntryView).failure(errors) if draft.nil?
          reversal = Partiduo::Accounting::Posting.create!(actor, draft)
          Partiduo::Accounting::Reversals.match_pairs!(actor, entry, reversal)
          Partiduo::Events.publish("entry.cancelled",
            {"entry_id" => input.entry_id.to_s, "reversal_entry_id" => reversal.pk!.to_s}, actor_user_id: actor.user_id)
          Result(EntryView).success(entry_views([reversal]).first)
        end
      end

      # --- Requêtes --------------------------------------------------------------

      # Une écriture d'un journal visible de l'acteur ; `NotFound` sinon.
      def self.entry(actor : Actor, id : Int64) : EntryView
        Guard.authorize!(actor, "accounting.entry.read", module_code: MODULE_CODE)
        entry = Partiduo::Accounting::Entry.filter(id: id).first || raise NotFound.new("entry", id)
        raise NotFound.new("entry", id) unless readable_ledger_ids(actor).includes?(entry.ledger_id.as(Int).to_i64)
        entry_views([entry]).first
      end

      # Écritures des journaux visibles répondant aux critères, par date.
      def self.entries(actor : Actor, query : EntryQuery = EntryQuery.new) : Array(EntryView)
        Guard.authorize!(actor, "accounting.entry.read", module_code: MODULE_CODE)
        ids = Partiduo::Accounting::EntryQueries.search_ids(query, readable_ledger_ids(actor))
        return [] of EntryView if ids.empty?
        by_id = Partiduo::Accounting::Entry.filter(id__in: ids).to_a.index_by(&.pk!.as(Int64))
        entry_views(ids.compact_map { |id| by_id[id]? })
      end

      def self.count_entries(actor : Actor, query : EntryQuery = EntryQuery.new) : Int64
        Guard.authorize!(actor, "accounting.entry.read", module_code: MODULE_CODE)
        Partiduo::Accounting::EntryQueries.count(query, readable_ledger_ids(actor))
      end

      # --- Outils ----------------------------------------------------------------

      private def self.post_document(actor : Actor, input : DocumentInput, kind : LedgerKind) : Result(EntryView)
        Guard.authorize!(actor, "accounting.entry.post", module_code: MODULE_CODE)
        Transaction.run do
          ledger = Partiduo::Accounting::Posting.writable_ledger(actor, input.ledger_id)
          unless ledger.kind == kind.code
            key = kind.purchase? ? "accounting.errors.entry.ledger.not_purchase" : "accounting.errors.entry.ledger.not_sale"
            next Result(EntryView).failure(FieldError.new("ledger_id", key, {"code" => ledger.code.to_s}))
          end
          draft, errors = Partiduo::Accounting::Documents.build(input, ledger)
          next Result(EntryView).failure(errors) if draft.nil?
          entry = Partiduo::Accounting::Posting.create!(actor, draft)
          Result(EntryView).success(entry_views([entry]).first)
        end
      end

      # Journaux dont l'acteur peut lire les écritures (droit `R` ou `W`, ou
      # administration des journaux).
      private def self.readable_ledger_ids(actor : Actor) : Array(Int64)
        Partiduo::Accounting::Ledger.all.to_a.compact_map do |ledger|
          id = ledger.pk!.as(Int64)
          access = Partiduo::Accounting::Ledgers.access(actor, id)
          id if Partiduo::Accounting::Ledgers.visible?(actor, access)
        end
      end

      private def self.ensure_lines_readable!(actor : Actor, lines : Array(Partiduo::Accounting::EntryLine)) : Nil
        readable = readable_ledger_ids(actor).to_set
        entry_ids = lines.map(&.entry_id.as(Int).to_i64).uniq!
        Partiduo::Accounting::Entry.filter(id__in: entry_ids).each do |entry|
          raise Forbidden.new("accounting.entry.read") unless readable.includes?(entry.ledger_id.as(Int).to_i64)
        end
      end

      private def self.draft_view(draft : Partiduo::Accounting::Posting::Draft) : EntryDraftView
        header = draft.header
        EntryDraftView.new(
          lines: draft.lines.map do |line|
            DraftLineView.new(
              account_number: line.account.number.to_s, account_label: line.account.label.to_s,
              card_code: line.card_code, side: line.side, amount: line.amount, currency_amount: line.currency_amount,
              label: line.label, vat_rate_code: line.vat_rate_code, vat_role: line.vat_role,
            )
          end,
          total_debit: draft.total(Side::Debit), total_credit: draft.total(Side::Credit),
          total_excluding_vat: draft.excluding_vat, total_vat: draft.vat,
          total_including_vat: draft.excluding_vat + draft.vat, period_id: header.period_id,
          receipt: header.receipt || next_receipt(header.ledger),
        )
      end

      # Pièce que l'enregistrement prendrait : les numéros déjà pris par une
      # pièce saisie sont sautés, comme `Posting.create!`.
      private def self.next_receipt(ledger : Partiduo::Accounting::Ledger) : String
        number = ledger.last_receipt_number!.to_i64
        receipt = ""
        Partiduo::Accounting::Posting::RECEIPT_ATTEMPTS.times do
          number += 1
          receipt = Partiduo::Accounting::Receipts.format(ledger.receipt_prefix.to_s, ledger.receipt_padding!.to_i32, number)
          break unless Partiduo::Accounting::Entry.filter(ledger_id: ledger.pk, receipt: receipt).exists?
        end
        receipt
      end

      # Vues des écritures, lignes comprises, en quelques requêtes.
      private def self.entry_views(entries : Array(Partiduo::Accounting::Entry)) : Array(EntryView)
        return [] of EntryView if entries.empty?
        ids = entries.map(&.pk!.as(Int64))
        lines = Partiduo::Accounting::EntryLine.filter(entry_id__in: ids).order(:position).to_a
          .group_by(&.entry_id.as(Int).to_i64)
        account_ids = lines.values.flatten.map(&.account_id.as(Int).to_i64).uniq!
        accounts = Partiduo::Accounting::Account.filter(id__in: account_ids).to_a.index_by(&.pk!.as(Int64))
        ledger_ids = entries.map(&.ledger_id.as(Int).to_i64).uniq!
        ledgers = Partiduo::Accounting::Ledger.filter(id__in: ledger_ids).to_a.index_by(&.pk!.as(Int64))
        reversed_by = Partiduo::Accounting::Entry.filter(reversal_of_id__in: ids).to_a
          .to_h { |reversal| {reversal.reversal_of_id.as(Int).to_i64, reversal.pk!.as(Int64)} }
        cards = {} of Int64 => String?
        rates = {} of Int64 => String?

        entries.map do |entry|
          id = entry.pk!.as(Int64)
          ledger = ledgers[entry.ledger_id.as(Int).to_i64]
          EntryView.new(
            id: id, ledger_id: ledger.pk!.as(Int64), ledger_code: ledger.code.to_s,
            ledger_kind: LedgerKind.from_code(ledger.kind.to_s), period_id: entry.period_id!.to_i64,
            date: entry.date!, due_date: entry.due_date, label: entry.label.to_s, receipt: entry.receipt,
            internal_code: entry.internal_code.to_s, amount: entry.amount!, currency_code: entry.currency_code.to_s,
            currency_rate: entry.currency_rate!, reversal_of_id: entry.reversal_of_id.try(&.as(Int).to_i64),
            reversed_by_id: reversed_by[id]?, attachment_id: entry.attachment_id.try(&.to_i64),
            source: entry.source.to_s, created_by_id: entry.created_by_id.try(&.to_i64),
            created_at: entry.created_at || Time.utc,
            lines: (lines[id]? || [] of Partiduo::Accounting::EntryLine).map do |line|
              account = accounts[line.account_id.as(Int).to_i64]
              card_id = line.card_id.try(&.to_i64)
              rate_id = line.vat_rate_id.try(&.to_i64)
              matching_id = line.matching_id.try(&.as(Int).to_i64)
              EntryLineView.new(
                id: line.pk!.as(Int64), position: line.position!.to_i32, account_id: account.pk!.as(Int64),
                account_number: account.number.to_s, account_label: account.label.to_s, card_id: card_id,
                card_code: card_id.try { |value| cards.put_if_absent(value) { card_code(value) } },
                side: Side.from_code(line.side.to_s), amount: line.amount!, currency_amount: line.currency_amount,
                label: line.label.to_s, vat_rate_id: rate_id,
                vat_rate_code: rate_id.try { |value| rates.put_if_absent(value) { vat_rate_code(value) } },
                vat_role: line.vat_role, quantity: line.quantity, matching_id: matching_id,
                matching_code: matching_id.try { |value| Partiduo::Accounting::Matchings.code(value) },
              )
            end,
          )
        end
      end

      private def self.card_code(id : Int64) : String?
        Partiduo::Api::Cards.card(Actor.system, id).code
      rescue NotFound
        nil
      end

      private def self.vat_rate_code(id : Int64) : String?
        Partiduo::Api::Vat.rate(Actor.system, id).code
      rescue NotFound
        nil
      end
    end
  end
end
