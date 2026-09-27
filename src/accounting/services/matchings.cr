# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Accounting
    # Lettrage, héritier de `Lettering::save` et `insert_couple`
    # (`jnt_letter`, `letter_deb`, `letter_cred`) : des lignes d'un même
    # compte, au débit et au crédit, sont rapprochées. Un lettrage peut être
    # partiel (débit ≠ crédit, « lettrage avec différence »). Une ligne déjà
    # lettrée qui entre dans un nouveau lettrage y amène son lettrage entier
    # (paiement en plusieurs fois). Service interne.
    module Matchings
      alias FieldError = Partiduo::Api::FieldError

      LETTERS = ('A'..'Z').to_a

      # Code affiché d'un lettrage : lettres tirées de l'identifiant
      # (1 → `A`, 26 → `Z`, 27 → `AA`).
      def self.code(id : Int64) : String
        n = id
        String.build do |io|
          chars = [] of Char
          while n > 0
            n -= 1
            chars << LETTERS[n % 26]
            n //= 26
          end
          chars.reverse_each { |char| io << char }
        end
      end

      # Lignes à lettrer, avec celles de leurs lettrages actuels ; erreurs
      # sous le champ `line_ids`.
      def self.validate(line_ids : Array(Int64)) : {Array(EntryLine), Array(FieldError)}
        errors = [] of FieldError
        ids = line_ids.uniq
        if ids.size < 2
          errors << FieldError.new("line_ids", "accounting.errors.matching.too_few_lines")
          return {[] of EntryLine, errors}
        end
        lines = EntryLine.filter(id__in: ids).to_a
        missing = ids - lines.map(&.pk!.as(Int64))
        missing.each do |id|
          errors << FieldError.new("line_ids", "accounting.errors.matching.line_not_found", {"id" => id.to_s})
        end
        return {lines, errors} unless errors.empty?

        existing = lines.compact_map(&.matching_id.try(&.as(Int).to_i64)).uniq!
        unless existing.empty?
          known = lines.map(&.pk!).to_set
          EntryLine.filter(matching_id__in: existing).each { |line| lines << line unless known.includes?(line.pk!) }
        end
        if lines.map(&.account_id).uniq!.size > 1
          errors << FieldError.new("line_ids", "accounting.errors.matching.different_accounts")
        elsif lines.all?(&.debit?) || lines.none?(&.debit?)
          errors << FieldError.new("line_ids", "accounting.errors.matching.one_side")
        end
        {lines, errors}
      end

      # Lettre les lignes (déjà validées) ; remplace leurs lettrages actuels.
      # Publie `payment.matched` quand un paiement (journal financier) est
      # lettré avec une facture (journal d'achats ou de ventes), ADR-004 D5.
      def self.match!(actor : Partiduo::Api::Actor, lines : Array(EntryLine)) : Matching
        # Lettrages remplacés, lus avant la mise à jour : ce qu'ils avaient
        # déjà réglé n'est pas publié une seconde fois.
        previous = lines.select(&.matching_id).group_by(&.matching_id.as(Int).to_i64).values
        old = lines.compact_map(&.matching_id.try(&.as(Int).to_i64)).uniq!
        matching = Matching.new(account_id: lines.first.account_id, created_by_id: actor.user_id)
        matching.save!
        ids = lines.map(&.pk!.as(Int64))
        EntryLine.filter(id__in: ids).update(matching_id: matching.pk)
        Matching.filter(id__in: old).delete unless old.empty?
        publish_payment(actor, matching.pk!.as(Int64), lines, previous)
        matching
      end

      # Délettre (`jnt_letter` effacé) : les lignes redeviennent ouvertes.
      # Publie `payment.unmatched` quand le lettrage défait rapprochait un
      # paiement (journal financier) d'une facture (journal d'achats ou de
      # ventes) : la Facturation retire les règlements qu'elle en avait
      # reçus (D-2F-003).
      def self.unmatch!(matching_id : Int64, actor : Partiduo::Api::Actor = Partiduo::Api::Actor.system) : Nil
        lines = EntryLine.filter(matching_id: matching_id).to_a
        EntryLine.filter(matching_id: matching_id).update(matching_id: nil)
        Matching.filter(id: matching_id).delete
        publish_unmatched(actor, matching_id, lines)
      end

      # Écritures des lignes et nature du journal de chaque ligne.
      private def self.ledger_kinds(lines : Array(EntryLine)) : {Hash(Int64, Entry), Proc(EntryLine, String)}
        entry_ids = lines.map(&.entry_id.as(Int).to_i64).uniq!
        entries = Entry.filter(id__in: entry_ids).to_a.index_by(&.pk!.as(Int64))
        kinds = Ledger.filter(id__in: entries.values.map(&.ledger_id).uniq!).to_a
          .to_h { |ledger| {ledger.pk!.as(Int64), ledger.kind.to_s} }
        kind_of = ->(line : EntryLine) { kinds[entries[line.entry_id.as(Int).to_i64].ledger_id.as(Int).to_i64]? || "" }
        {entries, kind_of}
      end

      # Un paiement et une facture dans les mêmes lignes ?
      private def self.payment_and_invoice?(lines : Array(EntryLine), kind_of : Proc(EntryLine, String)) : Bool
        present = lines.map { |line| kind_of.call(line) }.to_set
        present.includes?("financial") && (present.includes?("sale") || present.includes?("purchase"))
      end

      # Clés de `payment.unmatched` : `matching_id` (lettrage défait),
      # `entry_ids`, `sources` (références des écritures d'achats ou de
      # ventes du lettrage).
      private def self.publish_unmatched(actor : Partiduo::Api::Actor, matching_id : Int64, lines : Array(EntryLine)) : Nil
        return if lines.empty?
        entries, kind_of = ledger_kinds(lines)
        return unless payment_and_invoice?(lines, kind_of)
        sources = lines.select { |line| kind_of.call(line).in?("sale", "purchase") }
          .map { |line| entries[line.entry_id.as(Int).to_i64].source.to_s }.reject(&.empty?).uniq!
        Partiduo::Events.publish("payment.unmatched", {
          "matching_id" => matching_id.to_s,
          "entry_ids"   => entries.keys.sort!.join(","),
          "sources"     => sources.join(","),
        }, actor_user_id: actor.user_id)
      end

      # Clés de `payment.matched` : `matching_id`, `entry_ids`, `sources` ;
      # `amounts` (`<source>=<montant>;…`) : montant que ce lettrage règle
      # sur chaque facture, *en plus* des lettrages qu'il remplace ;
      # `matched_on` : date du dernier paiement lettré (D-INT-005).
      private def self.publish_payment(actor : Partiduo::Api::Actor, matching_id : Int64, lines : Array(EntryLine),
                                       previous : Array(Array(EntryLine))) : Nil
        entry_ids = lines.map(&.entry_id.as(Int).to_i64).uniq!
        entries, kind_of = ledger_kinds(lines)
        return unless payment_and_invoice?(lines, kind_of)

        amounts = settled(lines, entries, kind_of)
        previous.each do |group|
          settled(group, entries, kind_of).each do |source, amount|
            amounts[source] = amounts.fetch(source, BigDecimal.new(0)) - amount if amounts.has_key?(source)
          end
        end
        payments = lines.select { |line| kind_of.call(line) == "financial" }.map { |line| entries[line.entry_id.as(Int).to_i64] }
        matched_on = payments.reject(&.source.to_s.starts_with?(RECORDED_PREFIX)).max_of?(&.date!) ||
                     payments.max_of?(&.date!)
        payload = {
          "matching_id" => matching_id.to_s,
          "entry_ids"   => entry_ids.sort!.join(","),
          "sources"     => entry_ids.compact_map { |id| entries[id]?.try(&.source.to_s) }.reject(&.empty?).uniq!.join(","),
          "amounts"     => amounts.map { |source, amount| "#{source}=#{Math.max(amount, BigDecimal.new(0))}" }.join(";"),
        }
        matched_on.try { |date| payload["matched_on"] = date.to_s("%Y-%m-%d") }
        Partiduo::Events.publish("payment.matched", payload, actor_user_id: actor.user_id)
      end

      # Référence des encaissements venus de la Facturation (`payment.recorded`) :
      # la Facturation les connaît déjà, ils ne règlent rien de plus.
      RECORDED_PREFIX = "payment:"

      # Montant réglé par les paiements d'un groupe de lignes lettrées, par
      # référence de facture (`source` d'une écriture d'achats ou de ventes) :
      # les paiements (journaux financiers, hors `payment:`) du côté opposé
      # aux factures sont répartis sur elles par date, chacune plafonnée à son
      # montant diminué des avoirs du même groupe (imputés eux aussi par date).
      private def self.settled(lines : Array(EntryLine), entries : Hash(Int64, Entry),
                               kind_of : Proc(EntryLine, String)) : Hash(String, BigDecimal)
        zero = BigDecimal.new(0)
        documents = {"debit" => {} of String => BigDecimal, "credit" => {} of String => BigDecimal}
        order = {} of String => {Time, Int64}
        paid = {"debit" => zero, "credit" => zero}
        lines.each do |line|
          entry = entries[line.entry_id.as(Int).to_i64]
          side = line.side.to_s
          case kind_of.call(line)
          when "sale", "purchase"
            source = entry.source.to_s
            next if source.empty?
            documents[side][source] = documents[side].fetch(source, zero) + line.amount!
            order[source] = {entry.date!, entry.pk!.as(Int64)}
          when "financial"
            next if entry.source.to_s.starts_with?(RECORDED_PREFIX)
            paid[side] += line.amount!
          end
        end
        result = {} of String => BigDecimal
        documents.each_value { |sources| sources.each_key { |source| result[source] = zero } }
        {"debit", "credit"}.each do |side|
          other = side == "debit" ? "credit" : "debit"
          available = paid[other] - paid[side]
          next unless available > 0
          compensation = documents[other].values.sum(zero)
          documents[side].keys.sort_by! { |source| order[source] }.each do |source|
            amount = documents[side][source]
            used = Math.min(amount, compensation)
            compensation -= used
            share = Math.min(amount - used, available)
            available -= share
            result[source] = share
          end
        end
        result
      end
    end
  end
end
