# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Invoicing
    # Synthèse du tableau de bord (D-2F-005) : quelques requêtes agrégées sur
    # les totaux enregistrés des documents (`Documents.store_totals`), sans
    # reconstruire la vue d'aucun document. Appelé par
    # `Partiduo::Api::Invoicing.summary` seulement.
    module Summary
      alias Api = Partiduo::Api::Invoicing

      BALANCE = "(total_gross - prepaid_amount - paid_amount - credited_amount)"
      LATE    = "status IN ('issued', 'sent', 'partially_paid') AND due_date < $1::date"

      OPEN_SQL = <<-SQL
        SELECT count(*), COALESCE(sum(#{BALANCE}), 0),
               count(*) FILTER (WHERE #{LATE}), COALESCE(sum(#{BALANCE}) FILTER (WHERE #{LATE}), 0)
        FROM invoicing_document
        WHERE kind IN ('invoice', 'deposit_invoice') AND number IS NOT NULL AND status <> 'cancelled'
          AND #{BALANCE} > 0
        SQL

      LATE_CUSTOMERS_SQL = <<-SQL
        SELECT customer_snapshot ->> 'name'
        FROM invoicing_document
        WHERE kind IN ('invoice', 'deposit_invoice') AND number IS NOT NULL AND #{LATE} AND #{BALANCE} > 0
        ORDER BY due_date, id
        LIMIT 30
        SQL

      BILLED_SQL = <<-SQL
        SELECT COALESCE(sum(CASE WHEN kind = 'credit_note' THEN -total_net ELSE total_net END), 0),
               count(*) FILTER (WHERE kind = 'invoice'), count(*) FILTER (WHERE kind = 'credit_note')
        FROM invoicing_document
        WHERE kind IN ('invoice', 'credit_note') AND number IS NOT NULL
          AND issue_date >= $1::date AND issue_date < $2::date
        SQL

      QUOTES_SQL = <<-SQL
        SELECT count(*) FILTER (WHERE validity_date IS NULL OR validity_date >= $1::date),
               COALESCE(sum(total_net) FILTER (WHERE validity_date IS NULL OR validity_date >= $1::date), 0),
               count(*) FILTER (WHERE validity_date < $1::date)
        FROM invoicing_document
        WHERE kind = 'quote' AND status = 'sent'
        SQL

      RECENT_SQL = <<-SQL
        SELECT id FROM invoicing_document WHERE kind = 'invoice'
        ORDER BY COALESCE(issue_date, created_at::date) DESC, id DESC
        LIMIT 5
        SQL

      def self.build(on : Time) : Api::SummaryView
        day = Documents.day(on)
        month_start = Time.utc(day.year, day.month, 1)
        next_month = month_start.shift(months: 1)
        zero = BigDecimal.new(0)
        open = {0, zero, 0, zero}
        billed = {zero, 0, 0}
        quotes = {0, zero, 0}
        late_names = [] of String
        recent_ids = [] of Int64
        Marten::DB::Connection.default.open do |db|
          db.query_one(OPEN_SQL, args: [day.as(::DB::Any)]) do |row|
            open = {row.read(Int64).to_i32, row.read(BigDecimal), row.read(Int64).to_i32, row.read(BigDecimal)}
          end
          late_names = db.query_all(LATE_CUSTOMERS_SQL, args: [day.as(::DB::Any)], as: String?).compact
          db.query_one(BILLED_SQL, args: [month_start.as(::DB::Any), next_month.as(::DB::Any)]) do |row|
            billed = {row.read(BigDecimal), row.read(Int64).to_i32, row.read(Int64).to_i32}
          end
          db.query_one(QUOTES_SQL, args: [day.as(::DB::Any)]) do |row|
            quotes = {row.read(Int64).to_i32, row.read(BigDecimal), row.read(Int64).to_i32}
          end
          recent_ids = db.query_all(RECENT_SQL, as: Int64)
        end
        recent = Document.filter(id__in: recent_ids).to_a.index_by { |document| Documents.id_of(document.id) }
        Api::SummaryView.new(
          on: day, open_count: open[0], open_amount: open[1], overdue_count: open[2], overdue_amount: open[3],
          overdue_customers: late_names.uniq.first(3), billed_net: billed[0], billed_invoices: billed[1],
          billed_credit_notes: billed[2], quotes_waiting_count: quotes[0], quotes_waiting_net: quotes[1],
          quotes_expired: quotes[2], drafts: Document.filter(status: "draft").count.to_i32,
          recent_invoices: recent_ids.compact_map { |id| recent[id]?.try { |document| row(document, day) } },
        )
      end

      # Ligne d'un document, lue dans ses totaux enregistrés ; nom du client
      # figé à l'émission, sinon celui de sa fiche (brouillon).
      def self.row(document : Document, on : Time) : Api::DocumentSummaryView
        balance = Payments.balance(document)
        name = document.customer_snapshot.try { |json| json["name"]?.try(&.as_s?) } ||
               Configuration.card(Documents.id_of(document.customer_id)).try(&.name) || ""
        Api::DocumentSummaryView.new(
          id: Documents.id_of(document.id), kind: document.kind!, number: document.number, status: document.status!,
          effective_status: Documents.effective_status(document, balance, on), customer_name: name,
          currency_code: document.currency_code!, total_net: document.total_net!, total_gross: document.total_gross!,
          amount_due: balance, issue_date: document.issue_date, due_date: document.due_date,
          created_at: document.created_at!,
        )
      end
    end
  end
end
