# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias Api = Partiduo::Api::Liberal
private alias L = LiberalSpec

# Transmission de la 2035 de `year` telle que la publie l'extension qui la
# dépose (`partiduo-teledec`).
private def transmit(year : Int32, reference : String = "liasse:#{year}") : Nil
  Partiduo::Api::Transaction.run do
    Partiduo::Events.publish("tax_return.transmitted", {"form" => "2035", "year" => year.to_s, "reference" => reference,
                                                        "fingerprint" => Api.tax_return(L.system, year).fingerprint},
      actor_user_id: L.actor.user_id)
    Partiduo::Api::Result(Nil).success(nil)
  end
end

private def reject(year : Int32, reference : String = "liasse:#{year}") : Nil
  Partiduo::Api::Transaction.run do
    Partiduo::Events.publish("tax_return.rejected", {"form" => "2035", "year" => year.to_s, "reference" => reference})
    Partiduo::Api::Result(Nil).success(nil)
  end
end

private def actions(year : Int32) : Array(String)
  Api.year_history(L.system, year).map(&.action)
end

# DECISIONS D-LIB5-001 à D-LIB5-003 : l'exercice libéral est ouvert,
# clôturé (par le professionnel, réversible) ou verrouillé (2035 transmise,
# définitif ; le rejet de ce dépôt le rend clôturé).
describe_module "LIBERAL", "Clôture réversible et verrou de l'exercice libéral (D-LIB5)" do
  it "passe d'ouvert à clôturé, rouvert, de nouveau clôturé puis verrouillé, chaque passage tracé" do
    L.setup(years: [2025, 2026])
    line = L.expense("2025-06-10", "40")
    asset = L.asset("2025-04-01", "1200")
    Api.year(L.system, 2025).state.should eq("open")
    Api.year(L.system, 2025).closable?.should be_true

    closed = Api.close_year(L.actor, 2025).value!
    {closed.state, closed.closed_by_id, closed.reopenable?, closed.frozen?}.should eq({"closed", L.actor.user_id, true, true})
    closed.closed_at.should_not be_nil
    closed.frozen_fingerprint.should eq(Api.tax_return(L.system, 2025).fingerprint)
    # Lignes figées : ni modification, ni suppression, ni inscription.
    Api.line(L.system, line.id).locked.should be_true
    Api.update_line(L.actor, line.id, L.input("2025-06-10", "41", "OFFICE")).error_keys
      .should eq(["liberal.errors.line.change.year_closed"])
    Api.delete_line(L.actor, line.id).error_keys.should eq(["liberal.errors.line.change.year_closed"])
    Api.record_expense(L.actor, L.input("2025-12-01", "10", "OFFICE")).error_keys
      .should eq(["liberal.errors.line.date.year_closed"])
    Api.asset(L.system, asset.id).locked.should be_true
    Api.add_adjustment(L.actor, Api::AdjustmentInput.new(2025, "deduction", "x", L.d("5"))).error_keys
      .should eq(["liberal.errors.adjustment.year.closed"])
    Api.tax_return(L.system, 2025).controls.map(&.key).should_not contain("liberal.controls.year_open")
    # En base aussi.
    expect_raises(Exception, /exercice figé|intangible/) do
      Partiduo::Liberal::Line.get!(id: line.id).update!(label: "autre")
    end

    reopened = Api.reopen_year(L.actor, 2025).value!
    {reopened.state, reopened.reopened_by_id, reopened.closed_at, reopened.frozen_fingerprint}
      .should eq({"open", L.actor.user_id, nil, ""})
    reopened.reopened_at.should_not be_nil
    Api.update_line(L.actor, line.id, L.input("2025-06-10", "41", "OFFICE")).value!.amount.should eq(L.d("41"))
    Api.tax_return(L.system, 2025).controls.map(&.key).should contain("liberal.controls.year_open")

    Api.close_year(L.actor, 2025).value!.state.should eq("closed")
    Api.year(L.system, 2025).frozen_fingerprint.should eq(Api.tax_return(L.system, 2025).fingerprint)
    transmit(2025)
    locked = Api.year(L.system, 2025)
    {locked.state, locked.reference, locked.reopenable?, locked.closable?}.should eq({"locked", "liasse:2025", false, false})
    locked.frozen_at.should eq(locked.transmitted_at)
    Api.line(L.system, line.id).transmitted_at.should eq(locked.transmitted_at)
    Api.update_line(L.actor, line.id, L.input("2025-06-10", "42", "OFFICE")).error_keys
      .should eq(["liberal.errors.line.change.transmitted"])

    actions(2025).should eq(%w[closed reopened closed locked])
    Api.year_history(L.system, 2025).map(&.user_id).uniq!.should eq([L.actor.user_id])
    Api.year_history(L.system, 2025).last.reference.should eq("liasse:2025")
  end

  it "refuse de rouvrir un exercice verrouillé, par le contrat comme en base" do
    L.setup(years: [2025, 2026])
    line = L.receipt("2025-03-10", "100")
    Api.close_year(L.actor, 2025).value!
    transmit(2025)
    Api.reopen_year(L.actor, 2025).error_keys.should eq(["liberal.errors.year.reopen.locked"])
    Api.close_year(L.actor, 2025).error_keys.should eq(["liberal.errors.year.close.locked"])
    expect_raises(Exception, /verrouillé/) do
      Partiduo::Liberal::Year.get!(year: 2025).update!(state: "open", closed_at: nil, transmitted_at: nil)
    end
    Api.year(L.system, 2025).locked?.should be_true
    # Correction par contre-passation datée dans un exercice ouvert.
    reversal = Api.reverse_line(L.actor, Api::ReverseInput.new(line.id, L.date("2026-01-15"))).value!
    reversal.number.should start_with("J2026-")
  end

  it "rend l'exercice clôturé au rejet de la 2035 : il se rouvre, se corrige et se renvoie" do
    L.setup(years: [2025, 2026])
    line = L.receipt("2025-03-10", "100")
    Api.close_year(L.actor, 2025).value!
    transmit(2025)
    reject(2025, "liasse:autre")
    Api.year(L.system, 2025).locked?.should be_true
    reject(2025)
    rejected = Api.year(L.system, 2025)
    {rejected.state, rejected.reference, rejected.transmitted_at, rejected.reopenable?}.should eq({"closed", "", nil, true})
    rejected.closed_at.should_not be_nil
    Api.update_line(L.actor, line.id, L.input("2025-03-10", "110", "RECEIPTS")).error_keys
      .should eq(["liberal.errors.line.change.year_closed"])
    Api.reopen_year(L.actor, 2025).value!
    Api.update_line(L.actor, line.id, L.input("2025-03-10", "110", "RECEIPTS")).value!
    Api.close_year(L.actor, 2025).value!
    transmit(2025, "liasse:2025-bis")
    Api.year(L.system, 2025).reference.should eq("liasse:2025-bis")
    actions(2025).should eq(%w[closed locked unlocked reopened closed locked])
  end

  it "clôture d'office l'exercice encore ouvert dont la transmission est notée" do
    L.setup(years: [2025, 2026])
    L.receipt("2025-03-10", "100")
    transmit(2025)
    view = Api.year(L.system, 2025)
    {view.state, view.closed_by_id}.should eq({"locked", L.actor.user_id})
    view.closed_at.should eq(view.transmitted_at)
    actions(2025).should eq(%w[closed locked])
    reject(2025)
    Api.year(L.system, 2025).state.should eq("closed")
  end

  it "tient deux exercices indépendants : l'un clôturé, l'autre ouvert, puis l'inverse" do
    L.setup(years: [2025, 2026])
    previous = L.receipt("2025-11-15", "3000")
    current = L.receipt("2026-01-20", "250")
    Api.close_year(L.actor, 2025).value!
    Api.year(L.system, 2026).open?.should be_true
    Api.update_line(L.actor, current.id, L.input("2026-01-21", "260", "RECEIPTS")).value!
    # Une ligne de l'exercice ouvert ne se déplace pas dans l'exercice clôturé.
    Api.update_line(L.actor, current.id, L.input("2025-12-30", "260", "RECEIPTS")).error_keys
      .should eq(["liberal.errors.line.date.year_closed"])
    Api.close_year(L.actor, 2026).value!
    Api.reopen_year(L.actor, 2025).value!
    Api.year(L.system, 2026).closed?.should be_true
    Api.update_line(L.actor, previous.id, L.input("2025-11-15", "3100", "RECEIPTS")).value!
    Api.update_line(L.actor, current.id, L.input("2026-01-21", "270", "RECEIPTS")).error_keys
      .should eq(["liberal.errors.line.change.year_closed"])
    actions(2025).should eq(%w[closed reopened])
    actions(2026).should eq(%w[closed])
  end

  it "refuse une clôture sans objet et une réouverture d'un exercice ouvert" do
    L.setup(years: [2025, 2026])
    next_year = Partiduo::Config.today.year + 1
    Api.close_year(L.actor, next_year).error_keys.should eq(["liberal.errors.year.close.future"])
    Api.close_year(L.actor, 1800).error_keys.should eq(["liberal.errors.year.invalid"])
    Api.reopen_year(L.actor, 2025).error_keys.should eq(["liberal.errors.year.reopen.open"])
    Api.close_year(L.actor, 2025).value!
    Api.close_year(L.actor, 2025).error_keys.should eq(["liberal.errors.year.close.already"])
    actions(2025).should eq(%w[closed])
  end

  it "garde la clôture au socle comme verrou de plus : le module ne la rouvre pas" do
    L.setup(years: [2025, 2026])
    L.receipt("2025-03-10", "100")
    Api.close_year(L.actor, 2025).value!
    L.close_year(2025)
    view = Api.year(L.system, 2025)
    {view.state, view.reopenable?}.should eq({"closed", false})
    view.core_closed_at.should_not be_nil
    Api.reopen_year(L.actor, 2025).error_keys.should eq(["liberal.errors.year.reopen.core_closed"])
    # Clos au socle sans clôture du module : clôturé, rien à rouvrir non plus.
    L.receipt("2026-01-10", "50")
    L.close_year(2026)
    Api.year(L.system, 2026).closed?.should be_true
    Api.close_year(L.actor, 2026).error_keys.should eq(["liberal.errors.year.close.already"])
    Api.reopen_year(L.actor, 2026).error_keys.should eq(["liberal.errors.year.reopen.core_closed"])
  end

  it "exige le droit de saisie pour clôturer et rouvrir" do
    L.setup(years: [2025, 2026])
    reader = Partiduo::Api::Actor.user(10_i64, %w[liberal.register.read liberal.settings.write])
    expect_raises(Partiduo::Api::Forbidden) { Api.close_year(reader, 2025) }
    Api.close_year(L.actor, 2025).value!
    expect_raises(Partiduo::Api::Forbidden) { Api.reopen_year(reader, 2025) }
    Api.year_history(reader, 2025).size.should eq(1)
  end
end
