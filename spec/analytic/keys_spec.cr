# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Clés de répartition (`Anc_Key`, `anc_keyTest.php` : testKeyAvailable ;
# `fill_table`).

private alias Api = Partiduo::Api::Analytic

private def system
  Partiduo::Api::Actor.system
end

private def d(text : String) : BigDecimal
  BigDecimal.new(text)
end

private def key_input(name : String, rows : Array({String, Array(Int64)}), ledgers : Array(Int64) = [] of Int64)
  Api::KeyInput.new(name, rows.map { |(percent, posts)| Api::KeyRowInput.new(d(percent), posts) },
    "Description de la clef", ledgers)
end

describe_module "ANALYTIC", "Analytique : clés de répartition" do
  it "propose une clé aux seuls journaux choisis (testKeyAvailable)" do
    data = AnalyticSpec.setup
    posts = [data[:sale], data[:workshop], data[:p1], data[:p2]].map(&.id)
    rows = posts.zip(%w[10 20 30 40]).map { |(post, percent)| {percent, [post]} }
    a01 = EntrySpec.ledger("A01").id
    v01 = EntrySpec.ledger("V01").id
    o01 = EntrySpec.ledger("O01").id
    key1 = Api.create_key(system, key_input("Test.Key1", rows, [a01, v01, o01])).value!
    key2 = Api.create_key(system, key_input("Test.Key2", rows, [v01])).value!

    key1.total_percent.should eq(d("100"))
    key1.rows.map(&.position).should eq([0, 1, 2, 3])
    key1.rows.map(&.posts.map(&.code)).should eq([["VENTE"], ["ATELIER"], ["P1"], ["P2"]])
    Api.keys_for_ledger(system, a01).map(&.name).should eq(["Test.Key1"])
    Api.keys_for_ledger(system, v01).map(&.name).should eq(["Test.Key1", "Test.Key2"])
    Api.keys_for_ledger(system, o01).size.should eq(1)
    Api.keys_for_ledger(system, EntrySpec.ledger("F01").id).should be_empty

    Api.delete_key(system, key1.id).success?.should be_true
    Api.delete_key(system, key2.id).success?.should be_true
    Api.keys(system).should be_empty
  end

  it "contrôle nom, pourcentages (total de 100), postes et journaux" do
    data = AnalyticSpec.setup
    sale, p1 = data[:sale].id, data[:p1].id
    Api.create_key(system, key_input(" ", [{"100", [sale]}])).error_keys.should eq(["analytic.errors.key.name_required"])
    Api.create_key(system, key_input("K", [] of {String, Array(Int64)})).error_keys
      .should eq(["analytic.errors.key.rows_required"])
    total = Api.create_key(system, key_input("K", [{"60", [sale]}, {"30", [p1]}]))
    total.error_keys.should eq(["analytic.errors.key.total"])
    total.errors.first.params.should eq({"total" => "90"})
    Api.create_key(system, key_input("K", [{"0", [sale]}, {"100", [p1]}])).error_keys
      .should eq(["analytic.errors.key.percent_invalid"])
    Api.create_key(system, key_input("K", [{"100", [] of Int64}])).error_keys
      .should eq(["analytic.errors.key.post_required"])
    Api.create_key(system, key_input("K", [{"100", [sale, data[:workshop].id]}])).error_keys
      .should eq(["analytic.errors.distribution.plan_twice"])
    Api.create_key(system, key_input("K", [{"100", [sale]}], [999_999_i64])).error_keys
      .should eq(["analytic.errors.key.ledger_unknown"])
    Api.check_key(system, key_input("K", [{"100", [sale, p1]}])).success?.should be_true
  end

  it "remplace lignes et journaux à la mise à jour" do
    data = AnalyticSpec.setup
    key = Api.create_key(system, key_input("K", [{"100", [data[:sale].id]}], [EntrySpec.ledger("A01").id])).value!
    updated = Api.update_key(system, key.id,
      key_input("K2", [{"50", [data[:sale].id, data[:p1].id]}, {"50", [data[:workshop].id]}])).value!
    updated.name.should eq("K2")
    updated.rows.map(&.percent).should eq([d("50"), d("50")])
    updated.rows.first.posts.map(&.code).should eq(["VENTE", "P1"])
    updated.ledger_ids.should be_empty
    Partiduo::Analytic::KeyRow.all.count.should eq(2)
  end

  it "répartit un montant au centime, l'écart d'arrondi sur la dernière ligne" do
    data = AnalyticSpec.setup
    key = Api.create_key(system, key_input("Tiers",
      [{"33.3333", [data[:sale].id, data[:p1].id]}, {"33.3333", [data[:workshop].id]}, {"33.3334", [data[:p2].id]}])).value!
    rows = Api.apply_key(system, key.id, d("-100"))
    rows.map(&.amount).should eq([d("33.33"), d("33.33"), d("33.34")])
    rows.first.post_ids.should eq([data[:sale].id, data[:p1].id])
    rows.sum(BigDecimal.new(0), &.amount).should eq(d("100"))
    Api.apply_key(system, key.id, d("0.01")).map(&.amount).should eq([d("0.01")])
  end
end
