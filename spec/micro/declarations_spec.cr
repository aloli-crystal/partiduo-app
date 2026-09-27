# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias Api = Partiduo::Api::Micro
private alias M = MicroSpec

# Lot G (tests) : cas limites de l'aide à la déclaration URSSAF, de la
# 2042-C-PRO et des seuils (ADR-007 D1, D-MIC-006, D-MIC-007, D-MIC-010).

private def threshold(year : Int32, kind : String, scope : String) : Partiduo::Api::Micro::ThresholdView
  Api.thresholds(M.system, year).thresholds.find! { |row| row.kind == kind && row.scope == scope }
end

describe_module "MICRO", Api do
  describe "périodes et échéances" do
    it "passe d'ouverte à due puis en retard aux bornes exactes" do
      M.setup
      third = ->(today : String) { Api.declarations(M.system, 2026, M.date(today))[2].status }
      third.call("2026-09-30").should eq("open")
      third.call("2026-10-01").should eq("due")
      third.call("2026-10-31").should eq("due")
      third.call("2026-11-01").should eq("late")
    end

    it "place l'échéance au dernier jour du mois suivant, y compris en février et en fin d'année" do
      M.setup(periodicity: "monthly")
      periods = Api.declarations(M.system, 2026, M.date("2026-09-27"))
      periods[0].due_on.should eq(M.date("2026-02-28"))
      periods[1].ends_on.should eq(M.date("2026-02-28"))
      periods[1].due_on.should eq(M.date("2026-03-31"))
      periods[11].ends_on.should eq(M.date("2026-12-31"))
      periods[11].due_on.should eq(M.date("2027-01-31"))
      Api.declarations(M.system, 2028, M.date("2026-09-27"))[1].ends_on.should eq(M.date("2028-02-29"))
      Api.update_settings(M.actor, Api::SettingsInput.new(periodicity: "quarterly")).value!
      Api.declarations(M.system, 2026, M.date("2026-09-27")).last.due_on.should eq(M.date("2027-01-31"))
    end

    it "compte une contre-passation à sa propre date, pas à celle de la ligne" do
      M.setup
      line = M.receipt("2026-09-10", "1000", "SERVICE")
      Partiduo::Config.travel_to(Time.utc(2026, 10, 5, 9)) do
        Api.reverse_receipt(M.actor, Api::ReverseInput.new(line.id, M.date("2026-10-02"))).value!
      end
      periods = Api.declarations(M.system, 2026, M.date("2026-10-05"))
      periods[2].turnover.should eq(M.d("1000"))
      periods[3].turnover.should eq(M.d("-1000"))
      Api.tax_return(M.system, 2026).boxes.sum(BigDecimal.new(0), &.amount).should eq(M.d("0"))
    end

    it "ne compte pas les achats dans le chiffre d'affaires" do
      M.setup
      M.purchase("2026-09-12", "500")
      M.receipt("2026-09-12", "100", "SALE")
      Api.declarations(M.system, 2026, M.date("2026-09-27"))[2].turnover.should eq(M.d("100"))
      Api.thresholds(M.system, 2026).total_turnover.should eq(M.d("100"))
    end

    it "arrondit chaque cotisation au centime, demi-centime vers le haut" do
      M.setup
      M.receipt("2026-09-01", "5", "SALE") # CFP 0,1 % de 5 € = 0,005 €
      sale = Api.declarations(M.system, 2026, M.date("2026-09-27"))[2].contributions.find! { |row| row.category == "sale_bic" }
      sale.cfp.should eq(M.d("0.01"))
      sale.social.should eq(M.d("0.62")) # 12,3 % de 5 € = 0,615 €
      sale.flat_tax_rate.should be_nil
      sale.flat_tax.should eq(M.d("0"))
    end

    it "ne signale pas le versement libératoire manquant quand l'option n'est pas prise" do
      M.setup
      Api.parameters(M.system, "rate.flat_tax.bnc").each { |row| Api.delete_parameter(M.actor, row.id).value! }
      Api.declarations(M.system, 2026, M.date("2026-09-27"))[2].missing_rates.should be_empty
      Api.update_settings(M.actor, Api::SettingsInput.new(flat_tax: true)).value!
      Api.declarations(M.system, 2026, M.date("2026-09-27"))[2].missing_rates.should eq(["rate.flat_tax.bnc"])
    end
  end

  describe "déclaration faite" do
    it "refuse une date à venir, une référence trop longue et un début de période mensuelle faux" do
      M.setup
      Api.mark_declared(M.actor, Api::DeclarationInput.new(M.date("2026-07-01"), M.date("2026-10-15")))
        .error_keys.should eq(["micro.errors.declaration.future"])
      Api.mark_declared(M.actor, Api::DeclarationInput.new(M.date("2026-04-01"), M.date("2026-07-10"), "x" * 101))
        .error_keys.should eq(["micro.errors.line.too_long"])
      Api.update_settings(M.actor, Api::SettingsInput.new(periodicity: "monthly")).value!
      Api.mark_declared(M.actor, Api::DeclarationInput.new(M.date("2026-05-02"), M.date("2026-07-10")))
        .error_keys.should eq(["micro.errors.declaration.period.invalid"])
      declared = Api.mark_declared(M.actor, Api::DeclarationInput.new(M.date("2026-05-01"), M.date("2026-06-10"))).value!
      declared.ends_on.should eq(M.date("2026-05-31"))
      declared.declared_on.should eq(M.date("2026-06-10"))
    end

    it "garde une déclaration faite au statut « déclarée », même en retard" do
      M.setup
      Api.mark_declared(M.actor, Api::DeclarationInput.new(M.date("2026-01-01"), M.date("2026-09-01"))).value!
      Api.declarations(M.system, 2026, M.date("2026-09-27")).first.status.should eq("declared")
    end
  end

  describe "« À traiter »" do
    it "ne rappelle rien sans début d'activité ni recette" do
      M.setup
      Api.todo(M.system, M.date("2026-09-27")).select(&.kind.==("declaration")).should be_empty
    end

    it "part de la première recette à défaut de début d'activité" do
      M.setup
      M.receipt("2026-05-10", "10")
      items = Api.todo(M.system, M.date("2026-09-27")).select(&.kind.==("declaration"))
      items.map(&.params["from"]).should eq(["2026-04-01"])
      items.first.due_on.should eq(M.date("2026-07-31"))
      items.first.key.should eq("micro.todo.declaration_late")
    end

    it "rappelle une déclaration due, de ton « primary », puis en retard" do
      M.setup(activity_started_on: M.date("2026-07-01"))
      due = Api.todo(M.system, M.date("2026-10-10")).select(&.kind.==("declaration"))
      due.map { |item| {item.params["from"], item.key, item.tone} }
        .should eq([{"2026-07-01", "micro.todo.declaration_due", "primary"}])
      Api.todo(M.system, M.date("2026-11-02")).find!(&.kind.==("declaration")).tone.should eq("gap")
    end

    it "remonte les périodes des années antérieures non déclarées" do
      M.setup(activity_started_on: M.date("2025-10-01"))
      items = Api.todo(M.system, M.date("2026-01-15")).select(&.kind.==("declaration"))
      items.map(&.params["from"]).should eq(["2025-10-01"])
      items.first.key.should eq("micro.todo.declaration_due")
    end
  end

  describe "2042-C-PRO" do
    it "donne zéro pour une catégorie sans recette et une case vide si le paramètre manque" do
      M.setup
      Api.parameters(M.system, "box.bnc").each { |row| Api.delete_parameter(M.actor, row.id).value! }
      M.receipt("2026-03-10", "99.50", "SALE", vat_amount: M.d("0.01"))
      boxes = Api.tax_return(M.system, 2026).boxes
      boxes.map(&.category).should eq(%w[sale_bic service_bic bnc])
      boxes[0].amount.should eq(M.d("99")) # 99,49 € hors TVA
      boxes[1].amount.should eq(M.d("0"))
      boxes[2].box.should eq("")
      Api.tax_return(M.system, 2025).boxes.map(&.amount).uniq!.should eq([M.d("0")])
    end

    it "prend la case du millésime en vigueur au 31 décembre" do
      M.setup
      Api.set_parameter(M.actor, Api::ParameterInput.new("box.sale_bic", M.date("2026-12-31"), text: "5ZZ")).value!
      Api.tax_return(M.system, 2026).boxes.first.box.should eq("5ZZ")
      Api.tax_return(M.system, 2025).boxes.first.box.should eq("5KO")
    end
  end

  describe "seuils" do
    it "n'alerte pas au seuil atteint exactement, mais au premier centime au-delà" do
      M.setup
      M.receipt("2026-02-10", "37500", "SERVICE")
      vat = threshold(2026, "vat", "services")
      vat.ratio.should eq(M.d("100"))
      vat.status.should eq("approaching")
      M.receipt("2026-02-11", "0.01", "SERVICE")
      threshold(2026, "vat", "services").status.should eq("exceeded")
      Api.thresholds(M.system, 2026).alerts.map(&.key).should contain("micro.alerts.vat.exceeded")
    end

    it "franchit le seuil du régime micro" do
      M.setup
      M.receipt("2026-02-10", "83600.01", "FEE")
      micro = threshold(2026, "micro", "services")
      micro.status.should eq("exceeded")
      threshold(2026, "vat", "services").status.should eq("tolerance_exceeded")
      threshold(2026, "micro", "goods").status.should eq("ok")
      Api.todo(M.system, M.date("2026-09-27")).select(&.kind.==("threshold")).map(&.key).sort!
        .should eq(%w[micro.alerts.micro.exceeded micro.alerts.vat.approaching micro.alerts.vat.tolerance_exceeded])
    end

    it "dit « inconnu » quand un seuil n'est pas paramétré, et n'alerte pas sans ratio d'alerte" do
      M.setup
      Api.parameters(M.system, "threshold.vat.services").each { |row| Api.delete_parameter(M.actor, row.id).value! }
      Api.parameters(M.system, "alert.ratio").each { |row| Api.delete_parameter(M.actor, row.id).value! }
      M.receipt("2026-02-10", "36000", "SERVICE")
      vat = threshold(2026, "vat", "services")
      vat.status.should eq("unknown")
      vat.limit.should be_nil
      vat.ratio.should be_nil
      threshold(2026, "micro", "services").status.should eq("ok")
      Api.thresholds(M.system, 2026).alerts.should be_empty
    end

    it "prend le seuil en vigueur au 1er janvier de l'année suivie" do
      M.setup
      threshold(2025, "micro", "services").limit.should eq(M.d("77700"))
      threshold(2026, "micro", "goods").limit.should eq(M.d("203100"))
      Api.set_parameter(M.actor, Api::ParameterInput.new("threshold.vat.services", M.date("2026-07-01"), M.d("25000"))).value!
      threshold(2026, "vat", "services").limit.should eq(M.d("37500"))
      threshold(2027, "vat", "services").limit.should eq(M.d("25000"))
    end

    it "ne proratise pas le seuil l'année d'un début d'activité au 1er janvier, ni les années suivantes" do
      M.setup(activity_started_on: M.date("2026-01-01"))
      threshold(2026, "micro", "services").limit.should eq(M.d("83600"))
      Api.update_settings(M.actor, Api::SettingsInput.new(activity_started_on: M.date("2026-12-31"))).value!
      threshold(2026, "micro", "goods").limit.should eq(M.d("556")) # 203 100 × 1 / 365
      threshold(2026, "vat", "goods").limit.should eq(M.d("85000"))
    end
  end
end
