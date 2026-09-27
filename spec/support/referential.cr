# SPDX-License-Identifier: AGPL-3.0-or-later

require "json"

# Outils des specs du référentiel du socle (lot 1) : fiches, catégories,
# taux de TVA, exercices.
module ReferentialSpec
  def self.system : Partiduo::Api::Actor
    Partiduo::Api::Actor.system
  end

  # Chaque clé d'erreur du résultat a son message en fr, en et nl.
  def self.expect_translated(result) : Nil
    result.errors.each do |error|
      Partiduo::LOCALES.each do |locale|
        I18n.with_locale(locale) do
          message = I18n.t(error.key, error.params.merge({"max" => "1", "min" => "0"}))
          message.should_not contain("missing")
          message.should_not eq(error.key)
        end
      end
    end
  end

  def self.category(code : String = "CUSTOMER", kind : String = "customer", name : String? = nil,
                    attributes = [] of Partiduo::Api::Cards::AttributeInput) : Partiduo::Api::Cards::CategoryView
    input = Partiduo::Api::Cards::CategoryInput.new(code: code, name: name || code.capitalize, kind: kind,
      attributes: attributes)
    result = Partiduo::Api::Cards.create_category(system, input)
    result.value!
  end

  def self.card_input(category_id : Int64, name : String = "Dupont SARL", **options) : Partiduo::Api::Cards::CardInput
    Partiduo::Api::Cards::CardInput.new(category_id: category_id, name: name).copy_with(**options)
  end

  def self.card(category_id : Int64, name : String = "Dupont SARL", **options) : Partiduo::Api::Cards::CardView
    Partiduo::Api::Cards.create_card(system, card_input(category_id, name, **options)).value!
  end

  def self.vat_rate(code : String = "NOR", rate : String = "20", label : String? = nil,
                    **options) : Partiduo::Api::Vat::RateView
    input = Partiduo::Api::Vat::RateInput.new(code: code, label: label || "TVA #{code}", rate: BigDecimal.new(rate))
      .copy_with(**options)
    Partiduo::Api::Vat.create_rate(system, input).value!
  end

  def self.fiscal_year(year : Int32 = 2026, **options) : Partiduo::Api::Core::FiscalYearView
    input = Partiduo::Api::Core::FiscalYearInput.new(year: year, start_year: year).copy_with(**options)
    Partiduo::Api::Core.create_fiscal_year(system, input).value!
  end

  # Événements `name` publiés pendant le bloc (abonné temporaire du socle,
  # toujours actif).
  def self.capture_events(name : String, & : Array(Partiduo::Events::Event) ->) : Nil
    received = [] of Partiduo::Events::Event
    manifest = Partiduo::Modules["CORE"]
    previous = manifest.subscriptions[name]?.try(&.dup)
    manifest.on(name) { |event| received << event }
    begin
      yield received
    ensure
      if previous
        manifest.subscriptions[name] = previous
      else
        manifest.subscriptions.delete(name)
      end
    end
  end

  # La valeur, dont l'exemple exige la présence.
  def self.present(value : T?) : T forall T
    value.should_not be_nil
    value.as(T)
  end

  def self.date(text : String) : Time
    Time.parse_utc(text, "%Y-%m-%d")
  end

  def self.json(value) : JSON::Any
    JSON.parse(value.to_json)
  end
end
