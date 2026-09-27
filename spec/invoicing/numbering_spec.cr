# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Abonné temporaire du socle qui fait échouer l'émission après l'attribution
# du numéro (dans la même transaction).
private def failing_on(event_name : String, &)
  manifest = Partiduo::Modules["CORE"]
  previous = manifest.subscriptions[event_name]?.try(&.dup)
  manifest.on(event_name) { |_event| raise "échec simulé après numérotation" }
  begin
    yield
  ensure
    if previous
      manifest.subscriptions[event_name] = previous
    else
      manifest.subscriptions.delete(event_name)
    end
  end
end

private def counter(series : String, year : Int32) : Int32?
  Marten::DB::Connection.default.open do |db|
    db.query_one?("SELECT last_number FROM invoicing_counter WHERE series = $1 AND year = $2", series, year, as: Int32)
  end
end

# ADR-006 D5 : numéro attribué à l'émission par une table de compteurs
# verrouillée (`SELECT … FOR UPDATE`), jamais par une séquence PostgreSQL.
describe_module "INVOICING", "Facturation — numérotation" do
  it "n'attribue pas de numéro au brouillon, puis numérote à l'émission par série et par année" do
    setup = InvoicingSpec.setup
    draft = InvoicingSpec.draft(setup)
    draft.number.should be_nil
    draft.status.should eq("draft")
    InvoicingSpec.issue(draft.id).number.should eq("F-2026-0001")
    InvoicingSpec.issued(setup).number.should eq("F-2026-0002")
    InvoicingSpec.issued(setup, "quote").number.should eq("D-2026-0001")
    Partiduo::Config.travel_to(Time.utc(2027, 1, 2, 9)) do
      InvoicingSpec.issued(setup, "invoice", on: "2027-01-02").number.should eq("F-2027-0001")
    end
  end

  it "ne laisse aucun trou après une émission annulée" do
    setup = InvoicingSpec.setup
    InvoicingSpec.issued(setup).number.should eq("F-2026-0001")
    draft = InvoicingSpec.draft(setup)
    failing_on("invoice.issued") do
      expect_raises(Exception, "échec simulé") { InvoicingSpec.issue(draft.id) }
    end
    counter("F", 2026).should eq(1)
    Partiduo::Api::Invoicing.document(InvoicingSpec.actor, draft.id).number.should be_nil

    # Commande englobante annulée après l'émission : même effet.
    Partiduo::Api::Transaction.run do
      InvoicingSpec.issue(draft.id).number.should eq("F-2026-0002")
      Partiduo::Api::Result(Nil).failure(Partiduo::Api::FieldError.base("invoicing.errors.issue.no_line"))
    end
    counter("F", 2026).should eq(1)

    InvoicingSpec.issue(draft.id).number.should eq("F-2026-0002")
    Partiduo::Api::Invoicing.documents(InvoicingSpec.actor, Partiduo::Api::Invoicing::DocumentQuery.new(kind: "invoice"))
      .compact_map(&.number).sort!.should eq(["F-2026-0001", "F-2026-0002"])
  end

  it "ne produit aucun doublon sous émissions concurrentes" do
    setup = InvoicingSpec.setup
    count = 8
    drafts = Array.new(count) { InvoicingSpec.draft(setup).id }
    start = Channel(Nil).new
    done = Channel(String | Exception).new
    drafts.each do |id|
      spawn do
        start.receive
        result = Partiduo::Api::Invoicing.issue(InvoicingSpec.actor, id,
          Partiduo::Api::Invoicing::IssueInput.new(issue_date: InvoicingSpec.date("2026-09-15")))
        done.send(result.value!.number || "")
      rescue ex
        done.send(ex)
      end
    end
    count.times { start.send(nil) }
    numbers = Array.new(count) do
      value = done.receive
      raise value if value.is_a?(Exception)
      value
    end
    numbers.sort.should eq((1..count).map { |sequence| "F-2026-#{sequence.to_s.rjust(4, '0')}" })
    counter("F", 2026).should eq(count)
  end

  it "refuse une date antérieure au dernier document de la série (chronologie)" do
    setup = InvoicingSpec.setup
    InvoicingSpec.issued(setup, on: "2026-09-15")
    draft = InvoicingSpec.draft(setup)
    result = Partiduo::Api::Invoicing.issue(InvoicingSpec.actor, draft.id,
      Partiduo::Api::Invoicing::IssueInput.new(issue_date: InvoicingSpec.date("2026-09-14")))
    result.error_keys.should eq(["invoicing.errors.issue.before_last"])
    counter("F", 2026).should eq(1)
  end

  it "garantit en base l'unicité (série, numéro) et l'avance d'une unité des compteurs" do
    setup = InvoicingSpec.setup
    first = InvoicingSpec.issued(setup)
    second = InvoicingSpec.draft(setup)
    InvoicingSpec.sql_error("UPDATE invoicing_document SET number = $1, series = 'F', year = 2026, sequence = 1, " \
                            "issued_at = now(), issue_date = '2026-09-15', fingerprint = 'x', status = 'issued' " \
                            "WHERE id = $2", first.number, second.id).should_not be_nil
    InvoicingSpec.sql_error("UPDATE invoicing_counter SET last_number = last_number + 2").to_s.should contain("unité")
    InvoicingSpec.sql_error("UPDATE invoicing_counter SET last_number = last_number - 1").to_s.should contain("unité")
    InvoicingSpec.sql_error("DELETE FROM invoicing_counter").to_s.should contain("non supprimable")
    Marten::DB::Connection.default.open do |db|
      db.query_one("SELECT count(*) FROM pg_class WHERE relkind = 'S' AND relname LIKE 'invoicing_counter%' " \
                   "AND relname NOT LIKE '%id_seq'", as: Int64).should eq(0)
    end
  end

  it "calcule la communication structurée belge (modulo 97)" do
    reference = Partiduo::Invoicing::Numbering.structured_reference("F", 2026, 42)
    reference.should eq("+++261/0000/04290+++") # 2610000042 mod 97 = 90
    Partiduo::Invoicing::Numbering.valid_structured_reference?(reference).should be_true
    Partiduo::Invoicing::Numbering.valid_structured_reference?("+++261/0000/04291+++").should be_false
    # Reste nul : clé 97.
    Partiduo::Invoicing::Numbering.structured_reference("F", 2026, 49).should eq("+++261/0000/04997+++")
  end
end
