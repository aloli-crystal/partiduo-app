# SPDX-License-Identifier: AGPL-3.0-or-later

# Outils des specs du module liberal (ADR-007 D6) : tout passe par le contrat
# (`Partiduo::Api::Liberal` et le socle).
module LiberalSpec
  alias Api = Partiduo::Api::Liberal

  PERMISSIONS = %w[liberal.register.read liberal.register.write liberal.settings.write cards.card.read]

  def self.system : Partiduo::Api::Actor
    Partiduo::Api::Actor.system
  end

  def self.actor : Partiduo::Api::Actor
    Partiduo::Api::Actor.user(9_i64, PERMISSIONS)
  end

  def self.d(text : String) : BigDecimal
    BigDecimal.new(text)
  end

  def self.date(text : String) : Time
    Time.parse_utc(text, "%Y-%m-%d")
  end

  # Instance FR provisionnée (natures et table de correspondance du module),
  # exercices `years` (2026 par défaut), profession renseignée.
  def self.setup(years : Array(Int32) = [2026], profession : String = "Masseur-kinésithérapeute") : Nil
    provision_instance
    years.each { |year| ReferentialSpec.fiscal_year(year) }
    Api.update_settings(system, Api::SettingsInput.new(profession: profession,
      default_nature_id: nature("RECEIPTS").id)).value!
  end

  def self.nature(code : String) : Api::NatureView
    Api.natures(system).find(&.code.==(code)) || raise "nature #{code} absente"
  end

  def self.input(on : String, amount : String, nature : String, **options) : Api::LineInput
    Api::LineInput.new(date: date(on), nature_id: nature(nature).id, amount: d(amount), method: "transfer",
      party_name: "Patient", label: nature.downcase).copy_with(**options)
  end

  def self.receipt(on : String = "2026-09-10", amount : String = "100", nature : String = "RECEIPTS",
                   **options) : Api::LineView
    result = Api.record_receipt(actor, input(on, amount, nature, **options))
    raise "recette refusée : #{result.error_keys.join(", ")}" if result.failure?
    result.value!
  end

  def self.expense(on : String = "2026-09-12", amount : String = "40", nature : String = "OFFICE",
                   **options) : Api::LineView
    result = Api.record_expense(actor, input(on, amount, nature, **options))
    raise "dépense refusée : #{result.error_keys.join(", ")}" if result.failure?
    result.value!
  end

  def self.asset(on : String = "2026-04-01", amount : String = "3000", duration : Int32 = 3,
                 category : String = "office", **options) : Api::AssetView
    input = Api::AssetInput.new(label: "Ordinateur", category: category, acquired_on: date(on), amount: d(amount),
      duration_years: duration, method: "card").copy_with(**options)
    result = Api.record_asset(actor, input)
    raise "immobilisation refusée : #{result.error_keys.join(", ")}" if result.failure?
    result.value!
  end

  def self.period(on : String) : Partiduo::Api::Core::PeriodView
    Partiduo::Api::Core.period_for(system, date(on)) || raise "pas de période au #{on}"
  end

  def self.close_period(on : String) : Nil
    Partiduo::Api::Core.close_period(system, period(on).id).value!
  end

  # Ferme toutes les périodes de l'année.
  def self.close_year(year : Int32) : Nil
    Partiduo::Api::Core.periods(system).select { |period| period.starts_on.year == year && !period.closed? }
      .sort_by!(&.starts_on).each { |period| Partiduo::Api::Core.close_period(system, period.id).value! }
  end
end
