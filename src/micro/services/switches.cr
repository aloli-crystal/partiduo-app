# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Micro
    # Bascules guidées (ADR-007 D1) : vers la TVA (les articles du socle en
    # franchise prennent un taux normal, la Facturation cesse alors
    # d'apposer la mention 293 B), vers le régime réel (activation de la
    # Comptabilité par le registre du socle, puis republication des
    # registres). Aucun appel à un autre module (ADR-006 D3). Service interne.
    module Switches
      alias Api = Partiduo::Api::Micro

      FRANCHISE = "VATEX-FR-FRANCHISE"

      def self.system : Partiduo::Api::Actor
        Partiduo::Api::Actor.system
      end

      def self.franchise_rate_ids : Set(Int64)
        Partiduo::Api::Vat.rates(system, include_disabled: true).select(&.exemption_code.==(FRANCHISE)).map(&.id).to_set
      end

      def self.items_in_franchise : Array(Partiduo::Api::Cards::CardView)
        ids = franchise_rate_ids
        return [] of Partiduo::Api::Cards::CardView if ids.empty?
        cards = [] of Partiduo::Api::Cards::CardView
        offset = 0
        loop do
          page = Partiduo::Api::Cards.cards(system, Partiduo::Api::Cards::CardQuery.new(kind: "item", enabled: nil,
            limit: 500, offset: offset))
          cards.concat(page.select { |card| card.vat_rate_id.try { |id| ids.includes?(id) } })
          break if page.size < 500
          offset += 500
        end
        cards
      end

      def self.vat_plan : Api::VatSwitchPlanView
        items = items_in_franchise.map do |card|
          Api::SwitchItemView.new(card.id, card.code, card.name, card.vat_rate_code.to_s)
        end
        suggested = Partiduo::Api::Vat.rates(system).select { |rate| rate.category == "S" && rate.rate > 0 && !rate.reverse_charge }
          .max_by?(&.rate).try(&.id)
        Api::VatSwitchPlanView.new(items, suggested)
      end

      def self.to_vat(actor : Partiduo::Api::Actor, input : Api::VatSwitchInput) : Partiduo::Api::Result(Api::SettingsView)
        rate = begin
          Partiduo::Api::Vat.rate(system, input.rate_id)
        rescue Partiduo::Api::NotFound
          nil
        end
        if rate.nil? || !rate.enabled || rate.exemption_code == FRANCHISE || rate.rate <= 0
          return Partiduo::Api::Result(Api::SettingsView).failure(Registers.error("rate_id", "switch.vat.rate_invalid"))
        end
        settings = Registers.settings
        if settings.vat_liable_since
          return Partiduo::Api::Result(Api::SettingsView).failure(Registers.error("base", "switch.vat.already"))
        end
        errors = [] of Partiduo::Api::FieldError
        items_in_franchise.each do |card|
          result = Partiduo::Api::Cards.update_card(actor, card.id, card_input(card, rate.id))
          result.errors.each do |error|
            errors << Registers.error("items", "switch.vat.item_refused", {"code" => card.code, "error" => error.key})
          end
        end
        return Partiduo::Api::Result(Api::SettingsView).failure(errors) unless errors.empty?
        settings.vat_liable_since = Registers.day(input.effective_on)
        settings.save!
        Partiduo::Api::Result(Api::SettingsView).success(Registers.settings_view(settings))
      end

      def self.to_real(actor : Partiduo::Api::Actor, effective_on : Time) : Partiduo::Api::Result(Api::SettingsView)
        settings = Registers.settings
        if settings.real_regime_since
          return Partiduo::Api::Result(Api::SettingsView).failure(Registers.error("base", "switch.real.already"))
        end
        activated = Partiduo::Api::Modules.activate(actor, "ACCOUNTING")
        if activated.failure?
          return Partiduo::Api::Result(Api::SettingsView).failure(activated.errors)
        end
        settings.real_regime_since = Registers.day(effective_on)
        settings.save!
        Registers.republish(actor.user_id)
        Partiduo::Api::Result(Api::SettingsView).success(Registers.settings_view(settings))
      end

      # Saisie d'une fiche identique à `card`, au taux de TVA `rate_id`.
      def self.card_input(card : Partiduo::Api::Cards::CardView, rate_id : Int64) : Partiduo::Api::Cards::CardInput
        Partiduo::Api::Cards::CardInput.new(
          category_id: card.category_id, name: card.name, code: card.code, description: card.description,
          enabled: card.enabled, vat_number: card.vat_number, siren: card.siren, siret: card.siret,
          routing_id: card.routing_id, iban: card.iban, bic: card.bic, email: card.email, phone: card.phone,
          contact_name: card.contact_name, address: card.address.try(&.to_input),
          delivery_addresses: card.delivery_addresses.map(&.to_input), unit_code: card.unit_code,
          sale_price: card.sale_price, purchase_price: card.purchase_price, vat_rate_id: rate_id, extra: card.extra)
      end
    end
  end
end
