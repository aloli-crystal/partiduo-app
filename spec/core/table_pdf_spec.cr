# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"
require "pdf-validate"

# Tableau neutre en PDF/A-2b pour les listes de l'interface (ADR-005 D5,
# BLOCAGES B-CRIT-001, DECISIONS D-R5-008).

private alias Core = Partiduo::Api::Core

private def input(**options) : Core::TableInput
  Core::TableInput.new(name: "tiers-20260929", title: "Tiers",
    columns: [Core::TableColumnInput.new("Code"), Core::TableColumnInput.new("Nom", weight: 3.0),
              Core::TableColumnInput.new("Solde", "amount")],
    rows: [Core::TableRowInput.new(["CLI-01", "Atelier Morel", "1 200,00"]),
           Core::TableRowInput.new(["", "Total", "1 200,00"], "total")],
    subtitle: ["Actifs"]).copy_with(**options)
end

describe "Partiduo::Api::Core.table_pdf" do
  it "rend un PDF/A-2b du tableau donné, valide pour pdf-validate" do
    provision_instance
    file = Core.table_pdf(actor_with, input).value!
    file.filename.should eq("tiers-20260929.pdf")
    file.content_type.should eq("application/pdf")
    text = String.new(file.content)
    text.should start_with("%PDF-")
    text.should contain("<pdfaid:part>2</pdfaid:part>")
    report = PDF::Validate.bytes(file.content, profile: "pdf-a-2b")
    report.fatal_failures.map(&.rule.id).should eq([] of String)
  end

  it "assainit le nom du fichier et rend un tableau large (paysage)" do
    provision_instance
    columns = (1..7).map { |index| Core::TableColumnInput.new("C#{index}") }
    wide = Core.table_pdf(actor_with, input(name: "../liste des écritures", columns: columns,
      rows: [Core::TableRowInput.new(%w[a b c d e f g])])).value!
    wide.filename.should eq("liste-des-critures.pdf")
    PDF::Validate.bytes(wide.content, profile: "pdf-a-2b").fatal_failures.should be_empty
  end

  it "refuse un tableau sans titre, sans colonne, ou dont une ligne déborde" do
    provision_instance
    result = Core.table_pdf(actor_with, input(title: " ", columns: [] of Core::TableColumnInput))
    result.error_keys.should eq(["core.errors.table.title.blank", "core.errors.table.columns.count",
                                 "core.errors.table.rows.row"])
    ReferentialSpec.expect_translated(result)
    odd = Core.table_pdf(actor_with, input(columns: [Core::TableColumnInput.new("A", "money")]))
    odd.error_keys.first.should eq("core.errors.table.columns.column")
  end

  it "refuse un acteur anonyme ou une session non élevée" do
    expect_raises(Partiduo::Api::Forbidden) { Core.table_pdf(Partiduo::Api::Actor.anonymous, input) }
    lowered = Partiduo::Api::Actor.user(3_i64, [] of String, elevated: false)
    expect_raises(Partiduo::Api::Forbidden) { Core.table_pdf(lowered, input) }
  end
end
