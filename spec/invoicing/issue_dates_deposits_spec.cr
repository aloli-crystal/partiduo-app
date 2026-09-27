# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Clôture du lot 2F (relecture) : date d'émission bornée au jour même, date
# du jour dans le fuseau de l'instance (D-2F-002, D-2F-012), acompte crédité
# par avoir (D-2F-004).

private alias Api = Partiduo::Api::Invoicing

private def d(text : String) : BigDecimal
  BigDecimal.new(text)
end

private def actor : Partiduo::Api::Actor
  InvoicingSpec.actor
end

private def counter(series : String, year : Int32) : Int32?
  Partiduo::Invoicing::Counter.filter(series: series, year: year).first.try(&.last_number!.to_i32)
end

# Commande émise et facture d'acompte de 30 % émise.
private def order_and_deposit(setup : InvoicingSpec::Setup) : {Api::DocumentView, Api::DocumentView}
  order = InvoicingSpec.issued(setup, "order", on: "2026-09-01")
  deposit = Api.transform(actor, order.id, Api::TransformInput.new("deposit_invoice", deposit_percent: d("30"))).value!
  {order, InvoicingSpec.issue(deposit.id, "2026-09-02")}
end

# Avoir partiel (une heure de conseil au prix de l'acompte) d'une facture d'acompte.
private def partial_credit(setup : InvoicingSpec::Setup, deposit : Api::DocumentView, on : String) : Api::DocumentView
  credit = Api.transform(actor, deposit.id, Api::TransformInput.new("credit_note")).value!
  Api.update_document(actor, credit.id, InvoicingSpec.document_input(setup, "credit_note",
    credited_document_id: deposit.id, lines: [InvoicingSpec.line(setup, "1", unit_price: d("10"))])).value!
  InvoicingSpec.issue(credit.id, on)
end

describe_module "INVOICING", "Facturation — date d'émission (clôture du lot 2F)" do
  it "refuse une date d'émission postérieure au jour même, sans consommer de numéro" do
    setup = InvoicingSpec.setup
    draft = InvoicingSpec.draft(setup)
    result = Api.issue(actor, draft.id, Api::IssueInput.new(issue_date: InvoicingSpec.date("2026-12-31")))
    result.error_keys.should eq(["invoicing.errors.issue.future"])
    result.errors.first.field.should eq("issue_date")
    result.errors.first.params["date"].should eq("2026-09-27")
    counter("F", 2026).should be_nil
    Api.document(actor, draft.id).number.should be_nil

    # Le jour même passe ; la série n'est pas bloquée.
    InvoicingSpec.issue(draft.id, "2026-09-27").number.should eq("F-2026-0001")
  end

  it "refuse aussi la date prévue d'un brouillon quand elle est future" do
    setup = InvoicingSpec.setup
    draft = InvoicingSpec.draft(setup, issue_date: InvoicingSpec.date("2026-10-15"))
    Api.issue(actor, draft.id).error_keys.should eq(["invoicing.errors.issue.future"])
    Partiduo::Config.travel_to(Time.utc(2026, 10, 15, 8)) do
      Api.issue(actor, draft.id).value!.issue_date.should eq(InvoicingSpec.date("2026-10-15"))
    end
  end

  it "prend la date du jour dans le fuseau de l'instance, pas en UTC" do
    setup = InvoicingSpec.setup
    draft = InvoicingSpec.draft(setup)
    # 23 h 30 UTC le 27 : déjà le 28 à Paris (UTC+2 en septembre).
    Partiduo::Config.travel_to(Time.utc(2026, 9, 27, 23, 30)) do
      Partiduo::Config.today.should eq(InvoicingSpec.date("2026-09-28"))
      Partiduo::Api::Core.today.should eq(InvoicingSpec.date("2026-09-28"))
      issued = Api.issue(actor, draft.id).value!
      issued.issue_date.should eq(InvoicingSpec.date("2026-09-28"))
      issued.due_date.should eq(InvoicingSpec.date("2026-10-28"))
    end
    Partiduo::Config.time_zone.name.should eq("Europe/Paris")
  end
end

describe_module "INVOICING", "Facturation — acompte crédité par avoir (clôture du lot 2F)" do
  it "refuse de déduire un acompte qui porte un avoir, et ne le propose plus" do
    setup = InvoicingSpec.setup
    order, deposit = order_and_deposit(setup)
    partial_credit(setup, deposit, "2026-09-03")
    credited = Api.document(actor, deposit.id)
    credited.status.should_not eq("cancelled")
    credited.totals.credited.should eq(d("12"))

    # La transformation ne reprend plus l'acompte crédité…
    final = Api.transform(actor, order.id, Api::TransformInput.new("invoice")).value!
    final.deductions.should be_empty
    # … et il ne peut pas être ajouté à la main.
    input = InvoicingSpec.document_input(setup, "invoice", deposit_ids: [deposit.id])
    Api.check_document(actor, input).errors.map { |error| {error.field, error.key} }
      .should eq([{"deposit_ids[0]", "invoicing.errors.document.deposits.credited"}])
  end

  it "refuse l'émission quand l'acompte est crédité après la saisie de la facture finale" do
    setup = InvoicingSpec.setup
    order, deposit = order_and_deposit(setup)
    final = Api.transform(actor, order.id, Api::TransformInput.new("invoice")).value!
    final.deductions.map(&.deposit_id).should eq([deposit.id])
    partial_credit(setup, deposit, "2026-09-05")

    result = Api.issue(actor, final.id, Api::IssueInput.new(issue_date: InvoicingSpec.date("2026-09-20")))
    result.error_keys.should eq(["invoicing.errors.document.deposits.credited"])
    Api.document(actor, final.id).number.should be_nil
  end

  it "refuse un avoir sur un acompte déjà déduit d'une facture émise" do
    setup = InvoicingSpec.setup
    order, deposit = order_and_deposit(setup)
    final = Api.transform(actor, order.id, Api::TransformInput.new("invoice")).value!
    InvoicingSpec.issue(final.id, "2026-09-20")

    credit = Api.transform(actor, deposit.id, Api::TransformInput.new("credit_note"))
    credit.errors.map(&.key).should eq(["invoicing.errors.document.credited.deposit_deducted"])
    # Aucun brouillon d'avoir n'est créé.
    Partiduo::Invoicing::Document.filter(kind: "credit_note").count.should eq(0)
  end

  it "refuse à l'émission un brouillon d'avoir d'un acompte déduit entre-temps" do
    setup = InvoicingSpec.setup
    order, deposit = order_and_deposit(setup)
    credit = Api.transform(actor, deposit.id, Api::TransformInput.new("credit_note")).value!
    final = Api.transform(actor, order.id, Api::TransformInput.new("invoice")).value!
    InvoicingSpec.issue(final.id, "2026-09-20")
    Api.issue(actor, credit.id, Api::IssueInput.new(issue_date: InvoicingSpec.date("2026-09-21")))
      .error_keys.should eq(["invoicing.errors.document.credited.deposit_deducted"])
  end
end
