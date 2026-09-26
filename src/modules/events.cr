# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  # Événements du cœur (ADR-003 D7, ADR-006 D3).
  #
  # * *Synchrones*, publiés *dans la transaction* de l'opération : un abonné qui
  #   lève une exception annule l'opération entière.
  # * Charge utile : des *identifiants* et des valeurs scalaires, en chaînes
  #   (`{"entry_id" => "42"}`, montants en `BigDecimal#to_s`). L'abonné relit ce
  #   dont il a besoin par `Partiduo::Api`, jamais par les modèles d'un autre module.
  # * Seuls les abonnés des pièces *actives* sont appelés.
  # * Liste fermée : un événement n'est ajouté que lorsqu'un module ou une
  #   extension en a besoin (ADR-003 D7) — ajout consigné dans DECISIONS.adoc.
  module Events
    NAMES = %w[
      entry.posted
      entry.cancelled
      invoice.issued
      credit_note.issued
      payment.recorded
      payment.matched
      card.saved
      period.closed
    ]

    record Event, name : String, payload : Hash(String, String) do
      def [](key : String) : String
        payload[key]
      end

      def []?(key : String) : String?
        payload[key]?
      end
    end

    alias Handler = Event -> Nil

    def self.ensure_known!(name : String) : Nil
      raise ArgumentError.new("événement inconnu : #{name}") unless NAMES.includes?(name)
    end

    # Publie un événement vers les abonnés des pièces actives, dans l'ordre
    # d'enregistrement des manifestes.
    def self.publish(name : String, payload : Hash(String, String) = {} of String => String) : Event
      ensure_known!(name)
      event = Event.new(name, payload)
      Partiduo::Modules.active_manifests.each do |manifest|
        manifest.subscriptions[name]?.try &.each(&.call(event))
      end
      event
    end
  end
end
