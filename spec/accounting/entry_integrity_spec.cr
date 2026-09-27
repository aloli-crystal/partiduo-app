# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Intégrité des écritures *en base* (migration accounting 0003, D-ACC-011),
# vérifiée en SQL direct, sans passer par le contrat : successeurs de
# `check_balance`, `proc_check_balance`, `jrn_check_periode`, `is_closed`.

private alias Api = Partiduo::Api::Accounting

private def ledger_id(code = "O01") : Int64
  EntrySpec.ledger(code).id
end

private def account_id(number : String) : Int64
  Api.account(EntrySpec.system, number).id
end

private def insert_entry(db, day : String, amount : String, ledger = "O01") : Int64
  db.scalar(
    "INSERT INTO accounting_entry (ledger_id, period_id, date, label, amount, currency_code, currency_rate, source, " \
    "created_at, updated_at) VALUES ($1, 0, $2::date, 'SQL', $3::numeric, 'EUR', 1, '', now(), now()) RETURNING id",
    ledger_id(ledger), day, amount
  ).as(Int64)
end

private def insert_line(db, entry_id : Int64, number : String, side : String, amount : String) : Int64
  db.scalar(
    "INSERT INTO accounting_entry_line (entry_id, position, account_id, side, amount, label) " \
    "VALUES ($1, 0, $2, $3, $4::numeric, '') RETURNING id",
    entry_id, account_id(number), side, amount
  ).as(Int64)
end

