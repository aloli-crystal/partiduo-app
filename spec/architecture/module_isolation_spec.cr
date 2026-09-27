# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# ADR-006 D3 : aucun module n'appelle un autre module directement. Un module
# ne cite jamais les internes d'un autre (`Partiduo::Invoicing::…`) ; il ne cite
# son contrat (`Partiduo::Api::Invoicing`) que s'il en dépend dans son manifeste
# (`depends_on`).
#
# Seule exception (amendement proposé à ADR-006 D3, D-STK-001) : une pièce
# citée en `depends_on_any` peut être lue par son contrat, et seulement depuis
# le fichier des abonnés aux événements qu'elle publie (`DEPENDS_ON_ANY_READERS`).
DEPENDS_ON_ANY_READERS = {"stock/services/feeds.cr"}

MODULE_NAMESPACES = {
  "accounting" => {"ACCOUNTING", "Accounting"},
  "invoicing"  => {"INVOICING", "Invoicing"},
  "analytic"   => {"ANALYTIC", "Analytic"},
  "stock"      => {"STOCK", "Stock"},
  "followup"   => {"FOLLOWUP", "Followup"},
  "micro"      => {"MICRO", "Micro"},
}

describe "Isolation des modules (ADR-006 D3)" do
  it "interdit à un module de citer un autre module qu'il ne déclare pas" do
    src = File.expand_path("../../src", __DIR__)
    violations = [] of String

    MODULE_NAMESPACES.each do |dir, (code, _namespace)|
      manifest = Partiduo::Modules[code]
      Dir.glob(File.join(src, dir, "**", "*.cr")).sort.each do |path|
        declared = manifest.depends_on.dup
        declared.concat(manifest.depends_on_any.flatten) if Path[path].relative_to(src).to_s.in?(DEPENDS_ON_ANY_READERS)
        File.read_lines(path).each_with_index(1) do |text, number|
          MODULE_NAMESPACES.each_value do |other_code, other_namespace|
            next if other_code == code
            if text.matches?(/Partiduo::#{other_namespace}::|(?<!Api::)\b#{other_namespace}::[A-Z]/)
              violations << "#{Path[path].relative_to(src)}:#{number} cite les internes de #{other_code}"
            elsif text.matches?(/Api::#{other_namespace}\b/) && !declared.includes?(other_code)
              violations << "#{Path[path].relative_to(src)}:#{number} cite #{other_code} sans en dépendre"
            end
          end
        end
      end
    end

    violations.should eq([] of String)
  end
end
