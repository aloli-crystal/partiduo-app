# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Droits par dépôt, par profil (`profile_sec_repository` d'origine ;
# DECISIONS D-STK-006 révisée, D-R5-015).

private alias Api = Partiduo::Api::Stock
private alias S = StockSpec

# Magasinier : profil aux droits de lecture et d'écriture du Stock, sans le
# paramétrage.
private def storekeeper : {Partiduo::Api::Actor, Int64}
  permissions = %w[stock.movement.read stock.movement.write]
  profile = Partiduo::Api::Auth.create_profile(Partiduo::Api::Actor.system,
    Partiduo::Api::Auth::ProfileInput.new(name: "Magasinier", permissions: permissions)).value!
  created = Partiduo::Api::Auth.create_user(Partiduo::Api::Actor.system,
    Partiduo::Api::Auth::UserInput.new(email: "magasin@example.com", first_name: "Marc", last_name: "Dépôt",
      profile_id: profile.id, password: AuthSpec::PASSWORD)).value!
  {Partiduo::Api::Actor.user(created.user.id, permissions), profile.id}
end

describe_module "STOCK", "Stock : droits par dépôt" do
  it "laisse un profil sans droit enregistré voir et écrire partout" do
    setup = S.setup
    actor, profile_id = storekeeper
    Api.repositories(actor).size.should eq(2)
    Api.profile_rights(S.system, profile_id).restricted.should be_false
    Api.record_change(actor, Api::ChangeInput.new(setup.annex.id, S.date("2026-03-02"),
      [Api::ChangeLineInput.new(setup.screws.id, S.d("5"))])).success?.should be_true
  end

  it "restreint la lecture et l'écriture aux dépôts cités" do
    setup = S.setup
    S.change(setup.main, "2026-03-01", {setup.screws, "10", "1.5"})
    annex_change = S.change(setup.annex, "2026-03-01", {setup.bolts, "4", nil})
    actor, profile_id = storekeeper
    rights = [Api::RepositoryRightInput.new(setup.main.id, "R"), Api::RepositoryRightInput.new(setup.annex.id, "")]
    view = Api.set_profile_rights(S.system, profile_id, rights).value!
    view.restricted.should be_true
    view.rights.map { |right| {right.repository_name, right.access} }.sort!
      .should eq([{"Annexe", ""}, {"Entrepôt principal", "R"}])

    Api.repositories(actor).map(&.name).should eq(["Entrepôt principal"])
    expect_raises(Partiduo::Api::NotFound) { Api.repository(actor, setup.annex.id) }
    expect_raises(Partiduo::Api::NotFound) { Api.change(actor, annex_change.id) }
    Api.movements(actor).map(&.repository_name).uniq!.should eq(["Entrepôt principal"])
    Api.count_movements(actor, Api::MovementQuery.new(repository_id: setup.annex.id)).should eq(0)
    Api.changes(actor).map(&.repository_name).should eq(["Entrepôt principal"])
    state = Api.state(actor, Api::StateQuery.new(S.date("2026-01-01"), S.date("2026-12-31")))
    state.rows.map(&.repository_name).uniq!.should eq(["Entrepôt principal"])
    Api.valuation(actor, S.date("2026-12-31")).rows.map(&.repository_id).uniq!.should eq([setup.main.id])
    Api.quantity(actor, setup.bolts.id, S.date("2026-12-31")).should eq(S.d("0"))

    # Lecture seule : écriture refusée ; écriture accordée : admise.
    input = Api::ChangeInput.new(setup.main.id, S.date("2026-03-05"), [Api::ChangeLineInput.new(setup.screws.id, S.d("-1"))])
    refused = Api.record_change(actor, input)
    refused.error_keys.should eq(["stock.errors.rights.denied"])
    ReferentialSpec.expect_translated(refused)
    Api.set_profile_rights(S.system, profile_id, [Api::RepositoryRightInput.new(setup.main.id, "W")]).value!
    Api.record_change(actor, input).success?.should be_true

    # Qui paramètre le Stock voit tout.
    Api.repositories(S.system).size.should eq(2)
  end

  it "lève la restriction quand aucun droit ne reste, et contrôle la saisie des droits" do
    setup = S.setup
    actor, profile_id = storekeeper
    Api.set_profile_rights(S.system, profile_id, [Api::RepositoryRightInput.new(setup.main.id, "W")]).value!
    Api.repositories(actor).size.should eq(1)
    Api.set_profile_rights(S.system, profile_id, [] of Api::RepositoryRightInput).value!.restricted.should be_false
    Api.repositories(actor).size.should eq(2)
    result = Api.set_profile_rights(S.system, profile_id, [Api::RepositoryRightInput.new(424_242_i64, "X")])
    result.error_keys.should eq(["stock.errors.rights.access_invalid", "stock.errors.rights.repository_unknown"])
    ReferentialSpec.expect_translated(result)
    Api.set_profile_rights(S.system, 999_999_i64, [] of Api::RepositoryRightInput).error_keys
      .should eq(["stock.errors.rights.profile_unknown"])
    expect_raises(Partiduo::Api::Forbidden) { Api.profile_rights(actor, profile_id) }
  end
end
