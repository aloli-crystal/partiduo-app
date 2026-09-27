# SPDX-License-Identifier: AGPL-3.0-or-later

# Outils des specs du module micro-entreprise (ADR-007) : tout passe par le
# contrat (`Partiduo::Api::Micro` et le socle).
module MicroSpec
  alias Api = Partiduo::Api::Micro

  PERMISSIONS = %w[micro.register.read micro.register.write micro.settings.write]

  def self.system : Partiduo::Api::Actor
    Partiduo::Api::Actor.system
  end

  def self.actor : Partiduo::Api::Actor
    Partiduo::Api::Actor.user(9_i64, PERMISSIONS)
  end

  # L'utilisateur des saisies, qui dépose lui-même ses justificatifs.
  def self.uploader : Partiduo::Api::Actor
    Partiduo::Api::Actor.user(9_i64, ["core.attachment.write"])
  end

  def self.d(text : String) : BigDecimal
    BigDecimal.new(text)
  end

  def self.date(text : String) : Time
    Time.parse_utc(text, "%Y-%m-%d")
  end

  # Instance FR provisionnée (jeu de données initial des modules actifs,
  # donc natures et paramètres du module micro), exercice 2026.
  def self.setup(year : Bool = true, **settings) : Nil
    provision_instance
    ReferentialSpec.fiscal_year(2026) if year
    Api.update_settings(system, Api::SettingsInput.new.copy_with(**settings)).value! unless settings.empty?
  end

  def self.nature(code : String) : Api::NatureView
    Api.natures(system).find(&.code.==(code)) || raise "nature #{code} absente"
  end

  def self.receipt_input(on : String = "2026-09-10", amount : String = "100", nature : String = "SERVICE",
                         **options) : Api::ReceiptInput
    Api::ReceiptInput.new(date: date(on), nature_id: nature(nature).id, amount: d(amount), method: "transfer",
      party_name: "Jeanne Martin", label: "Réparation").copy_with(**options)
  end

  def self.receipt(on : String = "2026-09-10", amount : String = "100", nature : String = "SERVICE",
                   **options) : Api::LineView
    result = Api.record_receipt(actor, receipt_input(on, amount, nature, **options))
    raise "recette refusée : #{result.error_keys.join(", ")}" if result.failure?
    result.value!
  end

  def self.purchase(on : String = "2026-09-12", amount : String = "40", nature : String = "GOODS",
                    **options) : Api::LineView
    input = Api::PurchaseInput.new(date: date(on), nature_id: nature(nature).id, amount: d(amount), method: "card",
      party_name: "Grossiste SA", label: "Stock").copy_with(**options)
    result = Api.record_purchase(actor, input)
    raise "achat refusé : #{result.error_keys.join(", ")}" if result.failure?
    result.value!
  end

  # Période du socle qui contient `on`.
  def self.period(on : String) : Partiduo::Api::Core::PeriodView
    Partiduo::Api::Core.period_for(system, date(on)) || raise "pas de période au #{on}"
  end

  def self.close_period(on : String) : Nil
    Partiduo::Api::Core.close_period(system, period(on).id).value!
  end
end
