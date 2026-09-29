# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias Api = Partiduo::Api::Micro
private alias M = MicroSpec

# D-MIC2-001 : une ligne se modifie et se supprime tant que sa période de
# déclaration URSSAF (mois ou trimestre) n'est ni déclarée ni close au
# socle ; ensuite, elle est intangible et se corrige par une contre-passation
# datée dans une période ouverte, reportée sur la déclaration suivante.

private def declare(starts_on : String, on : String = "2026-09-20") : Nil
  Api.mark_declared(M.actor, Api::DeclarationInput.new(M.date(starts_on), M.date(on))).value!
end

private def invoicing_receipt(on : String = "2026-09-10") : Partiduo::Api::Micro::LineView
  Partiduo::Api::Transaction.run do
    row = Partiduo::Micro::Registers.create_receipt!(M.receipt_input(on), nil, "invoicing", "payment:1")
    Partiduo::Api::Result(Partiduo::Api::Micro::LineView).success(Partiduo::Micro::Registers.view(row))
  end.value!
end

describe_module "MICRO", Api do
  describe "période ouverte" do
    it "modifie une recette et publie micro.receipt.updated, charge utile complète" do
      M.setup
      line = M.receipt("2026-09-10", "100")
      line.editable?.should be_true
      line.deletable?.should be_true
      ReferentialSpec.capture_events("micro.receipt.updated") do |events|
        changed = Api.update_receipt(M.actor, line.id, M.receipt_input("2026-09-12", "120", "SALE",
          party_name: "Paul Durand", reference: "F-7")).value!
        changed.id.should eq(line.id)
        changed.number.should eq(line.number)
        changed.date.should eq(M.date("2026-09-12"))
        changed.amount.should eq(M.d("120"))
        changed.nature_code.should eq("SALE")
        changed.category.should eq("sale_bic")
        changed.party_name.should eq("Paul Durand")
        changed.modified_at.should_not be_nil
        events.size.should eq(1)
        payload = events.first.payload
        payload["receipt_id"].should eq(line.id.to_s)
        BigDecimal.new(payload["amount"]).should eq(M.d("120"))
        payload["nature_code"].should eq("SALE")
        payload["date"].should eq("2026-09-12")
        payload["origin"].should eq("manual")
      end
      Api.declarations(M.system, 2026, M.date("2026-09-27"))[2].turnover.should eq(M.d("120"))
    end

    it "renumérote une ligne déplacée dans une autre année" do
      M.setup
      # Exercice 2025 : la Comptabilité, si elle est active, y passe l'écriture.
      ReferentialSpec.fiscal_year(2025)
      M.receipt("2026-01-05", "10")
      line = M.receipt("2026-01-06", "20")
      moved = Api.update_receipt(M.actor, line.id, M.receipt_input("2025-12-30", "20")).value!
      moved.number.should eq("R2025-00001")
    end

    it "supprime une recette et un achat, et publie micro.*.deleted" do
      M.setup
      line = M.receipt("2026-09-10", "100")
      purchase = M.purchase("2026-09-12", "40")
      ReferentialSpec.capture_events("micro.receipt.deleted") do |events|
        Api.delete_receipt(M.actor, line.id).value!
        events.map(&.["receipt_id"]).should eq([line.id.to_s])
        events.first["number"].should eq(line.number)
      end
      ReferentialSpec.capture_events("micro.purchase.deleted") do |events|
        Api.delete_purchase(M.actor, purchase.id).value!
        events.map(&.["purchase_id"]).should eq([purchase.id.to_s])
      end
      Api.receipts(M.system).should be_empty
      Api.purchases(M.system).should be_empty
      expect_raises(Partiduo::Api::NotFound) { Api.receipt(M.system, line.id) }
      # Le numéro n'est pas repris.
      M.receipt("2026-09-11", "5").number.should eq("R2026-00002")
    end

    it "modifie un achat avec les contrôles de la saisie" do
      M.setup
      purchase = M.purchase("2026-09-12", "40")
      input = Api::PurchaseInput.new(date: M.date("2026-09-13"), nature_id: M.nature("SUPPLIES").id, amount: M.d("45.5"),
        method: "cash", party_name: "Papeterie")
      ReferentialSpec.capture_events("micro.purchase.updated") do |events|
        changed = Api.update_purchase(M.actor, purchase.id, input).value!
        changed.amount.should eq(M.d("45.5"))
        changed.category.should eq("other")
        events.size.should eq(1)
      end
      refused = Api.update_purchase(M.actor, purchase.id, input.copy_with(amount: M.d("-1"), date: M.date("2026-12-01")))
      refused.error_keys.sort.should eq(%w[micro.errors.line.amount.not_positive micro.errors.line.date.future])
      ReferentialSpec.expect_translated(refused)
      Api.purchase(M.system, purchase.id).amount.should eq(M.d("45.5"))
    end

    it "ne modifie ni une ligne issue de la Facturation, ni une ligne contre-passée, ni une contre-passation" do
      M.setup
      invoiced = invoicing_receipt
      invoiced.editable?.should be_false
      Api.update_receipt(M.actor, invoiced.id, M.receipt_input).error_keys.should eq(["micro.errors.line.change.from_invoicing"])
      Api.delete_receipt(M.actor, invoiced.id).error_keys.should eq(["micro.errors.line.change.from_invoicing"])

      line = M.receipt("2026-09-10", "100")
      reversal = Api.reverse_receipt(M.actor, Api::ReverseInput.new(line.id, M.date("2026-09-15"))).value!
      Api.receipt(M.system, line.id).editable?.should be_false
      Api.update_receipt(M.actor, line.id, M.receipt_input).error_keys.should eq(["micro.errors.line.change.reversed"])
      Api.delete_receipt(M.actor, line.id).error_keys.should eq(["micro.errors.line.change.reversed"])
      reversal.editable?.should be_false
      reversal.deletable?.should be_true
      Api.update_receipt(M.actor, reversal.id, M.receipt_input).error_keys.should eq(["micro.errors.line.change.is_reversal"])
      # Supprimer la contre-passation rend la ligne de nouveau modifiable.
      Api.delete_receipt(M.actor, reversal.id).value!
      Api.receipt(M.system, line.id).editable?.should be_true
      Api.update_receipt(M.actor, line.id, M.receipt_input(amount: "90")).value!.amount.should eq(M.d("90"))
    end
  end

  describe "période déclarée à l'URSSAF (mois ou trimestre)" do
    it "rend les lignes du trimestre déclaré intangibles ; correction reportée sur la période suivante" do
      M.setup
      line = M.receipt("2026-05-10", "100")
      other = M.receipt("2026-07-02", "30")
      declare("2026-04-01", "2026-07-10")
      view = Api.receipt(M.system, line.id)
      view.locked.should be_true
      view.declared_on.should eq(M.date("2026-07-10"))
      view.editable?.should be_false
      view.deletable?.should be_false
      view.reversible?.should be_true
      Api.receipt(M.system, other.id).locked.should be_false

      Api.update_receipt(M.actor, line.id, M.receipt_input("2026-05-10", "90"))
        .error_keys.should eq(["micro.errors.line.change.declared_period"])
      Api.delete_receipt(M.actor, line.id).error_keys.should eq(["micro.errors.line.change.declared_period"])
      # Ni saisie, ni déplacement, ni contre-passation dans le trimestre déclaré.
      Api.record_receipt(M.actor, M.receipt_input("2026-06-30")).error_keys.should eq(["micro.errors.line.date.declared_period"])
      Api.update_receipt(M.actor, other.id, M.receipt_input("2026-06-30", "30"))
        .error_keys.should eq(["micro.errors.line.date.declared_period"])
      Api.reverse_receipt(M.actor, Api::ReverseInput.new(line.id, M.date("2026-06-30")))
        .error_keys.should eq(["micro.errors.line.date.declared_period"])
      ReferentialSpec.expect_translated(Api.delete_receipt(M.actor, line.id))

      reversal = Api.reverse_receipt(M.actor, Api::ReverseInput.new(line.id, M.date("2026-07-15"))).value!
      periods = Api.declarations(M.system, 2026, M.date("2026-09-27"))
      periods[1].turnover.should eq(M.d("100"))
      periods[2].turnover.should eq(M.d("-70"))
      reversal.locked.should be_false
    end

    it "suit la périodicité mensuelle : seul le mois déclaré est clos" do
      M.setup(periodicity: "monthly")
      august = M.receipt("2026-08-31", "10")
      september = M.receipt("2026-09-01", "20")
      declare("2026-08-01", "2026-09-05")
      Api.receipt(M.system, august.id).locked.should be_true
      Api.receipt(M.system, september.id).locked.should be_false
      Api.delete_receipt(M.actor, september.id).value!
    end

    it "garde en base la période déclarée : ni modification, ni suppression, ni inscription" do
      M.setup
      line = M.purchase("2026-05-10", "40")
      open = M.purchase("2026-07-10", "12")
      InvoicingSpec.sql_error("UPDATE micro_purchase SET label = 'x' WHERE id = $1", line.id).should be_nil
      declare("2026-04-01", "2026-07-10")
      InvoicingSpec.sql_error("UPDATE micro_purchase SET label = 'y' WHERE id = $1", line.id).to_s.should contain("intangible")
      InvoicingSpec.sql_error("DELETE FROM micro_purchase WHERE id = $1", line.id).to_s.should contain("intangible")
      InvoicingSpec.sql_error("UPDATE micro_purchase SET date = '2026-06-01' WHERE id = $1", open.id)
        .to_s.should contain("période déclarée")
      sql = "INSERT INTO micro_purchase (number, date, nature_id, category, amount, method, party_name, label, reference, " \
            "recorded_at) VALUES ('X-1', '2026-05-11', $1, 'goods', 5, 'cash', '', '', '', now())"
      InvoicingSpec.sql_error(sql, M.nature("GOODS").id).to_s.should contain("période déclarée")
      InvoicingSpec.sql_error("DELETE FROM micro_purchase WHERE id = $1", open.id).should be_nil
    end
  end

  describe "période close au socle" do
    it "refuse modification et suppression, laisse la contre-passation dans une période ouverte" do
      M.setup
      line = M.receipt("2026-08-10", "100")
      M.close_period("2026-08-10")
      Api.receipt(M.system, line.id).declared_on.should be_nil
      Api.receipt(M.system, line.id).editable?.should be_false
      Api.update_receipt(M.actor, line.id, M.receipt_input("2026-08-10", "90"))
        .error_keys.should eq(["micro.errors.line.change.closed_period"])
      Api.delete_receipt(M.actor, line.id).error_keys.should eq(["micro.errors.line.change.closed_period"])
      open = M.receipt("2026-09-10", "10")
      Api.update_receipt(M.actor, open.id, M.receipt_input("2026-08-11", "10"))
        .error_keys.should eq(["micro.errors.line.date.closed_period"])
      Api.reverse_receipt(M.actor, Api::ReverseInput.new(line.id, M.date("2026-09-01"))).success?.should be_true
    end
  end
end
