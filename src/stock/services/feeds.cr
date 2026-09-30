# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Stock
    # Mouvements automatiques (D-STK-004), héritiers de
    # `Stock_Goods::insert_goods` appelé par la saisie des achats et des
    # ventes d'origine :
    #
    # * Facturation — `delivery_note.issued` : sortie des articles livrés ;
    #   `invoice.issued` : sortie, sauf facture d'acompte, lignes issues d'un
    #   bon de livraison (facture d'un ou de plusieurs bons, facture
    #   récapitulative : D-INV2-006) et facture d'un document déjà livré ;
    #   `credit_note.issued` : retour en stock ;
    # * Comptabilité — `entry.posted` d'un journal d'achats (entrée, coût
    #   unitaire = hors taxe ÷ quantité) ou de ventes (sortie), sauf écriture
    #   produite par la Facturation (`invoice:`, `credit_note:`), déjà
    #   comptée ; une extourne inverse les mouvements de l'écriture annulée.
    #
    # Seuls les articles suivis (`Item`) bougent, dans le dépôt par défaut ;
    # sans dépôt par défaut, rien n'est inscrit. Une référence (`source`) déjà
    # inscrite ne l'est pas deux fois. Un échec est consigné et n'annule
    # jamais l'opération d'origine (point de sauvegarde).
    module Feeds
      Log = ::Log.for("partiduo.stock")

      BILLING_SOURCES = {"invoice:", "credit_note:", "payment:"}

      def self.system : Partiduo::Api::Actor
        Partiduo::Api::Actor.system
      end

      def self.on_event(event : Partiduo::Events::Event) : Nil
        Partiduo::Api::Transaction.run do
          case event.name
          when "delivery_note.issued" then from_document(event["delivery_note_id"].to_i64)
          when "invoice.issued"       then from_document(event["invoice_id"].to_i64)
          when "credit_note.issued"   then from_document(event["credit_note_id"].to_i64)
          when "entry.posted"         then from_entry(event["entry_id"].to_i64)
          end
          Partiduo::Api::Result(Nil).success(nil)
        end
        nil
      rescue ex
        Log.warn(exception: ex) { "#{event.name} #{event.payload} : mouvement de stock non inscrit" }
      end

      # --- Facturation ----------------------------------------------------------------

      def self.from_document(id : Int64) : Nil
        document = Partiduo::Api::Invoicing.document(system, id)
        return unless document.kind.in?("delivery_note", "invoice", "credit_note")
        from_notes = from_notes?(document)
        return if document.kind == "invoice" && !from_notes && delivered?(document)
        source = "#{document.kind}:#{id}"
        return if Movement.filter(source: source).exists?
        repository = Movements.default_repository || return
        date = document.issue_date || Partiduo::Config.today
        lines = item_lines(document, from_notes)
        items = Movements.items_by_card(lines.map(&.[0]))
        comment = document.number.to_s
        lines.each do |(card_id, line)|
          item = items[card_id]? || next
          # Quantité signée vue du stock : la livraison et la facture sortent,
          # l'avoir rentre ; une ligne à quantité négative inverse le sens
          # (retour de marchandise, `$nNeg` de `Acc_Ledger_Sale::insert`).
          signed = document.kind == "credit_note" ? line.quantity : -line.quantity
          next if signed.zero?
          Movements.create!(repository.pk!.as(Int64), item, signed > 0 ? "in" : "out", signed.abs, date,
            comment: comment, source: source, created_by_id: document.issued_by_id)
        end
      end

      # Facture de bons de livraison (D-INV2-006) : les lignes qui citent un
      # bon sont déjà sorties par lui, les autres (ajoutées à la facture)
      # sortent.
      def self.from_notes?(document : Partiduo::Api::Invoicing::DocumentView) : Bool
        document.kind == "invoice" && document.lines.any?(&.delivery_note_id)
      end

      # Lignes d'articles `{fiche, ligne}` ; `skip_notes` : sans celles qui
      # citent un bon de livraison (déjà sorties par lui).
      private def self.item_lines(document : Partiduo::Api::Invoicing::DocumentView, skip_notes : Bool)
        document.lines.compact_map do |line|
          next if skip_notes && line.delivery_note_id
          line.item_card_id.try { |card_id| {card_id, line} } if line.kind == "item"
        end
      end

      # Profondeur maximale parcourue dans la chaîne documentaire (devis,
      # commande, bon de livraison, facture) : garde-fou contre un cycle.
      CHAIN_DEPTH = 6

      # Facture dont les articles sont déjà sortis : issue d'un bon de
      # livraison, ou rattachée à une chaîne documentaire (ascendants et
      # leurs descendants, profondeur bornée) qui compte un bon de livraison
      # émis. Couvre « devis → commande → bon de livraison » puis « facture
      # tirée du devis » (D-STK-004, D-STK-010).
      def self.delivered?(invoice : Partiduo::Api::Invoicing::DocumentView) : Bool
        source = invoice.source || return false
        return true if source.kind == "delivery_note"
        # Racine de la chaîne : on remonte les documents sources.
        root = Partiduo::Api::Invoicing.document(system, source.id)
        CHAIN_DEPTH.times do
          parent = root.source || break
          return true if parent.kind == "delivery_note" && !parent.number.nil?
          root = Partiduo::Api::Invoicing.document(system, parent.id)
        end
        # Descendants de la racine, en largeur, sans repasser par un document vu.
        seen = Set{invoice.id, root.id}
        frontier = [root]
        CHAIN_DEPTH.times do
          following = [] of Partiduo::Api::Invoicing::DocumentView
          frontier.each do |document|
            document.derived.each do |link|
              next unless seen.add?(link.id)
              return true if link.kind == "delivery_note" && !link.number.nil?
              following << Partiduo::Api::Invoicing.document(system, link.id)
            end
          end
          break if following.empty?
          frontier = following
        end
        false
      end

      # --- Comptabilité ----------------------------------------------------------------

      def self.from_entry(id : Int64) : Nil
        entry = Partiduo::Api::Accounting.entry(system, id)
        return if BILLING_SOURCES.any? { |prefix| entry.source.starts_with?(prefix) }
        source = "entry:#{id}"
        return if Movement.filter(source: source).exists?
        if original = entry.reversal_of_id
          reverse(original, source, entry.date)
          return
        end
        return unless entry.ledger_kind.purchase? || entry.ledger_kind.sale?
        repository = Movements.default_repository || return
        from_lines(entry, repository.pk!.as(Int64), source)
      end

      # Lignes d'articles saisies (ni ligne de TVA `tax`, ni tiers, ni ligne
      # calculée).
      # Achat : débit = entrée au coût unitaire hors taxe ; vente : crédit =
      # sortie ; l'avoir inverse le sens.
      private def self.from_lines(entry : Partiduo::Api::Accounting::EntryView, repository_id : Int64, source : String) : Nil
        lines = entry.lines.compact_map do |line|
          line.card_id.try { |card_id| {card_id, line} } if item_line?(line.input_index, line.vat_role)
        end
        items = Movements.items_by_card(lines.map(&.[0]))
        comment = entry.label.presence || entry.internal_code
        lines.each do |(card_id, line)|
          item = items[card_id]? || next
          quantity = (line.quantity || BigDecimal.new(1)).abs
          next if quantity.zero?
          entering = line.side.debit?
          unit_cost = entry.ledger_kind.purchase? && entering ? (line.amount / quantity).round(4, mode: :ties_away) : nil
          Movements.create!(repository_id, item, entering ? "in" : "out", quantity, entry.date, unit_cost: unit_cost,
            comment: comment, source: source, created_by_id: entry.created_by_id)
        end
      end

      # Ligne d'article : saisie (`input_index`) et ni ligne de TVA (`tax`),
      # ni rôle inconnu ; la Comptabilité ne pose que `base` et `tax`.
      def self.item_line?(input_index : Int32?, vat_role : String?) : Bool
        !input_index.nil? && (vat_role.nil? || vat_role == "base")
      end

      # Extourne : mouvements inverses de ceux de l'écriture annulée, à la
      # date de l'extourne ; la sortie qui annule une entrée garde son coût,
      # qui se retranche de la valorisation (D-STK-005).
      private def self.reverse(original_id : Int64, source : String, date : Time) : Nil
        Movement.filter(source: "entry:#{original_id}").order(:id).each do |movement|
          Movement.create!(repository_id: movement.repository_id, card_id: movement.card_id,
            stock_code: movement.stock_code, direction: movement.direction == "in" ? "out" : "in",
            quantity: movement.quantity, unit_cost: movement.unit_cost, date: Movements.day(date),
            comment: movement.comment, source: source, created_by_id: movement.created_by_id)
        end
      end
    end
  end
end
