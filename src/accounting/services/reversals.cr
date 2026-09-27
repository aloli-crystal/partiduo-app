# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Accounting
    # Annulation par extourne, héritière de `Acc_Ledger::reverse` : écriture
    # inverse (mêmes comptes, fiches et montants, sens opposés) dans le même
    # journal, à une date d'une période ouverte, avec une nouvelle pièce ;
    # chaque ligne est lettrée avec la ligne qu'elle annule (`insert_couple`).
    # Une ligne déjà lettrée quitte son lettrage, qui est défait : le
    # paiement d'une facture annulée redevient un élément ouvert. Service
    # interne.
    module Reversals
      alias FieldError = Partiduo::Api::FieldError

      def self.build(entry : Entry, input : Partiduo::Api::Accounting::CancelEntryInput) : {Posting::Draft?, Array(FieldError)}
        errors = [] of FieldError
        if entry.reversal_of_id
          errors << FieldError.base("accounting.errors.entry.cancel.is_reversal")
        elsif Entry.filter(reversal_of_id: entry.pk).exists?
          errors << FieldError.base("accounting.errors.entry.cancel.already_cancelled")
        end
        return {nil, errors} unless errors.empty?

        ledger = entry.ledger!
        header = Posting.header(ledger, input.date || entry.date!, entry.due_date, nil, entry.currency_code,
          entry.currency_rate, entry.attachment_id.try(&.to_i64), entry.source.to_s, errors)
        return {nil, errors} unless header

        lines = entry.lines.order(:position).map do |line|
          Posting::DraftLine.new(
            account: line.account!, side: Partiduo::Api::Accounting::Side.from_code(line.side.to_s).opposite,
            amount: line.amount!, currency_amount: line.currency_amount, card_id: line.card_id.try(&.to_i64),
            label: line.label.to_s, vat_rate_id: line.vat_rate_id.try(&.to_i64), vat_role: line.vat_role,
            quantity: line.quantity, input_index: line.input_index.try(&.to_i32),
          )
        end
        draft = Posting::Draft.new(header, input.label.strip.presence || entry.label.to_s, lines)
        draft.reversal_of_id = entry.pk!.as(Int64)
        {draft, errors}
      end

      # Lettre chaque ligne de l'extourne avec la ligne qu'elle annule.
      def self.match_pairs!(actor : Partiduo::Api::Actor, original : Entry, reversal : Entry) : Nil
        originals = original.lines.order(:position).to_a
        reversed = reversal.lines.order(:position).to_a
        originals.compact_map(&.matching_id).uniq!.each { |id| Matchings.unmatch!(id.as(Int).to_i64, actor) }
        originals.zip(reversed).each do |(line, opposite)|
          matching = Matching.new(account_id: line.account_id, created_by_id: actor.user_id)
          matching.save!
          EntryLine.filter(id__in: [line.pk!, opposite.pk!]).update(matching_id: matching.pk)
        end
      end
    end
  end
end
