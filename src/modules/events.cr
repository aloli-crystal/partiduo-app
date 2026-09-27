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
      "payment.recorded"   => %w[payment_id],
      "payment.matched"    => %w[matching_id],
      "card.saved"         => %w[card_id],
      "period.closed"      => %w[period_id],
    }

    NAMES = SCHEMA.keys

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
        Partiduo::Modules.active_manifests.each do |manifest|
          manifest.subscriptions[name]?.try &.each(&.call(event))
        end
      end
      event
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
