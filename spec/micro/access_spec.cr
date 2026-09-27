# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias Api = Partiduo::Api::Micro
private alias M = MicroSpec

# Lot G (tests) : tout le contrat `Partiduo::Api::Micro` refuse l'accès quand
# le module est inactif (ADR-006 D2) et exige, fonction par fonction, la
# permission du manifeste (lecture, saisie, paramétrage).

private DAY = Time.utc(2026, 9, 1)

private def receipt_input : Partiduo::Api::Micro::ReceiptInput
  Api::ReceiptInput.new(date: DAY, nature_id: 1_i64, amount: BigDecimal.new(1), method: "cash")
end

private def purchase_input : Partiduo::Api::Micro::PurchaseInput
  Api::PurchaseInput.new(date: DAY, nature_id: 1_i64, amount: BigDecimal.new(1), method: "cash")
end

# Chaque fonction de lecture du contrat, appelée par `actor`.
private def reads(actor : Partiduo::Api::Actor) : Array(Proc(Nil))
  query = Api::RegisterQuery.new
  [
    -> { Api.settings(actor); nil },
    -> { Api.natures(actor); nil },
    -> { Api.item_natures(actor); nil },
    -> { Api.parameters(actor); nil },
    -> { Api.parameter_value(actor, "alert.ratio", DAY); nil },
    -> { Api.receipts(actor); nil },
    -> { Api.receipt(actor, 1_i64); nil },
    -> { Api.export_receipts(actor, query, Api::ExportFormat::Csv); nil },
    -> { Api.purchases(actor); nil },
    -> { Api.purchase(actor, 1_i64); nil },
    -> { Api.purchase_totals(actor, 2026); nil },
    -> { Api.export_purchases(actor, query, Api::ExportFormat::Pdf); nil },
    -> { Api.declarations(actor, 2026); nil },
    -> { Api.todo(actor); nil },
    -> { Api.tax_return(actor, 2026); nil },
    -> { Api.thresholds(actor, 2026); nil },
  ]
end

# Chaque fonction de saisie (`micro.register.write`).
private def writes(actor : Partiduo::Api::Actor) : Array(Proc(Nil))
  [
    -> { Api.check_receipt(actor, receipt_input); nil },
    -> { Api.record_receipt(actor, receipt_input); nil },
    -> { Api.reverse_receipt(actor, Api::ReverseInput.new(1_i64, DAY)); nil },
    -> { Api.check_purchase(actor, purchase_input); nil },
    -> { Api.record_purchase(actor, purchase_input); nil },
    -> { Api.reverse_purchase(actor, Api::ReverseInput.new(1_i64, DAY)); nil },
    -> { Api.mark_declared(actor, Api::DeclarationInput.new(DAY, DAY)); nil },
  ]
end

# Chaque fonction de paramétrage (`micro.settings.write`).
private def settings(actor : Partiduo::Api::Actor) : Array(Proc(Nil))
  [
    -> { Api.update_settings(actor, Api::SettingsInput.new); nil },
    -> { Api.load_defaults(actor); nil },
    -> { Api.create_nature(actor, Api::NatureInput.new("X", "X", "receipt", "bnc")); nil },
    -> { Api.update_nature(actor, 1_i64, Api::NatureInput.new("X", "X", "receipt", "bnc")); nil },
    -> { Api.set_item_nature(actor, 1_i64, nil); nil },
    -> { Api.set_parameter(actor, Api::ParameterInput.new("alert.ratio", DAY, BigDecimal.new(80))); nil },
    -> { Api.delete_parameter(actor, 1_i64); nil },
    -> { Api.republish(actor); nil },
    -> { Api.vat_switch_plan(actor); nil },
    -> { Api.switch_to_vat(actor, Api::VatSwitchInput.new(DAY, 1_i64)); nil },
    -> { Api.switch_to_real(actor, DAY); nil },
  ]
end

describe "Module micro inactif — tout le contrat (ADR-006 D2)" do
  it "lève ModuleDisabled pour chaque fonction, même pour le système" do
    ["invoicing", "accounting", "accounting,invoicing,analytic,stock,followup"].each do |modules|
      with_active_modules(modules) do
        (reads(M.system) + writes(M.system) + settings(M.system)).each do |call|
          expect_raises(Partiduo::Api::ModuleDisabled) { call.call }
        end
      end
    end
  end
end

describe "Permissions du module micro (manifeste)" do
  it "déclare ses trois permissions et ses menus" do
    manifest = Partiduo::Modules["MICRO"]
    manifest.permissions.sort.should eq(%w[micro.register.read micro.register.write micro.settings.write])
    manifest.dependencies.should be_empty
    manifest.depends_on_any.should be_empty
    manifest.menus.compact_map(&.permission).uniq!.sort!.should eq(%w[micro.register.read micro.settings.write])
  end

  it "refuse la lecture sans micro.register.read" do
    with_active_modules("micro") do
      stranger = actor_with("micro.register.write", "micro.settings.write", "accounting.entry.read")
      reads(stranger).each { |call| expect_raises(Partiduo::Api::Forbidden) { call.call } }
    end
  end

  it "refuse la saisie sans micro.register.write, même au lecteur et au paramétreur" do
    with_active_modules("micro") do
      reader = actor_with("micro.register.read", "micro.settings.write")
      writes(reader).each { |call| expect_raises(Partiduo::Api::Forbidden) { call.call } }
    end
  end

  it "refuse le paramétrage sans micro.settings.write" do
    with_active_modules("micro") do
      clerk = actor_with("micro.register.read", "micro.register.write")
      settings(clerk).each { |call| expect_raises(Partiduo::Api::Forbidden) { call.call } }
    end
  end
end

describe_module "MICRO", Api do
  it "laisse le lecteur tout consulter, sans rien inscrire" do
    M.setup
    M.receipt("2026-09-10", "100")
    reader = actor_with("micro.register.read")
    Api.receipts(reader).size.should eq(1)
    Api.declarations(reader, 2026).size.should eq(4)
    Api.export_receipts(reader, Api::RegisterQuery.new, Api::ExportFormat::Csv).content.size.should be > 0
    expect_raises(Partiduo::Api::Forbidden) { Api.record_receipt(reader, M.receipt_input) }
    Api.receipts(M.system).size.should eq(1)
  end
end
