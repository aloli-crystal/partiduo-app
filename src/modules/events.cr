# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  # Bus d'événements du cœur (ADR-003 D7, ADR-006 D3).
  #
  # * *Synchrone* et *dans la transaction* de l'opération : `publish` rejoint la
  #   transaction ouverte par la commande (`Partiduo::Api::Transaction.run`), ou
  #   en ouvre une s'il n'y en a pas. Un abonné qui lève une exception annule
  #   l'opération entière, publication comprise.
  # * Charge utile : des *identifiants* et des valeurs scalaires, en chaînes
  #   (`{"entry_id" => "42"}`, montants en `BigDecimal#to_s`). L'abonné relit ce
  #   dont il a besoin par `Partiduo::Api`, avec `Partiduo::Api::Actor.system`,
  #   jamais par les modèles d'un autre module.
  # * Abonnement déclaré dans le manifeste : `on("entry.posted") { |event| … }`.
  #   Seuls les abonnés des pièces *actives* sont appelés, dans l'ordre
  #   d'enregistrement des manifestes.
  # * Effet extérieur (courriel, appel réseau) : l'abonné l'enregistre par
  #   `Partiduo::Events.after_commit { … }`, exécuté après la validation.
  # * Liste fermée : un événement n'est ajouté que lorsqu'un module ou une
  #   extension en a besoin (ADR-003 D7) — ajout consigné dans DECISIONS.adoc.
  module Events
    # Événements et clés de charge utile attendues (au minimum).
    SCHEMA = {
      "entry.posted"       => %w[entry_id],
      "entry.cancelled"    => %w[entry_id],
      "invoice.issued"     => %w[invoice_id],
      "credit_note.issued" => %w[credit_note_id],
      # Bon de livraison émis (lot 6) : sortie de stock (D-STK-004).
      "delivery_note.issued" => %w[delivery_note_id],
      "payment.recorded"     => %w[payment_id],
      # Document fiscal déposé avec succès sur la plateforme agréée, publié
      # par l'extension qui le transmet (`partiduo-einvoicing`) ; la
      # Facturation le marque envoyé et en double l'envoi de la copie PDF
      # (ADR-004 D9 révisé, D-CPY-001). Clés facultatives : `platform_ref`,
      # `connector`.
      "invoice.platform_deposited" => %w[invoice_id],
      "payment.matched"            => %w[matching_id],
      "payment.unmatched"          => %w[matching_id],
      "card.saved"                 => %w[card_id],
      "period.closed"              => %w[period_id],
      # Recette ou achat inscrit au registre du module micro-entreprise
      # (ADR-007 D2, D-MIC-002) : la Comptabilité passe l'écriture.
      "micro.receipt.recorded"  => %w[receipt_id],
      "micro.purchase.recorded" => %w[purchase_id],
      # Recette, dépense ou immobilisation inscrite par le module des
      # professions libérales (ADR-007 D6, D-LIB-002) : la Comptabilité passe
      # l'écriture.
      "liberal.receipt.recorded" => %w[receipt_id],
      "liberal.expense.recorded" => %w[expense_id],
      "liberal.asset.recorded"   => %w[asset_id operation],
    }

    NAMES = SCHEMA.keys

    # Événements rejouables, consignés à chaque publication dans le journal
    # du socle (`modules_event_log`), qu'un abonné soit actif ou non : un
    # module activé plus tard y retrouve ce qu'il a manqué (ADR-006 D2,
    # D-INT-002).
    JOURNALED = %w[invoice.issued credit_note.issued payment.recorded]

    # Événement consigné dans le journal.
    record JournalEntry, id : Int64, name : String, payload : Hash(String, String), actor_user_id : Int64?,
      created_at : Time

    # Événement publié. `actor_user_id` : utilisateur à l'origine de
    # l'opération (`nil` pour un outil en ligne de commande), pour la
    # traçabilité ; l'abonné agit avec `Actor.system`.
    record Event, name : String, payload : Hash(String, String), actor_user_id : Int64? = nil do
      def [](key : String) : String
        payload[key]? || raise KeyError.new("événement #{name} sans clé #{key}")
      end

      def []?(key : String) : String?
        payload[key]?
      end
    end

    alias Handler = Event -> Nil

    def self.ensure_known!(name : String) : Nil
      raise ArgumentError.new("événement inconnu : #{name}") unless SCHEMA.has_key?(name)
    end

    # Publie un événement vers les abonnés des pièces actives, dans la
    # transaction courante. Lève `ArgumentError` pour un nom inconnu ou une clé
    # de charge utile manquante ; l'exception d'un abonné est propagée telle
    # quelle et annule la transaction.
    def self.publish(name : String, payload : Hash(String, String) = {} of String => String,
                     actor_user_id : Int64? = nil) : Event
      ensure_known!(name)
      missing = SCHEMA[name].reject { |key| payload.has_key?(key) }
      unless missing.empty?
        raise ArgumentError.new("événement #{name} : clé(s) manquante(s) #{missing.join(", ")}")
      end

      event = Event.new(name, payload, actor_user_id)
      Marten::DB::Connection.default.transaction do
        record_in_journal(event)
        Partiduo::Modules.active_manifests.each do |manifest|
          manifest.subscriptions[name]?.try &.each(&.call(event))
        end
      end
      event
    end

    # Événements consignés (`JOURNALED`) de noms `names`, dans l'ordre de
    # publication ; `ids` restreint aux entrées citées ; `where` (clé, valeur)
    # à celles dont la charge utile porte cette valeur, filtré en base.
    def self.journal(names : Enumerable(String), ids : Enumerable(Int64)? = nil,
                     where : {String, String}? = nil) : Array(JournalEntry)
      query = Partiduo::Modules::EventLog.filter(name__in: names.to_a)
      query = query.filter(id__in: ids.to_a) if ids
      if filter = where
        matching = [] of Int64
        Marten::DB::Connection.default.open do |db|
          db.query("SELECT id FROM modules_event_log WHERE name = ANY($1) AND (payload::jsonb) ->> $2 = $3",
            args: [names.to_a, filter[0], filter[1]]) do |result_set|
            result_set.each { matching << result_set.read(Int64) }
          end
        end
        return [] of JournalEntry if matching.empty?
        query = query.filter(id__in: matching)
      end
      query.order(:id).map do |row|
        payload = row.payload.try(&.as_h?).try(&.transform_values { |value| value.as_s? || value.to_s }) ||
                  {} of String => String
        JournalEntry.new(row.pk!.as(Int64), row.name.to_s, payload, row.actor_user_id.try(&.to_i64),
          row.created_at || Time.utc)
      end
    end

    private def self.record_in_journal(event : Event) : Nil
      return unless JOURNALED.includes?(event.name)
      Partiduo::Modules::EventLog.create!(name: event.name, payload: JSON.parse(event.payload.to_json),
        actor_user_id: event.actor_user_id, created_at: Time.utc)
    end

    # Codes des pièces actives abonnées à `name`.
    def self.subscribers(name : String) : Array(String)
      ensure_known!(name)
      Partiduo::Modules.active_manifests.select(&.subscriptions.has_key?(name)).map(&.code)
    end

    # Exécute le bloc après la validation de la transaction courante (effet
    # extérieur d'un abonné : il n'a pas lieu si l'opération est annulée). Hors
    # transaction, le bloc est exécuté aussitôt.
    # Dans une commande imbriquée (point de sauvegarde), le bloc est abandonné
    # si ce point est annulé (`Partiduo::Api::Transaction`, D-024).
    def self.after_commit(&block : -> Nil) : Nil
      Partiduo::Api::Transaction.after_commit(block)
    end
  end
end
