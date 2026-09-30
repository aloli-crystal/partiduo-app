# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias Api = Partiduo::Api::Liberal

# ADR-006 D2 : tout le contrat `Partiduo::Api::Liberal` refuse l'accès
# quand le module est inactif et exige, fonction par fonction, la permission
# du manifeste (lecture, saisie, paramétrage).

private DAY = Time.utc(2026, 9, 1)

private def line_input : Partiduo::Api::Liberal::LineInput
  Api::LineInput.new(date: DAY, nature_id: 1_i64, amount: BigDecimal.new(1), method: "cash")
end

private def asset_input : Partiduo::Api::Liberal::AssetInput
  Api::AssetInput.new(label: "X", category: "office", acquired_on: DAY, amount: BigDecimal.new(1), duration_years: 1,
    method: "cash")
end

private def reads(actor : Partiduo::Api::Actor) : Array(Proc(Nil))
  query = Api::JournalQuery.new
  [
    -> { Api.settings(actor); nil },
    -> { Api.interfaces(actor); nil },
    -> { Api.natures(actor); nil },
    -> { Api.form_lines(actor); nil },
    -> { Api.lines(actor); nil },
    -> { Api.line(actor, 1_i64); nil },
    -> { Api.journal_totals(actor); nil },
    -> { Api.heading_totals(actor, 2026); nil },
    -> { Api.export_journal(actor, query, Api::ExportFormat::Csv); nil },
    -> { Api.assets(actor); nil },
    -> { Api.asset(actor, 1_i64); nil },
    -> { Api.depreciation(actor, 2026); nil },
    -> { Api.schedule(actor, 1_i64); nil },
    -> { Api.adjustments(actor, 2026); nil },
    -> { Api.tax_return(actor, 2026); nil },
    -> { Api.export_tax_return(actor, 2026); nil },
    -> { Api.year(actor, 2026); nil },
  ]
end

private def writes(actor : Partiduo::Api::Actor) : Array(Proc(Nil))
  [
    -> { Api.check_receipt(actor, line_input); nil },
    -> { Api.record_receipt(actor, line_input); nil },
    -> { Api.check_expense(actor, line_input); nil },
    -> { Api.record_expense(actor, line_input); nil },
    -> { Api.reverse_line(actor, Api::ReverseInput.new(1_i64, DAY)); nil },
    -> { Api.update_line(actor, 1_i64, line_input); nil },
    -> { Api.delete_line(actor, 1_i64); nil },
    -> { Api.check_asset(actor, asset_input); nil },
    -> { Api.record_asset(actor, asset_input); nil },
    -> { Api.reverse_asset(actor, Api::ReverseInput.new(1_i64, DAY)); nil },
    -> { Api.dispose_asset(actor, Api::DisposalInput.new(1_i64, DAY, BigDecimal.new(1), "cash")); nil },
    -> { Api.update_asset(actor, 1_i64, asset_input); nil },
    -> { Api.delete_asset(actor, 1_i64); nil },
    -> { Api.delete_disposal(actor, 1_i64); nil },
    -> { Api.add_adjustment(actor, Api::AdjustmentInput.new(2026, "deduction", "x", BigDecimal.new(1))); nil },
    -> { Api.delete_adjustment(actor, 1_i64); nil },
  ]
end

private def settings(actor : Partiduo::Api::Actor) : Array(Proc(Nil))
  [
    -> { Api.update_settings(actor, Api::SettingsInput.new); nil },
    -> { Api.load_defaults(actor); nil },
    -> { Api.create_nature(actor, Api::NatureInput.new("X", "X", "receipt", "receipts")); nil },
    -> { Api.update_nature(actor, 1_i64, Api::NatureInput.new("X", "X", "receipt", "receipts")); nil },
    -> { Api.set_form_line(actor, Api::FormLineInput.new(2026, "rent", "2035-A")); nil },
    -> { Api.delete_form_line(actor, 1_i64); nil },
    -> { Api.republish(actor); nil },
  ]
end

describe "Module liberal inactif — tout le contrat (ADR-006 D2)" do
  it "lève ModuleDisabled pour chaque fonction, même pour le système" do
    ["micro", "accounting", "accounting,invoicing,analytic,stock,followup"].each do |modules|
      with_active_modules(modules) do
        (reads(Partiduo::Api::Actor.system) + writes(Partiduo::Api::Actor.system) +
          settings(Partiduo::Api::Actor.system)).each do |call|
          expect_raises(Partiduo::Api::ModuleDisabled) { call.call }
        end
      end
    end
  end
end

describe "Permissions du module liberal (manifeste)" do
  it "déclare ses trois permissions, ses menus et aucune dépendance" do
    manifest = Partiduo::Modules["LIBERAL"]
    manifest.permissions.sort.should eq(%w[liberal.register.read liberal.register.write liberal.settings.write])
    manifest.dependencies.should be_empty
    manifest.depends_on_any.should be_empty
    manifest.menus.compact_map(&.permission).uniq!.sort!.should eq(%w[liberal.register.read liberal.settings.write])
  end

  it "refuse la lecture sans liberal.register.read" do
    with_active_modules("liberal") do
      stranger = actor_with("liberal.register.write", "liberal.settings.write")
      reads(stranger).each { |call| expect_raises(Partiduo::Api::Forbidden) { call.call } }
    end
  end

  it "refuse la saisie sans liberal.register.write" do
    with_active_modules("liberal") do
      reader = actor_with("liberal.register.read", "liberal.settings.write")
      writes(reader).each { |call| expect_raises(Partiduo::Api::Forbidden) { call.call } }
    end
  end

  it "refuse le paramétrage sans liberal.settings.write" do
    with_active_modules("liberal") do
      clerk = actor_with("liberal.register.read", "liberal.register.write")
      settings(clerk).each { |call| expect_raises(Partiduo::Api::Forbidden) { call.call } }
    end
  end
end
