# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Relecture du lot 5 : désignation des lignes par leur saisie
# (`input_index`), écritures annulées et extournes, clés après suppression
# d'un poste, historique découpé en SQL, exports, paramètres uniques,
# droits de lecture d'une ventilation (DECISIONS D-ANA-012 à D-ANA-018).

private alias Api = Partiduo::Api::Analytic
private alias Acc = Partiduo::Api::Accounting

private def system
  Partiduo::Api::Actor.system
end

private def d(text : String) : BigDecimal
  BigDecimal.new(text)
end

private def row(amount : String, *posts : Api::PostView) : Api::DistributionRowInput
  Api::DistributionRowInput.new(d(amount), posts.to_a.map(&.id))
end

describe_module "ANALYTIC", "Analytique : relecture du lot 5" do
  it "rattache chaque ligne d'écriture à sa ligne saisie, TVA et tiers exclus, extourne comprise" do
    AnalyticSpec.setup
    supplier = EntrySpec.card("SUPPLIER", "Fournisseur")
    input = EntrySpec.document("A01", supplier.code, [
      EntrySpec.item("0", account: "604"), EntrySpec.item("100", account: "603"), EntrySpec.item("50", account: "681"),
    ])
    entry = Acc.post_purchase(system, input).value!
    entry.lines.to_h { |line| {line.account_number, line.input_index} }
      .select { |number, _| number.in?("603", "681") }.should eq({"603" => 1, "681" => 2})
    entry.lines.select { |line| line.vat_role == "tax" || line.card_code == supplier.code }.all?(&.input_index.nil?).should be_true

    misc = EntrySpec.post_misc([EntrySpec.debit("603", "10"), EntrySpec.credit("400", "10")])
    misc.lines.map(&.input_index).should eq([0, 1])
    reversal = Acc.cancel_entry(system, Acc::CancelEntryInput.new(misc.id)).value!
    reversal.lines.map(&.input_index).should eq([0, 1])
  end

  it "ignore une ligne saisie nulle ventilée par poste, refuse un rang hors de la saisie" do
    data = AnalyticSpec.setup
    supplier = EntrySpec.card("SUPPLIER", "Fournisseur")
    input = EntrySpec.document("A01", supplier.code, [EntrySpec.item("0", account: "604"), EntrySpec.item("100", account: "603")])
    outside = Api.post_purchase(system, input, [Api::InputDistributionInput.new(5, post_ids: [data[:sale].id])])
    outside.errors.map(&.field).should eq(["distributions[0].input_index"])
    explicit = Api.post_purchase(system, input, [Api::InputDistributionInput.new(0, [row("10", data[:sale])])])
    explicit.errors.map(&.field).should eq(["distributions[0].input_index"])
    entry = Api.post_purchase(system, input, [
      Api::InputDistributionInput.new(0, post_ids: [data[:sale].id]),
      Api::InputDistributionInput.new(1, post_ids: [data[:workshop].id]),
    ]).value!
    Api.entry_distributions(system, entry.id).map(&.account_number).should eq(["603"])
  end

  it "ventile au montant converti en devise de tenue, pas au montant saisi" do
    data = AnalyticSpec.setup
    AnalyticSpec.mandatory!("603")
    Partiduo::Api::Core.create_currency(system, Partiduo::Api::Core::CurrencyInput.new(
      code: "USD", name: "Dollar", decimals: 2, rate: d("1.5"), valid_from: EntrySpec.date("2026-01-01"))).value!
    input = EntrySpec.misc_input([EntrySpec.debit("603", "300"), EntrySpec.credit("400", "300")])
      .copy_with(currency_code: "USD", currency_rate: d("1.5"))
    entry = Api.post_entry(system, input, [Api::InputDistributionInput.new(0, post_ids: [data[:sale].id, data[:p1].id])]).value!
    Api.entry_distributions(system, entry.id).first.rows.first.amount.should eq(d("200"))
  end

  it "refuse de ventiler une écriture annulée ou son extourne" do
    data = AnalyticSpec.setup
    entry = AnalyticSpec.expense("100")
    AnalyticSpec.distribute(entry, [row("100", data[:sale])]).value!
    reversal = Acc.cancel_entry(system, Acc::CancelEntryInput.new(entry.id)).value!
    cancelled = Acc.entry(system, entry.id)
    [cancelled, reversal].each do |item|
      lines = [Api::LineDistributionInput.new(item.lines.first.id, [row("100", data[:workshop])])]
      Api.distribute_entry(system, item.id, lines).error_keys.should eq(["analytic.errors.distribution.cancelled_entry"])
      Api.check_distribution(system, item.id, lines).error_keys.should eq(["analytic.errors.distribution.cancelled_entry"])
    end
  end

  it "retire les lignes de clé restées sans poste et n'applique plus une clé incomplète" do
    data = AnalyticSpec.setup
    lonely = AnalyticSpec.post(data[:activity], "SEUL")
    key = Api.create_key(system, Api::KeyInput.new("DEUX", [
      Api::KeyRowInput.new(d("60"), [data[:sale].id, data[:p1].id]),
      Api::KeyRowInput.new(d("40"), [lonely.id]),
    ])).value!
    key.complete?.should be_true
    Api.delete_post(system, lonely.id).value!
    after = Api.key(system, key.id)
    after.rows.size.should eq(1)
    after.total_percent.should eq(d("60"))
    after.complete?.should be_false

    input = EntrySpec.misc_input([EntrySpec.debit("603", "100"), EntrySpec.credit("400", "100")])
    refused = Api.post_entry(system, input, [Api::InputDistributionInput.new(0, key_id: key.id)])
    refused.error_keys.should eq(["analytic.errors.key.incomplete"])
    refused.errors.first.field.should eq("distributions[0].key_id")

    Api.delete_plan(system, data[:project].id).value!
    Api.key(system, key.id).rows.map(&.posts.map(&.code)).should eq([["VENTE"]])
  end

  it "découpe l'historique en SQL et exporte toute la sélection" do
    data = AnalyticSpec.setup
    5.times do |index|
      entry = AnalyticSpec.expense("#{index + 1}0", "2026-03-#{10 + index}")
      AnalyticSpec.distribute(entry, [row("#{index + 1}0", data[:sale])]).value!
    end
    query = Api::ReportQuery.new(data[:activity].id)
    page = Api.history(system, query, 1, 2)
    page.count.should eq(5)
    page.total.debit.should eq(d("150"))
    page.operations.map(&.amount).should eq([d("20"), d("30")])
    String.new(Api.export_history(system, query).content).lines.size.should eq(6)
  end

  it "nomme le fichier de la balance sans caractère dangereux" do
    Partiduo::Analytic::Exports.slug(%(A"B;C/ÉTÉ)).should eq("a-b-c-ete")
    Partiduo::Analytic::Exports.slug("***").should eq("plan")
  end

  it "garde une seule ligne de paramètres" do
    EntrySpec.setup
    Partiduo::Analytic::Settings.current
    Partiduo::Analytic::Settings.current
    Partiduo::Analytic::Setting.all.count.should eq(1)
    expect_raises(Exception) do
      EntrySpec.sql_transaction { |db| db.exec("INSERT INTO analytic_setting (mandatory, account_filter, singleton) VALUES (false, '6', true)") }
    end
  end

  it "laisse lire la ventilation d'une écriture à qui peut la ventiler" do
    data = AnalyticSpec.setup
    entry = AnalyticSpec.expense("100")
    AnalyticSpec.distribute(entry, [row("100", data[:sale])]).value!
    _, writer = AccountingSpec.user_actor("ventileur@example.test", "analytic.operation.write", "accounting.entry.read")
    Api.entry_distributions(writer, entry.id).size.should eq(1)
    expect_raises(Partiduo::Api::Forbidden) { Api.entry_distributions(actor_with("accounting.entry.read"), entry.id) }
  end

  it "signale le mode obligatoire à tout utilisateur" do
    AnalyticSpec.setup
    Api.distribution_required?(actor_with).should be_false
    AnalyticSpec.mandatory!
    Api.distribution_required?(actor_with).should be_true
  end
end
