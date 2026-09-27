# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Lot 2F — contraintes des écritures en base, cas non couverts par
# `entry_integrity_spec.cr` : déplacement d'une ligne entre écritures,
# changement de date ou de journal, contrôles de colonnes, clés étrangères,
# lettrage en période close, suppression complète d'une écriture. SQL direct,
# sans passer par le contrat.

private alias Api = Partiduo::Api::Accounting

private def account_id(number : String) : Int64
  Api.account(EntrySpec.system, number).id
end

private def od(amount = "40", day = "2026-03-15") : Api::EntryView
  EntrySpec.post_misc([EntrySpec.debit("603", amount), EntrySpec.credit("510001", amount)], day)
end

# Instruction SQL isolée sur une connexion dédiée, dans sa transaction : les
# déclencheurs différés jouent au COMMIT (B-ACC-002).
private def sql_alone(statement : String, *args) : Nil
  EntrySpec.sql_transaction(&.exec(statement, *args))
end

describe_module "ACCOUNTING", "Intégrité des écritures en base — cas limites (lot 2F)" do
  describe "équilibre" do
    it "refuse de déplacer une ligne d'une écriture vers une autre (les deux deviennent déséquilibrées)" do
      EntrySpec.setup
      a = od("40")
      b = od("25")
      expect_raises(Exception, /déséquilibrée/) do
        sql_alone("UPDATE accounting_entry_line SET entry_id = $1 WHERE id = $2", b.id, a.lines[0].id)
      end
      Api.entry(EntrySpec.system, a.id).lines.size.should eq(2)
    end

    it "refuse de changer le montant d'en-tête seul, admet un changement cohérent de toute l'écriture" do
      EntrySpec.setup
      view = od("40")
      expect_raises(Exception, /déséquilibrée/) do
        sql_alone("UPDATE accounting_entry SET amount = 41 WHERE id = $1", view.id)
      end
      EntrySpec.sql_transaction do |db|
        db.exec("UPDATE accounting_entry SET amount = 50 WHERE id = $1", view.id)
        db.exec("UPDATE accounting_entry_line SET amount = 50 WHERE entry_id = $1", view.id)
      end
      Api.entry(EntrySpec.system, view.id).amount.should eq(BigDecimal.new(50))
    end

    it "admet la suppression complète d'une écriture d'une période ouverte" do
      EntrySpec.setup
      view = od
      EntrySpec.sql_transaction do |db|
        db.exec("DELETE FROM accounting_entry_line WHERE entry_id = $1", view.id)
        db.exec("DELETE FROM accounting_entry WHERE id = $1", view.id)
      end
      EntrySpec.scalar("SELECT count(*) FROM accounting_entry").should eq(0)
    end
  end

  describe "période" do
    it "recalcule la période quand la date change dans l'exercice" do
      EntrySpec.setup
      view = od("10", "2026-03-15")
      sql_alone("UPDATE accounting_entry SET date = '2026-05-02' WHERE id = $1", view.id)
      Api.entry(EntrySpec.system, view.id).period_id.should eq(EntrySpec.period("2026-05-02").id)
    end

    it "refuse de déplacer une écriture vers une période close ou hors exercice" do
      EntrySpec.setup
      view = od("10", "2026-03-15")
      Partiduo::Api::Core.close_period(EntrySpec.system, EntrySpec.period("2026-01-10").id).value!
      expect_raises(Exception, /période close/) do
        sql_alone("UPDATE accounting_entry SET date = '2026-01-10' WHERE id = $1", view.id)
      end
      expect_raises(Exception, /hors exercice/) do
        sql_alone("UPDATE accounting_entry SET date = '2031-01-10' WHERE id = $1", view.id)
      end
      Api.entry(EntrySpec.system, view.id).date.should eq(EntrySpec.date("2026-03-15"))
    end

    it "refuse en période close de changer journal, montant ou devise, mais admet pièce et échéance" do
      EntrySpec.setup
      view = od("10", "2026-03-15")
      Partiduo::Api::Core.close_period(EntrySpec.system, EntrySpec.period("2026-03-15").id).value!
      expect_raises(Exception, /période close/) do
        sql_alone("UPDATE accounting_entry SET ledger_id = $1 WHERE id = $2", EntrySpec.ledger("A01").id, view.id)
      end
      expect_raises(Exception, /période close/) do
        sql_alone("UPDATE accounting_entry SET currency_rate = 2 WHERE id = $1", view.id)
      end
      expect_raises(Exception, /période close/) do
        sql_alone("UPDATE accounting_entry_line SET side = 'credit' WHERE id = $1", view.lines[0].id)
      end
      sql_alone("UPDATE accounting_entry SET receipt = 'CORR-1', due_date = '2026-04-30' WHERE id = $1", view.id)
      Api.entry(EntrySpec.system, view.id).receipt.should eq("CORR-1")
    end

    it "admet le lettrage d'une ligne en période close, et son retrait" do
      EntrySpec.setup
      view = od("10", "2026-03-15")
      Partiduo::Api::Core.close_period(EntrySpec.system, EntrySpec.period("2026-03-15").id).value!
      matching_id = EntrySpec.scalar(
        "INSERT INTO accounting_matching (account_id, created_at, updated_at) VALUES ($1, now(), now()) RETURNING id",
        account_id("603")).as(Int64)
      sql_alone("UPDATE accounting_entry_line SET matching_id = $1 WHERE id = $2", matching_id, view.lines[0].id)
      Api.entry(EntrySpec.system, view.id).lines[0].matching_id.should eq(matching_id)
      sql_alone("UPDATE accounting_entry_line SET matching_id = NULL WHERE id = $1", view.lines[0].id)
      Api.entry(EntrySpec.system, view.id).lines[0].matching_id.should be_nil
    end
  end

  describe "contraintes de colonnes et clés étrangères" do
    it "refuse devise mal formée, cours nul, montant d'en-tête nul, pièce vide et auto-extourne" do
      EntrySpec.setup
      view = od
      {
        "currency_code = 'eur'"     => /accounting_entry_currency_code_check/,
        "currency_rate = 0"         => /accounting_entry_currency_rate_check/,
        "receipt = '  '"            => /accounting_entry_receipt_check/,
        "reversal_of_id = id"       => /accounting_entry_reversal_check/,
        "amount = 0"                => /accounting_entry_amount_check/,
        "source = repeat('x', 101)" => /too long|trop long|value too long/i,
      }.each do |assignment, error|
        expect_raises(Exception, error) do
          sql_alone("UPDATE accounting_entry SET #{assignment} WHERE id = $1", view.id)
        end
      end
    end

    it "refuse un rôle de TVA inconnu, une fiche ou un taux inexistant sur une ligne" do
      EntrySpec.setup
      view = od
      line = view.lines[0].id
      expect_raises(Exception, /accounting_entry_line_vat_role_check/) do
        sql_alone("UPDATE accounting_entry_line SET vat_role = 'other' WHERE id = $1", line)
      end
      expect_raises(Exception, /accounting_entry_line_card_fk/) do
        sql_alone("UPDATE accounting_entry_line SET card_id = 987654 WHERE id = $1", line)
      end
      expect_raises(Exception, /accounting_entry_line_vat_rate_fk/) do
        sql_alone("UPDATE accounting_entry_line SET vat_rate_id = 987654 WHERE id = $1", line)
      end
      expect_raises(Exception, /accounting_entry_period_fk|accounting_entry_attachment_fk/) do
        sql_alone("UPDATE accounting_entry SET attachment_id = 987654 WHERE id = $1", view.id)
      end
    end

    it "refuse d'effacer un lettrage encore cité par des lignes" do
      EntrySpec.setup
      customer = EntrySpec.card("CUSTOMER", "Client lettré en base")
      sale = Api.post_sale(EntrySpec.system, EntrySpec.document("V01", customer.code,
        [EntrySpec.item("100", account: "706")])).value!
      payment = Api.post_financial(EntrySpec.system, Api::FinancialInput.new(ledger_id: EntrySpec.ledger("F01").id,
        date: EntrySpec.date("2026-03-20"), lines: [Api::PaymentLineInput.new(BigDecimal.new(120), card: customer.code,
        match_line_ids: [sale.lines.find! { |line| line.card_id == customer.id }.id])])).value!.first
      matching_id = ReferentialSpec.present(Api.entry(EntrySpec.system, payment.id).lines[0].matching_id)
      expect_raises(Exception, /foreign key|clé étrangère/i) do
        sql_alone("DELETE FROM accounting_matching WHERE id = $1", matching_id)
      end
    end
  end
end
