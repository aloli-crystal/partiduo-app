# SPDX-License-Identifier: AGPL-3.0-or-later

require "log"

module Partiduo
  module Liberal
    # Recettes issues de la Facturation (ADR-007 D6), par ses seuls
    # événements, sans jamais citer ce module (ADR-006 D3) :
    #
    # * `invoice.issued` : la facture est relevée (client, numéro) ;
    # * `payment.recorded` (règlement saisi dans la Facturation) et
    #   `payment.matched` (encaissement lettré par la Comptabilité) : la
    #   somme encaissée, toutes taxes comprises (comptabilité de trésorerie),
    #   devient une recette de la nature par défaut des paramètres ;
    # * `payment.unmatched` : les recettes issues d'un lettrage des factures
    #   citées sont contre-passées à la date du jour (comme D-MIC-016).
    #
    # Un encaissement daté dans un exercice figé ou une période close est
    # inscrit à la date du jour, dans l'exercice ouvert (DECISIONS
    # D-LIB2-001, comme D-MIC2-001).
    #
    # Une référence (`payment:<id>`, `matching:<id>:invoice:<id>`) n'est
    # inscrite qu'une fois. Un échec est consigné et ne bloque jamais
    # l'opération d'origine (point de sauvegarde). Service interne.
    module Feeds
      Log = ::Log.for("partiduo.liberal")

      alias Api = Partiduo::Api::Liberal

      def self.on_event(event : Partiduo::Events::Event) : Nil
        result = Partiduo::Api::Transaction.run do
          case event.name
          when "invoice.issued"    then invoice_issued(event.payload)
          when "payment.recorded"  then payment_recorded(event)
          when "payment.matched"   then payment_matched(event)
          when "payment.unmatched" then payment_unmatched(event)
          when "payment.rejected"  then payment_rejected(event)
          end
          Partiduo::Api::Result(Nil).success(nil)
        end
        Log.warn { "#{event.name} #{event.payload} : recette non inscrite" } if result.failure?
      rescue ex
        Log.warn(exception: ex) { "#{event.name} #{event.payload} : recette non inscrite" }
      end

      def self.invoice_issued(payload : Hash(String, String)) : Nil
        return unless payload["kind"]?.in?(nil, "invoice", "deposit_invoice")
        invoice_id = payload["invoice_id"].to_i64
        return if Invoice.filter(invoice_id: invoice_id).exists?
        Invoice.create!(invoice_id: invoice_id, number: payload["number"]?.to_s,
          card_id: payload["customer_card_id"]?.try(&.to_i64?))
      end

      # Facture relevée ; à défaut (module activé après l'émission), relue
      # dans le journal des événements du socle.
      def self.invoice(invoice_id : Int64) : Invoice?
        Invoice.filter(invoice_id: invoice_id).first || begin
          entry = Partiduo::Events.journal(["invoice.issued"], where: {"invoice_id", invoice_id.to_s}).first?
          entry.try do |found|
            invoice_issued(found.payload)
            Invoice.filter(invoice_id: invoice_id).first
          end
        end
      end

      def self.payment_recorded(event : Partiduo::Events::Event) : Nil
        payload = event.payload
        invoice_id = payload["invoice_id"]?.try(&.to_i64?) || return
        date = parse_date(payload["paid_on"]?) || Partiduo::Config.today
        record(invoice_id, decimal(payload["amount"]?), date, method(payload["method"]?), "payment:#{payload["payment_id"]}",
          event.actor_user_id)
      end

      def self.payment_matched(event : Partiduo::Events::Event) : Nil
        payload = event.payload
        amounts = amounts(payload["amounts"]?.to_s)
        date = parse_date(payload["matched_on"]?) || Partiduo::Config.today
        payload["sources"]?.to_s.split(',').map(&.strip).each do |source|
          kind, _, id = source.partition(':')
          invoice_id = id.to_i64?
          next unless kind == "invoice" && invoice_id
          amount = amounts[source]? || next
          next unless amount > 0
          record(invoice_id, amount, date, "transfer", "matching:#{payload["matching_id"]}:#{source}", event.actor_user_id)
        end
      end

      # Règlement saisi rejeté par la banque (D-INV3-008) : sa recette
      # (`payment:<id>`) est contre-passée à la date du rejet (la date du
      # jour si la période est close). Un règlement venu d'un lettrage l'est
      # par `payment.unmatched`, que publie la Comptabilité.
      def self.payment_rejected(event : Partiduo::Events::Event) : Nil
        return unless event["source"]? == "manual"
        date = parse_date(event["rejected_on"]?) || Partiduo::Config.today
        Line.filter(source: "payment:#{event["payment_id"]}", reversal_of_id__isnull: true).order(:id).each do |row|
          next if Line.filter(reversal_of_id: row.pk).exists?
          input = Api::ReverseInput.new(row.pk!.as(Int64), Math.max(date, row.date!))
          errors = Registers.reverse_errors(row, input, manual: false)
          input = Api::ReverseInput.new(row.pk!.as(Int64), Math.max(Partiduo::Config.today, row.date!)) unless errors.empty?
          errors = Registers.reverse_errors(row, input, manual: false)
          raise "contre-passation refusée : #{errors.map(&.key).join(", ")}" unless errors.empty?
          Registers.reverse!(row, input, event.actor_user_id, manual: false)
        end
      end

      def self.payment_unmatched(event : Partiduo::Events::Event) : Nil
        today = Partiduo::Config.today
        invoices = event["sources"]?.to_s.split(',').map(&.strip).select(&.matches?(/\Ainvoice:\d+\z/))
        rows = if invoices.empty?
                 Line.filter(source__startswith: "matching:#{event["matching_id"]}:", reversal_of_id__isnull: true).to_a
               else
                 invoices.flat_map do |source|
                   Line.filter(source__startswith: "matching:", source__endswith: ":#{source}", reversal_of_id__isnull: true).to_a
                 end
               end
        rows.uniq!(&.pk).sort_by!(&.pk!.as(Int64)).each do |row|
          next if Line.filter(reversal_of_id: row.pk).exists?
          input = Api::ReverseInput.new(row.pk!.as(Int64), Math.max(today, row.date!))
          errors = Registers.reverse_errors(row, input, manual: false)
          raise "contre-passation refusée : #{errors.map(&.key).join(", ")}" unless errors.empty?
          Registers.reverse!(row, input, event.actor_user_id, manual: false)
        end
      end

      # Inscrit l'encaissement `amount` de la facture.
      def self.record(invoice_id : Int64, amount : BigDecimal, date : Time, method : String, source : String,
                      actor_user_id : Int64?) : Nil
        return if Line.filter(source: source, reversal_of_id__isnull: true).exists?
        invoice = invoice(invoice_id) || raise "facture #{invoice_id} inconnue du module liberal"
        amount = amount.round(2, mode: :ties_away)
        return unless amount > 0
        date = Partiduo::Config.today if Registers.locked_on?(date)
        nature_id = default_nature || raise "aucune nature de recette active"
        input = Api::LineInput.new(date: date, nature_id: nature_id, amount: amount, method: method,
          card_id: invoice.card_id.try(&.to_i64), label: invoice.number.to_s, reference: invoice.number.to_s)
        errors = Registers.line_errors("receipt", input, manual: false)
        raise "recette refusée : #{errors.map(&.key).join(", ")}" unless errors.empty?
        Registers.create_line!("receipt", input, actor_user_id, "invoicing", source)
      end

      # Nature des paramètres, sinon première nature de recette active de la
      # rubrique `receipts`.
      def self.default_nature : Int64?
        id = Registers.settings?.try(&.default_nature_id).try(&.to_i64)
        return id if id && Nature.filter(id: id, kind: "receipt", enabled: true).exists?
        Nature.filter(kind: "receipt", heading: "receipts", enabled: true).order(:id).first.try(&.pk!.as(Int64))
      end

      def self.method(value : String?) : String
        text = value.to_s
        Api::METHODS.includes?(text) ? text : "other"
      end

      def self.amounts(text : String) : Hash(String, BigDecimal)
        text.split(';').each_with_object({} of String => BigDecimal) do |pair, result|
          source, _, amount = pair.partition('=')
          next if source.strip.empty? || amount.strip.empty?
          result[source.strip] = BigDecimal.new(amount.strip)
        end
      end

      def self.decimal(text : String?) : BigDecimal
        text.try(&.strip).presence.try { |value| BigDecimal.new(value) } || BigDecimal.new(0)
      end

      def self.parse_date(text : String?) : Time?
        text.try(&.strip).presence.try { |value| Time.parse_utc(value, "%Y-%m-%d") }
      rescue Time::Format::Error
        nil
      end
    end
  end
end
