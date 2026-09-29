# SPDX-License-Identifier: AGPL-3.0-or-later

require "log"

module Partiduo
  module Micro
    # Recettes issues de la Facturation (ADR-007 D1), par ses seuls
    # événements, sans jamais citer ce module (ADR-006 D3) :
    #
    # * `invoice.issued` : la facture est relevée (client, numéro, TVA par
    #   taux, parts hors taxe par article et taux) ;
    # * `payment.recorded` (règlement saisi dans la Facturation) et
    #   `payment.matched` (encaissement lettré par la Comptabilité) : la
    #   somme encaissée devient une recette, ventilée par nature selon les
    #   articles de la facture (nature de l'article, sinon nature par
    #   défaut), TVA au prorata du TTC, répartie entre natures selon leurs
    #   parts à chaque taux. Un règlement saisi dans la Facturation n'est
    #   compté qu'une fois même quand la Comptabilité le lettre ensuite : le
    #   montant de `payment.matched` exclut les encaissements `payment:`
    #   (`Matchings::RECORDED_PREFIX`, D-MIC-005) ;
    # * `payment.unmatched` : toutes les recettes issues d'un lettrage des
    #   factures citées (`matching:<id>:invoice:<id>`, y compris celles des
    #   lettrages absorbés par le lettrage défait) sont contre-passées à la
    #   date du jour, comme la Facturation retire tous les règlements venus
    #   d'un lettrage.
    #
    # Un encaissement daté dans une période URSSAF déjà déclarée est inscrit
    # à la date du jour (D-MIC2-001). Une référence (`payment:<id>`,
    # `matching:<id>:invoice:<id>`) n'est inscrite qu'une fois. Un échec est consigné et ne bloque jamais
    # l'opération d'origine (point de sauvegarde). Service interne.
    module Feeds
      Log = ::Log.for("partiduo.micro")

      alias Api = Partiduo::Api::Micro

      def self.on_event(event : Partiduo::Events::Event) : Nil
        result = Partiduo::Api::Transaction.run do
          case event.name
          when "invoice.issued"    then invoice_issued(event.payload)
          when "payment.recorded"  then payment_recorded(event)
          when "payment.matched"   then payment_matched(event)
          when "payment.unmatched" then payment_unmatched(event)
          end
          Partiduo::Api::Result(Nil).success(nil)
        end
        Log.warn { "#{event.name} #{event.payload} : recette non inscrite" } if result.failure?
      rescue ex
        Log.warn(exception: ex) { "#{event.name} #{event.payload} : recette non inscrite" }
      end

      # --- Factures ---------------------------------------------------------------------

      def self.invoice_issued(payload : Hash(String, String)) : Nil
        return unless payload["kind"]?.in?(nil, "invoice", "deposit_invoice")
        invoice_id = payload["invoice_id"].to_i64
        return if Invoice.filter(invoice_id: invoice_id).exists?
        shares = rows(payload["sales"]?).map do |row|
          {"item_card_id" => row["item_card_id"]?, "vat_rate_id" => row["vat_rate_id"]?, "amount" => row["amount"]?}
        end
        vats = rows(payload["vat"]?).map { |row| {"vat_rate_id" => row["vat_rate_id"]?, "amount" => row["amount"]?} }
        Invoice.create!(invoice_id: invoice_id, number: payload["number"]?.to_s, card_id: payload["customer_card_id"]?.try(&.to_i64?),
          issue_date: parse_date(payload["issue_date"]?), total_vat: decimal(payload["total_vat"]?),
          total_gross: decimal(payload["total_gross"]?), shares: shares.to_json, vats: vats.to_json)
      end

      # Facture relevée ; à défaut (module activé après l'émission), relue
      # dans le journal des événements du socle (filtré en base sur
      # `invoice_id`).
      def self.invoice(invoice_id : Int64) : Invoice?
        Invoice.filter(invoice_id: invoice_id).first || begin
          entry = Partiduo::Events.journal(["invoice.issued"], where: {"invoice_id", invoice_id.to_s}).first?
          entry.try do |found|
            invoice_issued(found.payload)
            Invoice.filter(invoice_id: invoice_id).first
          end
        end
      end

      # --- Encaissements ----------------------------------------------------------------

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

      # Contre-passe les recettes vivantes issues d'un lettrage de chaque
      # facture citée (`sources`), quel que soit ce lettrage : un lettrage
      # qui en a absorbé d'autres (fusion) ne publie que son surplus, et le
      # défaire rouvre toute la facture. Sans facture citée, celles du seul
      # lettrage défait.
      def self.payment_unmatched(event : Partiduo::Events::Event) : Nil
        today = Partiduo::Config.today
        invoices = event["sources"]?.to_s.split(',').map(&.strip).select(&.matches?(/\Ainvoice:\d+\z/))
        rows = if invoices.empty?
                 Receipt.filter(source__startswith: "matching:#{event["matching_id"]}:", reversal_of_id__isnull: true).to_a
               else
                 invoices.flat_map do |source|
                   Receipt.filter(source__startswith: "matching:", source__endswith: ":#{source}", reversal_of_id__isnull: true).to_a
                 end
               end
        rows.uniq!(&.pk).sort_by!(&.pk!.as(Int64)).each do |row|
          next if Receipt.filter(reversal_of_id: row.pk).exists?
          input = Api::ReverseInput.new(row.pk!.as(Int64), Math.max(today, row.date!))
          errors = Registers.reverse_errors(row, input, manual: false)
          raise "contre-passation refusée : #{errors.map(&.key).join(", ")}" unless errors.empty?
          Registers.reverse_receipt!(row, input, event.actor_user_id, manual: false)
        end
      end

      # Inscrit l'encaissement `amount` de la facture, ventilé par nature.
      def self.record(invoice_id : Int64, amount : BigDecimal, date : Time, method : String, source : String,
                      actor_user_id : Int64?) : Nil
        return if Receipt.filter(source: source, reversal_of_id__isnull: true).exists?
        invoice = invoice(invoice_id) || raise "facture #{invoice_id} inconnue du module micro"
        # Encaissement d'une période URSSAF déjà déclarée : inscrit à la date
        # du jour, reporté sur la déclaration suivante (D-MIC2-001).
        date = Partiduo::Config.today if Registers.declared?(date)
        amount = amount.round(2, mode: :ties_away)
        return unless amount > 0
        gross = invoice.total_gross!
        vat = gross > 0 ? (amount * invoice.total_vat! / gross).round(2, mode: :ties_away) : BigDecimal.new(0)
        vat = BigDecimal.new(0) if vat >= amount || vat < 0
        parts = split(invoice, amount, vat)
        parts.each do |nature_id, (part, part_vat)|
          next unless part > 0
          input = Api::ReceiptInput.new(date: date, nature_id: nature_id, amount: part, method: method,
            card_id: invoice.card_id.try(&.to_i64), label: invoice.number.to_s,
            reference: invoice.number.to_s, vat_amount: part_vat >= part ? BigDecimal.new(0) : part_vat)
          errors = Registers.receipt_errors(input, manual: false)
          raise "recette refusée : #{errors.map(&.key).join(", ")}" unless errors.empty?
          Registers.create_receipt!(input, actor_user_id, "invoicing", source)
        end
      end

      # Ventilation d'un encaissement et de sa TVA par nature. La TVA de
      # chaque taux (`vats`) est répartie sur les natures au prorata de
      # leurs parts hors taxe à ce taux ; l'encaissement se ventile au
      # prorata du TTC de chaque nature, sa TVA au prorata de la TVA de
      # chaque nature. Sans TVA par taux (facture relevée avant cette
      # règle), TVA et encaissement suivent les parts hors taxe. Le reste
      # d'arrondi va à la plus grande part.
      def self.split(invoice : Invoice, amount : BigDecimal, vat : BigDecimal) : Hash(Int64, {BigDecimal, BigDecimal})
        zero = BigDecimal.new(0)
        default = default_nature || raise "aucune nature de recette active"
        net = {} of Int64 => BigDecimal
        net_by_rate = {} of String => Hash(Int64, BigDecimal)
        rows(invoice.shares.to_s).each do |row|
          nature_id = row["item_card_id"]?.try(&.to_i64?).try { |card_id| item_nature(card_id) } || default
          part = decimal(row["amount"]?)
          net[nature_id] = net.fetch(nature_id, zero) + part
          rate = net_by_rate[row["vat_rate_id"]?.to_s] ||= {} of Int64 => BigDecimal
          rate[nature_id] = rate.fetch(nature_id, zero) + part
        end
        net = {default => BigDecimal.new(1)} if net.empty? || net.values.sum(zero) <= 0
        net.reject! { |_, weight| weight <= 0 }

        taxes = taxes(invoice, net, net_by_rate)
        if taxes.values.sum(zero) <= 0
          weights = net
          vat_weights = net
        else
          weights = net.to_h { |nature_id, part| {nature_id, part + taxes[nature_id]} }
          vat_weights = taxes
        end
        amounts = allocate(amount, weights)
        vats = vat_weights.values.sum(zero) > 0 ? allocate(vat, vat_weights) : weights.transform_values { zero }
        amounts.to_h { |nature_id, part| {nature_id, {part, vats[nature_id]? || zero}} }
      end

      # TVA de la facture par nature : celle de chaque taux répartie sur les
      # natures au prorata de leurs parts hors taxe à ce taux (zéro sans TVA
      # par taux relevée).
      def self.taxes(invoice : Invoice, net : Hash(Int64, BigDecimal),
                     net_by_rate : Hash(String, Hash(Int64, BigDecimal))) : Hash(Int64, BigDecimal)
        taxes = net.transform_values { BigDecimal.new(0) }
        rows(invoice.vats.to_s).each do |row|
          weights = (net_by_rate[row["vat_rate_id"]?.to_s]? || next).select { |nature_id, weight| net.has_key?(nature_id) && weight > 0 }
          total = decimal(row["amount"]?)
          next if weights.empty? || total <= 0
          allocate(total, weights).each { |nature_id, part| taxes[nature_id] += part }
        end
        taxes
      end

      def self.allocate(total : BigDecimal, weights : Hash(Int64, BigDecimal)) : Hash(Int64, BigDecimal)
        sum = weights.values.sum(BigDecimal.new(0))
        return weights.transform_values { BigDecimal.new(0) } if sum.zero?
        parts = weights.transform_values { |weight| (total * weight / sum).round(2, mode: :ties_away) }
        rest = total - parts.values.sum(BigDecimal.new(0))
        largest = weights.max_by { |_, weight| weight }[0]
        parts[largest] += rest
        parts
      end

      def self.default_nature : Int64?
        id = Registers.settings.default_nature_id.try(&.to_i64)
        return id if id && Nature.filter(id: id, kind: "receipt", enabled: true).exists?
        Nature.filter(kind: "receipt", enabled: true).order(:id).first.try(&.pk!.as(Int64))
      end

      def self.item_nature(card_id : Int64) : Int64?
        row = ItemNature.filter(item_card_id: card_id).first || return
        nature_id = row.nature_id!.to_i64
        Nature.filter(id: nature_id, enabled: true).exists? ? nature_id : nil
      end

      # --- Outils -----------------------------------------------------------------------

      # Mode de règlement de la Facturation → mode du livre des recettes.
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

      def self.rows(text : String?) : Array(Hash(String, String?))
        return [] of Hash(String, String?) if text.nil? || text.strip.empty?
        JSON.parse(text).as_a.map do |row|
          row.as_h.transform_values { |value| value.raw.nil? ? nil : (value.as_s? || value.to_s) }
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
