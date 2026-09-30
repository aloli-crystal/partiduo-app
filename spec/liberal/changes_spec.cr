# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias Api = Partiduo::Api::Liberal
private alias L = LiberalSpec

# Transmission de la 2035 de `year` telle que la publie l'extension qui la
# dépose (`partiduo-teledec`) : l'exercice est figé.
private def transmit(year : Int32, reference : String = "liasse:#{year}") : Nil
  Partiduo::Api::Transaction.run do
    Partiduo::Events.publish("tax_return.transmitted", {"form" => "2035", "year" => year.to_s, "reference" => reference,
                                                        "fingerprint" => Api.tax_return(L.system, year).fingerprint})
    Partiduo::Api::Result(Nil).success(nil)
  end
end

private def reject(year : Int32, reference : String = "liasse:#{year}") : Nil
  Partiduo::Api::Transaction.run do
    Partiduo::Events.publish("tax_return.rejected", {"form" => "2035", "year" => year.to_s, "reference" => reference})
    Partiduo::Api::Result(Nil).success(nil)
  end
end

# DECISIONS D-LIB2-001 à D-LIB2-005 : une ligne du livre-journal, une
# immobilisation ou une cession se modifie et se supprime tant que son
# exercice (année civile de la 2035) est ouvert ; l'exercice se fige à sa
# clôture au socle ou à la transmission de sa 2035 ; ensuite, correction par
# contre-passation datée dans un exercice ouvert. Deux exercices peuvent être
# ouverts à la fois.
describe_module "LIBERAL", "Livre-journal libéral modifiable tant que l'exercice est ouvert (D-LIB2)" do
  it "modifie une ligne d'un exercice ouvert, sans changer de numéro dans la même année" do
    L.setup
    line = L.expense("2026-03-10", "250", "VEHICLE", nondeductible_amount: L.d("50"))
    line.editable?.should be_true
    line.deletable?.should be_true
    line.modified_at.should be_nil
    changed = Api.update_line(L.actor, line.id, L.input("2026-03-12", "260", "OFFICE", reference: "F-9")).value!
    {changed.id, changed.number, changed.date, changed.amount, changed.heading, changed.reference, changed.kind}
      .should eq({line.id, line.number, L.date("2026-03-12"), L.d("260"), "office", "F-9", "expense"})
    changed.nondeductible_amount.should eq(L.d("0"))
    changed.modified_at.should_not be_nil
    Api.heading_totals(L.system, 2026).map { |item| {item.heading, item.amount} }.should eq([{"office", L.d("260")}])
  end

  it "applique à la modification les règles de la saisie, dans le même sens" do
    L.setup
    line = L.receipt("2026-03-10", "100")
    Api.update_line(L.actor, line.id, L.input("2026-03-10", "-1", "RECEIPTS")).error_keys
      .should eq(["liberal.errors.line.amount.not_positive"])
    # Une recette reste une recette : une nature de dépense est refusée.
    Api.update_line(L.actor, line.id, L.input("2026-03-10", "10", "OFFICE")).error_keys
      .should eq(["liberal.errors.line.nature.unknown"])
    Api.update_line(L.actor, line.id, L.input("2026-12-31", "10", "RECEIPTS")).error_keys
      .should eq(["liberal.errors.line.date.future"])
    expect_raises(Partiduo::Api::NotFound) { Api.update_line(L.actor, 999_999_i64, L.input("2026-03-10", "1", "RECEIPTS")) }
    Api.line(L.system, line.id).amount.should eq(L.d("100"))
  end

  it "renumérote une ligne déplacée dans l'autre exercice ouvert" do
    L.setup(years: [2025, 2026])
    L.receipt("2025-12-20", "10")
    line = L.receipt("2026-01-05", "100")
    line.number.should eq("J2026-00001")
    moved = Api.update_line(L.actor, line.id, L.input("2025-12-30", "100", "RECEIPTS")).value!
    moved.number.should eq("J2025-00002")
    L.receipt("2026-01-06", "5").number.should eq("J2026-00002")
  end

  it "supprime une ligne ou une contre-passation, sans reprendre le numéro" do
    L.setup
    line = L.expense("2026-03-10", "40")
    reversal = Api.reverse_line(L.actor, Api::ReverseInput.new(line.id, L.date("2026-03-11"))).value!
    # Contre-passée : ni modifiée ni supprimée ; la contre-passation se
    # supprime mais ne se modifie pas.
    Api.line(L.system, line.id).editable?.should be_false
    Api.update_line(L.actor, line.id, L.input("2026-03-10", "41", "OFFICE")).error_keys
      .should eq(["liberal.errors.line.change.reversed"])
    Api.delete_line(L.actor, line.id).error_keys.should eq(["liberal.errors.line.change.reversed"])
    reversal.editable?.should be_false
    reversal.deletable?.should be_true
    Api.update_line(L.actor, reversal.id, L.input("2026-03-11", "40", "OFFICE")).error_keys
      .should eq(["liberal.errors.line.change.is_reversal"])
    Api.delete_line(L.actor, reversal.id).value!
    Api.line(L.system, line.id).reversed_by_id.should be_nil
    Api.delete_line(L.actor, line.id).value!
    expect_raises(Partiduo::Api::NotFound) { Api.line(L.system, line.id) }
    L.expense("2026-03-12", "1").number.should eq("J2026-00003")
  end

  it "fige l'exercice clôturé au socle : lignes intangibles, contre-passation dans l'exercice ouvert" do
    L.setup(years: [2025, 2026])
    old = L.expense("2025-06-10", "40")
    L.close_year(2025)
    Api.year(L.system, 2025).state.should eq("closed")
    Api.year(L.system, 2025).closed_at.should_not be_nil
    Api.year(L.system, 2026).state.should eq("open")
    view = Api.line(L.system, old.id)
    {view.locked, view.editable?, view.deletable?, view.reversible?}.should eq({true, false, false, true})
    Api.update_line(L.actor, old.id, L.input("2025-06-10", "41", "OFFICE")).error_keys
      .should eq(["liberal.errors.line.change.closed_period"])
    Api.delete_line(L.actor, old.id).error_keys.should eq(["liberal.errors.line.change.closed_period"])
    # Une ligne de l'exercice ouvert ne se déplace pas dans l'exercice clos.
    line = L.expense("2026-02-01", "10")
    Api.update_line(L.actor, line.id, L.input("2025-12-31", "10", "OFFICE")).error_keys
      .should eq(["liberal.errors.line.date.closed_period"])
    reversal = Api.reverse_line(L.actor, Api::ReverseInput.new(old.id, L.date("2026-02-02"))).value!
    reversal.date.should eq(L.date("2026-02-02"))
    reversal.number.should start_with("J2026-")
  end

  it "fige l'exercice dont la 2035 est transmise, même non clôturé, et le libère au rejet de ce dépôt" do
    L.setup(years: [2025, 2026])
    old = L.receipt("2025-06-10", "1000")
    transmit(2025)
    year = Api.year(L.system, 2025)
    {year.state, year.reference, year.frozen?}.should eq({"transmitted", "liasse:2025", true})
    year.transmitted_at.should_not be_nil
    year.frozen_fingerprint.should eq(Api.tax_return(L.system, 2025).fingerprint)
    Api.line(L.system, old.id).locked.should be_true
    Api.line(L.system, old.id).transmitted_at.should eq(year.transmitted_at)
    Api.update_line(L.actor, old.id, L.input("2025-06-10", "1100", "RECEIPTS")).error_keys
      .should eq(["liberal.errors.line.change.transmitted"])
    Api.record_receipt(L.actor, L.input("2025-12-01", "10", "RECEIPTS")).error_keys
      .should eq(["liberal.errors.line.date.transmitted"])
    Api.add_adjustment(L.actor, Api::AdjustmentInput.new(2025, "deduction", "x", L.d("5"))).error_keys
      .should eq(["liberal.errors.adjustment.year.closed"])
    Api.set_form_line(L.actor, Api::FormLineInput.new(2025, "rent", "2035-A", "16", "BD")).error_keys
      .should contain("liberal.errors.form_line.year.closed")
    # En base aussi.
    expect_raises(Exception, /exercice figé|intangible/) do
      Partiduo::Liberal::Line.get!(id: old.id).update!(label: "autre")
    end
    # Une seconde transmission ne change rien ; un rejet d'un autre dépôt non plus.
    transmit(2025, "liasse:autre")
    reject(2025, "liasse:autre")
    Api.year(L.system, 2025).reference.should eq("liasse:2025")
    reject(2025)
    Api.year(L.system, 2025).state.should eq("open")
    Api.update_line(L.actor, old.id, L.input("2025-06-10", "1100", "RECEIPTS")).success?.should be_true
  end

  it "tient deux exercices ouverts : N-1 s'achève et sa 2035 se prépare pendant que N avance" do
    L.setup(years: [2025, 2026])
    previous = L.receipt("2025-11-15", "30000")
    current = L.receipt("2026-01-20", "2500")
    L.expense("2026-02-03", "300", "RENT")
    Api.year(L.system, 2025).open?.should be_true
    Api.year(L.system, 2026).open?.should be_true
    # La 2035 de 2025 préparée, puis recalculée après une écriture tardive
    # et une correction, sans toucher 2026.
    first = Api.tax_return(L.system, 2025)
    first.amount("receipts").should eq(L.d("30000"))
    L.expense("2025-12-28", "1200", "RENT")
    Api.update_line(L.actor, previous.id, L.input("2025-11-15", "31000", "RECEIPTS")).value!
    second = Api.tax_return(L.system, 2025)
    {second.amount("receipts"), second.amount("rent")}.should eq({L.d("31000"), L.d("1200")})
    second.fingerprint.should_not eq(first.fingerprint)
    Api.tax_return(L.system, 2026).amount("receipts").should eq(L.d("2500"))
    # Transmise, la 2035 de 2025 ne bouge plus ; 2026 reste ouvert.
    transmit(2025)
    L.expense("2026-02-04", "20", "OFFICE")
    Api.update_line(L.actor, current.id, L.input("2026-01-21", "2600", "RECEIPTS")).value!
    Api.tax_return(L.system, 2025).fingerprint.should eq(second.fingerprint)
    Api.tax_return(L.system, 2025).exercise.state.should eq("transmitted")
    Api.tax_return(L.system, 2025).controls.map(&.key).should_not contain("liberal.controls.year_open")
    Api.tax_return(L.system, 2026).amount("receipts").should eq(L.d("2600"))
    Api.tax_return(L.system, 2026).exercise.open?.should be_true
  end

  it "garde l'empreinte de la 2035 au figement et signale un écart ultérieur" do
    L.setup(years: [2025, 2026])
    L.receipt("2025-06-10", "1000")
    L.close_year(2025)
    view = Api.tax_return(L.system, 2025)
    view.exercise.frozen_fingerprint.should eq(view.fingerprint)
    view.controls.map(&.key).should_not contain("liberal.controls.frozen_changed")
    Api.update_settings(L.system, Api::SettingsInput.new(profession: "Ostéopathe",
      default_nature_id: L.nature("RECEIPTS").id)).value!
    Api.tax_return(L.system, 2025).controls.map(&.key).should contain("liberal.controls.frozen_changed")
  end

  it "modifie et supprime une immobilisation tant que son exercice est ouvert et qu'aucune année figée n'en dépend" do
    L.setup(years: [2025, 2026])
    asset = L.asset("2026-04-01", "3000", 3)
    asset.editable?.should be_true
    changed = Api.update_asset(L.actor, asset.id, Api::AssetInput.new(label: "Portable", category: "office",
      acquired_on: L.date("2026-04-02"), amount: L.d("3200"), duration_years: 4, method: "card")).value!
    {changed.number, changed.label, changed.amount, changed.duration_years}.should eq({asset.number, "Portable", L.d("3200"), 4})
    changed.modified_at.should_not be_nil
    Api.depreciation(L.system, 2026).first.amount.should eq(L.d("3200"))

    # Cession : l'immobilisation ne change plus tant que la cession existe ;
    # la cession se supprime dans l'exercice ouvert.
    Api.dispose_asset(L.actor, Api::DisposalInput.new(asset.id, L.date("2026-08-01"), L.d("1000"), "cheque")).value!
    Api.update_asset(L.actor, asset.id, Api::AssetInput.new(label: "x", category: "office",
      acquired_on: L.date("2026-04-02"), amount: L.d("1"), duration_years: 1, method: "card")).error_keys
      .should eq(["liberal.errors.asset.change.disposed"])
    Api.delete_disposal(L.actor, asset.id).value!.disposal.should be_nil
    Api.delete_disposal(L.actor, asset.id).error_keys.should eq(["liberal.errors.disposal.none"])

    # Contre-passée : la contre-passation se supprime, puis l'immobilisation.
    reversal = Api.reverse_asset(L.actor, Api::ReverseInput.new(asset.id, L.date("2026-08-02"))).value!
    Api.delete_asset(L.actor, asset.id).error_keys.should eq(["liberal.errors.line.change.reversed"])
    Api.update_asset(L.actor, reversal.id, Api::AssetInput.new(label: "x", category: "office",
      acquired_on: L.date("2026-08-02"), amount: L.d("1"), duration_years: 1, method: "card")).error_keys
      .should eq(["liberal.errors.line.change.is_reversal"])
    Api.delete_asset(L.actor, reversal.id).value!
    Api.delete_asset(L.actor, asset.id).value!
    Api.assets(L.system).should be_empty

    # Acquise en 2025, alors que 2026 est figé : elle compte dans la 2035 de
    # 2026, elle ne change plus.
    older = L.asset("2025-05-01", "900", 3)
    transmit(2026)
    Api.asset(L.system, older.id).locked.should be_true
    Api.delete_asset(L.actor, older.id).error_keys.should eq(["liberal.errors.asset.change.later_year_frozen"])
    Api.record_asset(L.actor, Api::AssetInput.new(label: "x", category: "office", acquired_on: L.date("2025-06-01"),
      amount: L.d("10"), duration_years: 1, method: "card")).error_keys
      .should eq(["liberal.errors.asset.change.later_year_frozen"])
  end

  it "refuse de modifier une immobilisation ou une cession d'un exercice clôturé" do
    L.setup(years: [2025, 2026])
    asset = L.asset("2025-03-01", "900", 3)
    Api.dispose_asset(L.actor, Api::DisposalInput.new(asset.id, L.date("2025-09-01"), L.d("400"), "cheque")).value!
    L.close_year(2025)
    view = Api.asset(L.system, asset.id)
    {view.locked, view.editable?, view.deletable?, view.disposal.try(&.locked)}.should eq({true, false, false, true})
    Api.delete_disposal(L.actor, asset.id).error_keys.should eq(["liberal.errors.line.change.closed_period"])
    Api.delete_asset(L.actor, asset.id).error_keys
      .should eq(%w[liberal.errors.asset.change.disposed liberal.errors.line.change.closed_period])
  end

  it "exige le droit de saisie et le module actif" do
    L.setup
    line = L.receipt
    reader = Partiduo::Api::Actor.user(8_i64, %w[liberal.register.read])
    expect_raises(Partiduo::Api::Forbidden) { Api.update_line(reader, line.id, L.input("2026-09-10", "1", "RECEIPTS")) }
    expect_raises(Partiduo::Api::Forbidden) { Api.delete_line(reader, line.id) }
    Api.year(reader, 2026).open?.should be_true
  end
end
