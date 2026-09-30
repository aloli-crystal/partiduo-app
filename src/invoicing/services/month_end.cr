# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Invoicing
    # Facturation mensuelle des bons de livraison (art. 289-I-3 du CGI :
    # livraisons multiples à un même client au cours d'un même mois, facture
    # récapitulative établie au plus tard à la fin du mois). DECISIONS
    # D-INV2-007 et D-INV2-008.
    #
    # Pour un mois M, chaque client (au rythme mensuel, ou celui qu'on
    # désigne) qui a des bons émis, non facturés et libres, livrés au plus
    # tard le dernier jour de M (les bons oubliés des mois précédents
    # compris), reçoit un brouillon de facture récapitulative par devise.
    # Idempotent : une ligne `MonthlyInvoice` par client, mois et devise
    # (contrainte d'unicité, verrou consultatif) ; un mois déjà traité pour
    # un client ne l'est plus, même si son brouillon a été supprimé. Une
    # préparation refusée (`failed`, sans facture) est reprise au passage
    # suivant.
    #
    # Déclenchement planifié (`schedule`) : le dernier jour du mois, et le
    # mois précédent tant qu'il n'est pas clos (rattrapage d'un jour manqué) ;
    # chaque mois traité ainsi est clos (`MonthClose`).
    module MonthEnd
      alias Api = Partiduo::Api::Invoicing

      Log = ::Log.for("partiduo.invoicing")

      def self.month_start(day : Time) : Time
        Time.utc(day.year, day.month, 1)
      end

      def self.month_last_day(day : Time) : Time
        Time.utc(day.year, day.month, Time.days_in_month(day.year, day.month))
      end

      def self.last_day?(day : Time) : Bool
        day.day == Time.days_in_month(day.year, day.month)
      end

      def self.previous_month(day : Time) : Time
        month_start(month_start(day) - 1.day)
      end

      def self.closed?(month : Time) : Bool
        MonthClose.filter(month: month_start(month)).exists?
      end

      # Mois dus au jour `today` pour la tâche planifiée : le précédent s'il
      # n'est pas clos, le mois courant si c'est son dernier jour.
      def self.due_months(today : Time) : Array(Time)
        months = [] of Time
        previous = previous_month(today)
        months << previous unless closed?(previous)
        current = month_start(today)
        months << current if last_day?(today) && !closed?(current)
        months
      end

      def self.close!(month : Time, trigger : String, prepared : Int32) : Nil
        return if closed?(month)
        MonthClose.create!(month: month_start(month), trigger: trigger, prepared: prepared, created_at: Time.utc)
      end

      # Bons à regrouper pour le mois : `{client, devise} => bons`.
      def self.candidates(month : Time, customer_id : Int64?) : Hash({Int64, String}, Array(Document))
        records = Document.filter(kind: "delivery_note", status: "issued", delivery_date__lte: month_last_day(month))
        records = records.filter(customer_id: customer_id) if customer_id
        notes = records.order(:delivery_date, :number).to_a
        held = notes.empty? ? Set(Int64).new : BilledDelivery.filter(delivery_note_id__in: notes.map { |note| Documents.id_of(note.id) }).to_a
          .map { |row| Documents.id_of(row.delivery_note_id) }.to_set
        notes = notes.reject { |note| held.includes?(Documents.id_of(note.id)) }
        unless customer_id
          monthly = CustomerBilling.filter(billing_rhythm: "monthly").to_a.map(&.card_id!.to_i64).to_set
          notes = notes.select { |note| monthly.includes?(Documents.id_of(note.customer_id)) }
        end
        notes.group_by { |note| {Documents.id_of(note.customer_id), note.currency_code!} }
      end

      # Prépare les brouillons du mois ; renvoie les lignes créées (ou
      # reprises après un refus) et le nombre de clients déjà traités.
      def self.prepare!(month : Time, customer_id : Int64?, mode : String,
                        actor : Partiduo::Api::Actor) : {Array(MonthlyInvoice), Int32}
        month = month_start(month)
        prepared = [] of MonthlyInvoice
        skipped = 0
        candidates(month, customer_id).each do |(customer, currency), notes|
          outcome = Partiduo::Api::Transaction.run do
            Marten::DB::Connection.default.open(&.exec("SELECT pg_advisory_xact_lock(hashtext($1))",
              "invoicing_monthly:#{customer}:#{month.to_s("%Y-%m")}"))
            existing = MonthlyInvoice.filter(month: month, customer_id: customer, currency_code: currency).first
            if existing && !(existing.status == "failed" && existing.invoice_id.nil?)
              next Partiduo::Api::Result(MonthlyInvoice?).success(nil)
            end
            existing.try(&.delete)
            Partiduo::Api::Result(MonthlyInvoice?).success(prepare_one(month, customer, currency, notes, mode, actor))
          end
          if row = outcome.value?
            prepared << row
          else
            skipped += 1
          end
        end
        {prepared, skipped}
      end

      private def self.prepare_one(month : Time, customer : Int64, currency : String, notes : Array(Document), mode : String,
                                   actor : Partiduo::Api::Actor) : MonthlyInvoice
        row = MonthlyInvoice.new(month: month, customer_id: customer, currency_code: currency, mode: mode,
          created_by_id: actor.user_id)
        input = DeliveryBilling.group_input(notes)
        lines, errors = Documents.check(input)
        if errors.empty?
          document = Documents.save_draft!(input, lines, actor)
          Documents.log(Documents.id_of(document.id), "created", actor, "",
            {"month" => month.to_s("%Y-%m"), "delivery_notes" => notes.map(&.number.to_s).join(",")})
          row.invoice_id = document.id
          row.status = "proposed"
        else
          row.status = "failed"
          row.error = errors.map(&.key).uniq!.join(", ")
          Log.warn { "fin de mois #{month.to_s("%Y-%m")}, client #{customer} : #{row.error}" }
        end
        row.save!
        row
      end

      # Suite de l'émission ou de l'envoi d'une facture de fin de mois.
      def self.record_outcome(invoice_id : Int64, status : String, error : String = "") : Nil
        MonthlyInvoice.filter(invoice_id: invoice_id).to_a.each do |row|
          row.status = status
          row.error = error
          row.save!
        end
      end

      def self.view(row : MonthlyInvoice) : Api::MonthlyInvoiceView
        invoice = row.invoice_id.try { |id| Document.filter(id: id.to_i64).first }
        name = invoice.try { |document| Documents.customer(document).name } ||
               Configuration.card(row.customer_id!.to_i64).try(&.name) || ""
        Api::MonthlyInvoiceView.new(
          id: row.id!.to_i64, month: row.month!, customer_card_id: row.customer_id!.to_i64, customer_name: name,
          currency_code: row.currency_code!, invoice_id: invoice.try { |document| Documents.id_of(document.id) },
          invoice_number: invoice.try(&.number), total_gross: invoice.try(&.total_gross!) || BigDecimal.new(0),
          mode: row.mode!, status: row.status!, error: row.error.to_s, created_at: row.created_at || Time.utc,
        )
      end

      # Brouillons de fin de mois encore à valider (« À traiter »).
      def self.proposals : Array(MonthlyInvoice)
        rows = MonthlyInvoice.all.exclude(invoice_id: nil).order(:month, :id).to_a
        return rows if rows.empty?
        ids = rows.compact_map(&.invoice_id.try(&.to_i64))
        drafts = Document.filter(id__in: ids, number: nil).to_a.map { |doc| Documents.id_of(doc.id) }.to_set
        rows.select { |row| row.invoice_id.try { |id| drafts.includes?(id.to_i64) } }
      end
    end
  end
end