describe_module "ACCOUNTING", "Intégrité des écritures en base" do
  describe "équilibre (CONSTRAINT TRIGGER … DEFERRABLE INITIALLY DEFERRED)" do
    it "refuse au COMMIT une écriture déséquilibrée" do
      EntrySpec.setup
      expect_raises(Exception, /déséquilibrée/) do
        EntrySpec.sql_transaction do |db|
          id = insert_entry(db, "2026-03-15", "100")
          insert_line(db, id, "603", "debit", "100")
          insert_line(db, id, "510001", "credit", "99.99")
        end
      end
      EntrySpec.scalar("SELECT count(*) FROM accounting_entry").should eq(0)
    end

    it "admet un état intermédiaire déséquilibré dans la transaction, contrôlé au COMMIT" do
      EntrySpec.setup
      EntrySpec.sql_transaction do |db|
        id = insert_entry(db, "2026-03-15", "100")
        insert_line(db, id, "603", "debit", "100")
        # Une seule ligne à ce stade : le contrôle est différé.
        db.scalar("SELECT accounting_entry_check_balance($1)", id).as(PG::Numeric).to_big_d.should eq(BigDecimal.new(100))
        insert_line(db, id, "510001", "credit", "100")
      end
      EntrySpec.scalar("SELECT count(*) FROM accounting_entry_line").should eq(2)
    end

    it "contrôle aussitôt avec SET CONSTRAINTS … IMMEDIATE" do
      EntrySpec.setup
      expect_raises(Exception, /déséquilibrée/) do
        EntrySpec.sql_transaction do |db|
          id = insert_entry(db, "2026-03-15", "50")
          insert_line(db, id, "603", "debit", "50")
          db.exec("SET CONSTRAINTS accounting_entry_line_balance IMMEDIATE")
        end
      end
    end

    it "refuse un montant d'en-tête différent du débit (check_balance < 0)" do
      EntrySpec.setup
      expect_raises(Exception, /déséquilibrée \(écart -10/) do
        EntrySpec.sql_transaction do |db|
          id = insert_entry(db, "2026-03-15", "110")
          insert_line(db, id, "603", "debit", "100")
          insert_line(db, id, "510001", "credit", "100")
        end
      end
    end

    it "refuse une écriture sans ligne" do
      EntrySpec.setup
      expect_raises(Exception, /déséquilibrée/) do
        EntrySpec.sql_transaction { |db| insert_entry(db, "2026-03-15", "10") }
      end
    end

    it "refuse la modification d'un montant qui déséquilibre une écriture enregistrée" do
      EntrySpec.setup
      view = EntrySpec.post_misc([EntrySpec.debit("603", "40"), EntrySpec.credit("510001", "40")])
      expect_raises(Exception, /déséquilibrée/) do
        EntrySpec.sql("UPDATE accounting_entry_line SET amount = 41 WHERE id = $1", view.lines[0].id)
      end
      expect_raises(Exception, /déséquilibrée/) do
        EntrySpec.sql("DELETE FROM accounting_entry_line WHERE id = $1", view.lines[1].id)
      end
      expect_raises(Exception, /accounting_entry_line_side_check/) do
        EntrySpec.sql("UPDATE accounting_entry_line SET side = 'both' WHERE id = $1", view.lines[1].id)
      end
      expect_raises(Exception, /accounting_entry_line_amount_check/) do
        EntrySpec.sql("UPDATE accounting_entry_line SET amount = -40 WHERE id = $1", view.lines[1].id)
      end
    end
  end

  describe "période (jrn_check_periode, is_closed)" do
    it "calcule la période à partir de la date, quelle que soit la valeur fournie" do
      EntrySpec.setup
      id = 0_i64
      EntrySpec.sql_transaction do |db|
        id = insert_entry(db, "2026-05-20", "10")
        insert_line(db, id, "603", "debit", "10")
        insert_line(db, id, "510001", "credit", "10")
      end
      EntrySpec.scalar("SELECT period_id FROM accounting_entry WHERE id = $1", id).should eq(EntrySpec.period("2026-05-20").id)
    end

    it "refuse une écriture hors exercice" do
      EntrySpec.setup
      expect_raises(Exception, /hors exercice/) do
        EntrySpec.sql_transaction do |db|
          id = insert_entry(db, "2030-01-10", "10")
          insert_line(db, id, "603", "debit", "10")
          insert_line(db, id, "510001", "credit", "10")
        end
      end
    end

    it "refuse toute écriture, ligne ou modification dans une période close" do
      EntrySpec.setup
      view = EntrySpec.post_misc([EntrySpec.debit("603", "40"), EntrySpec.credit("510001", "40")], "2026-03-15")
      Partiduo::Api::Core.close_period(EntrySpec.system, EntrySpec.period("2026-03-15").id).value!

      expect_raises(Exception, /période close/) do
        EntrySpec.sql_transaction do |db|
          id = insert_entry(db, "2026-03-20", "10")
          insert_line(db, id, "603", "debit", "10")
          insert_line(db, id, "510001", "credit", "10")
        end
      end
      expect_raises(Exception, /période close/) do
        EntrySpec.sql("UPDATE accounting_entry_line SET account_id = $1 WHERE id = $2", account_id("641"), view.lines[0].id)
      end
      expect_raises(Exception, /période close/) { EntrySpec.sql("DELETE FROM accounting_entry WHERE id = $1", view.id) }
      expect_raises(Exception, /période close/) do
        EntrySpec.sql("UPDATE accounting_entry SET date = '2026-04-02' WHERE id = $1", view.id)
      end
      expect_raises(Exception, /période close/) do
        EntrySpec.sql_transaction { |db| insert_line(db, view.id, "603", "debit", "0") }
      end

      # Libellé et lettrage restent permis (NOALYSS : date inchangée).
      EntrySpec.sql("UPDATE accounting_entry SET label = 'Corrigé' WHERE id = $1", view.id)
      Api.entry(EntrySpec.system, view.id).label.should eq("Corrigé")
    end

    it "refuse une écriture dans une période d'un exercice clos" do
      EntrySpec.setup
      year = Partiduo::Api::Core.fiscal_years(EntrySpec.system).first
      Partiduo::Api::Core.close_fiscal_year(EntrySpec.system, year.id).value!
      expect_raises(Exception, /période close/) do
        EntrySpec.sql_transaction do |db|
          id = insert_entry(db, "2026-06-10", "10")
          insert_line(db, id, "603", "debit", "10")
          insert_line(db, id, "510001", "credit", "10")
        end
      end
    end
  end

  describe "contraintes de colonnes" do
    it "refuse une pièce en double dans un journal et une double extourne" do
      EntrySpec.setup
      first = EntrySpec.post_misc([EntrySpec.debit("603", "10"), EntrySpec.credit("510001", "10")])
      second = EntrySpec.post_misc([EntrySpec.debit("603", "10"), EntrySpec.credit("510001", "10")])
      expect_raises(Exception, /accounting_entry_ledger_receipt/) do
        EntrySpec.sql("UPDATE accounting_entry SET receipt = $1 WHERE id = $2", first.receipt, second.id)
      end
      Api.cancel_entry(EntrySpec.system, Api::CancelEntryInput.new(first.id)).value!
      expect_raises(Exception, /accounting_entry_reversal_of/) do
        EntrySpec.sql("UPDATE accounting_entry SET reversal_of_id = $1 WHERE id = $2", first.id, second.id)
      end
    end

    it "protège les fiches et comptes cités par une ligne" do
      EntrySpec.setup
      supplier = EntrySpec.card("SUPPLIER", "Fournisseur cité")
      EntrySpec.post_misc([EntrySpec.debit("603", "10"), EntrySpec.credit("", "10", supplier.code)])
      Partiduo::Api::Cards.delete_card(EntrySpec.system, supplier.id).failure?.should be_true
      result = Api.delete_account(EntrySpec.system, account_id("603"))
      result.error_keys.should eq(["accounting.errors.account.in_use"])
    end
  end
end
