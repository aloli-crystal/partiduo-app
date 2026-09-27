# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# ADR-006 D1, D3 : le socle (core, cards, vat, modules, auth) ne dépend
# d'aucun module activable. Le rattachement d'une fiche ou d'un taux de TVA à
# un compte comptable appartient à la Comptabilité, qui cite le socle ; jamais
# l'inverse.
SOCLE_DIRS    = %w[core cards vat modules auth]
MODULE_NAMES  = %w[Accounting Invoicing Analytic Stock]
MODULE_TABLES = %w[accounting_ invoicing_ analytic_ stock_]

describe "Isolation du socle (ADR-006 D3)" do
  it "ne cite ni le contrat, ni les internes, ni les tables d'un module" do
    src = File.expand_path("../../src", __DIR__)
    violations = [] of String
    SOCLE_DIRS.each do |dir|
      Dir.glob(File.join(src, dir, "**", "*.cr")).sort.each do |path|
        File.read_lines(path).each_with_index(1) do |text, number|
          next if text.lstrip.starts_with?('#')
          MODULE_NAMES.each do |name|
            if text.matches?(/\b(Api::)?#{name}::/)
              violations << "#{Path[path].relative_to(src)}:#{number} cite #{name}"
            end
          end
          MODULE_TABLES.each do |prefix|
            if text.matches?(/\b#{prefix}[a-z]/)
              violations << "#{Path[path].relative_to(src)}:#{number} cite une table #{prefix}*"
            end
          end
        end
      end
    end
    violations.should eq([] of String)
  end

  it "ne déclare ses données initiales qu'au nom des pièces du socle" do
    socle = %w[CORE CARDS VAT MODULES AUTH]
    Partiduo::Api::InitialData.all_loaders.select { |loader| socle.includes?(loader.owner) }
      .map(&.id).sort!.should eq(%w[AUTH.profiles_and_admin CARDS.categories CORE.base_currency VAT.rates])
  end
end
