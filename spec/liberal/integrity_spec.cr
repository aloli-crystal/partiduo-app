# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias Api = Partiduo::Api::Liberal
private alias L = LiberalSpec

private def sql(statement : String, *args) : Nil
  Marten::DB::Connection.default.open(&.exec(statement, *args))
end

private def refused(statement : String, *args, pattern : Regex = /./) : Nil
  expect_raises(Exception, pattern) { sql(statement, *args) }
end

private LINE = "INSERT INTO liberal_line (number, kind, date, nature_id, heading, amount, nondeductible_amount, method, " \
               "party_name, label, reference, origin, source, reversal_of_id, recorded_at) " \
               "VALUES ($1, $2, $3::date, $4, $5, $6::numeric, $7::numeric, $8, '', '', '', $9, $10, $11, now())"

private def line_sql(number : String, amount : String, nature : String = "RENT", kind : String = "expense",
                     nondeductible : String = "0", method : String = "cash", origin : String = "manual",
                     source : String = "", reversal_of : Int64? = nil, date : String = "2026-09-01") : Nil
  sql(LINE, number, kind, date, L.nature(nature).id, L.nature(nature).heading, amount, nondeductible, method, origin,
    source, reversal_of)
end

# Contraintes posées en base par la migration liberal 0001 (ADR-007 D6) :
# elles tiennent même si un code contourne le contrat.
describe_module "LIBERAL", Api do
  it "refuse en base un montant, une part non déductible ou une valeur fermée invalides" do
    L.setup
    expect_raises(Exception, /liberal_line_amount_check/) { line_sql("X1", "-5") }
    expect_raises(Exception, /liberal_line_amount_check/) { line_sql("X2", "0") }
    expect_raises(Exception, /liberal_line_amount_check/) { line_sql("X3", "10", nondeductible: "11") }
    expect_raises(Exception, /liberal_line_amount_check/) { line_sql("X4", "10", nondeductible: "-1") }
    expect_raises(Exception, /liberal_line_amount_check/) do
      line_sql("X5", "10", "RECEIPTS", "receipt", nondeductible: "1")
    end
    expect_raises(Exception, /liberal_line_values_check/) { line_sql("X6", "10", method: "bitcoin") }
    expect_raises(Exception, /liberal_line_values_check/) { line_sql("X7", "10", origin: "import") }
    expect_raises(Exception, /liberal_line_nature_fk/) do
      sql(LINE, "X8", "expense", "2026-09-01", 999_999_i64, "rent", "10", "0", "cash", "manual", "", nil)
    end
    line_sql("X9", "10")
    expect_raises(Exception, /liberal_line_number|unique|duplicate/) { line_sql("X9", "10") }
    Api.lines(L.system).map(&.number).should eq(["X9"])
  end

  it "n'admet qu'une contre-passation négative par ligne et une seule inscription par référence d'origine" do
    L.setup
    line = L.expense("2026-09-01", "50", "RENT")
    expect_raises(Exception, /liberal_line_amount_check/) { line_sql("R1", "50", reversal_of: line.id) }
    line_sql("R2", "-50", reversal_of: line.id)
    expect_raises(Exception, /liberal_line_reversal/) { line_sql("R3", "-50", reversal_of: line.id) }
    Api.line(L.system, line.id).reversed_by_id.should_not be_nil

    line_sql("S1", "10", "RECEIPTS", "receipt", origin: "invoicing", source: "payment:1")
    expect_raises(Exception, /liberal_line_source/) do
      line_sql("S2", "10", "RECEIPTS", "receipt", origin: "invoicing", source: "payment:1")
    end
    # Sans référence d'origine, pas d'unicité.
    line_sql("S3", "10", "RECEIPTS", "receipt")
    line_sql("S4", "10", "RECEIPTS", "receipt")
  end

  it "rend livre-journal, immobilisations et cessions d'une période close intangibles et ferme les périodes closes" do
    L.setup
    line = L.expense("2026-02-10", "30", "OFFICE")
    asset = L.asset("2026-02-11", "900", 3)
    Api.dispose_asset(L.actor, Api::DisposalInput.new(asset.id, L.date("2026-02-20"), L.d("100"), "cash")).value!
    # Exercice ouvert : la base admet la modification (D-LIB2-001)…
    sql("UPDATE liberal_line SET label = 'x' WHERE id = $1", line.id)
    # …pas une fois la période close.
    L.close_period("2026-02-15")
    refused("DELETE FROM liberal_line WHERE id = $1", line.id, pattern: /intangible/)
    refused("UPDATE liberal_line SET amount = 1 WHERE id = $1", line.id, pattern: /intangible/)
    refused("UPDATE liberal_asset SET duration_years = 5 WHERE id = $1", asset.id, pattern: /intangible/)
    refused("DELETE FROM liberal_asset WHERE id = $1", asset.id, pattern: /intangible/)
    refused("UPDATE liberal_disposal SET price = 1 WHERE asset_id = $1", asset.id, pattern: /intangible/)
    refused("DELETE FROM liberal_disposal WHERE asset_id = $1", asset.id, pattern: /intangible/)

    refused("UPDATE liberal_line SET date = '2026-02-10' WHERE id = $1",
      L.expense("2026-03-01", "5", "OFFICE").id, pattern: /période close/)

    L.close_period("2026-01-15")
    refused(LINE, "C1", "expense", "2026-01-20", L.nature("RENT").id, "rent", "10", "0", "cash", "manual", "", nil,
      pattern: /période close/)
    refused("INSERT INTO liberal_asset (number, label, category, acquired_on, service_on, amount, duration_years, " \
            "method, party_name, reference, recorded_at) VALUES ('C2', 'x', 'office', '2026-01-20', '2026-01-20', " \
            "10, 1, 'cash', '', '', now())", pattern: /période close/)
    Api.lines(L.system).size.should eq(2)
    Api.assets(L.system).size.should eq(1)
  end

  it "contrôle en base immobilisations, cessions, ajustements, table de correspondance et compteurs" do
    L.setup
    asset_sql = "INSERT INTO liberal_asset (number, label, category, acquired_on, service_on, amount, duration_years, " \
                "method, party_name, reference, recorded_at) VALUES ($1, 'x', $2, '2026-03-01', $3::date, $4::numeric, " \
                "$5, 'cash', '', '', now())"
    refused(asset_sql, "A1", "office", "2026-02-01", "10", 1, pattern: /liberal_asset_amount_check/)
    refused(asset_sql, "A2", "office", "2026-03-01", "10", 51, pattern: /liberal_asset_amount_check/)
    refused(asset_sql, "A3", "office", "2026-03-01", "-10", 1, pattern: /liberal_asset_amount_check/)
    refused(asset_sql, "A4", "yacht", "2026-03-01", "10", 1, pattern: /liberal_asset_values_check/)

    asset = L.asset("2026-03-01", "900", 3)
    disposal_sql = "INSERT INTO liberal_disposal (asset_id, date, price, method, reference, recorded_at) " \
                   "VALUES ($1, '2026-04-01', $2::numeric, 'cash', '', now())"
    refused(disposal_sql, asset.id, "-1", pattern: /liberal_disposal_values_check/)
    refused(disposal_sql, 999_999_i64, "1", pattern: /liberal_disposal_asset_fk/)
    sql(disposal_sql, asset.id, "1")
    refused(disposal_sql, asset.id, "2", pattern: /unique|duplicate/)

    adjustment_sql = "INSERT INTO liberal_adjustment (year, kind, label, amount, recorded_at) " \
                     "VALUES ($1, $2, 'x', $3::numeric, now())"
    refused(adjustment_sql, 2026, "deduction", "0", pattern: /liberal_adjustment_values_check/)
    refused(adjustment_sql, 2026, "bonus", "1", pattern: /liberal_adjustment_values_check/)
    refused(adjustment_sql, 1800, "deduction", "1", pattern: /liberal_adjustment_values_check/)

    form_sql = "INSERT INTO liberal_form_line (millesime, item, form, line, box, created_at, updated_at) " \
               "VALUES ($1, $2, $3, '1', 'AA', now(), now())"
    refused(form_sql, 2026, "receipts", "2036", pattern: /liberal_form_line_values_check/)
    refused(form_sql, 1999, "receipts", "2035-A", pattern: /liberal_form_line_values_check/)
    refused(form_sql, 2024, "receipts", "2035-A", pattern: /liberal_form_line_unique|unique|duplicate/)

    refused("INSERT INTO liberal_counter (register, year, next_number) VALUES ('invoice', 2026, 1)",
      pattern: /liberal_counter_checks/)
    refused("UPDATE liberal_counter SET next_number = 0", pattern: /liberal_counter_checks/)
    refused("INSERT INTO liberal_nature (code, label, kind, heading, enabled, created_at, updated_at) " \
            "VALUES ('LOAN', 'x', 'loan', 'rent', true, now(), now())", pattern: /liberal_nature_kind_check/)
  end

  it "fige en base les ajustements d'une année dont une période est close" do
    L.setup
    adjustment = Api.add_adjustment(L.actor, Api::AdjustmentInput.new(2026, "deduction", "x", L.d("5"))).value!
    other = Api.add_adjustment(L.actor, Api::AdjustmentInput.new(2026, "provision", "y", L.d("7"))).value!
    Api.delete_adjustment(L.actor, other.id).value!
    Api.adjustments(L.system, 2026).map(&.id).should eq([adjustment.id])
    L.close_period("2026-01-15")
    refused("UPDATE liberal_adjustment SET amount = 9 WHERE id = $1", adjustment.id, pattern: /close/)
    refused("UPDATE liberal_adjustment SET year = 2027 WHERE id = $1", adjustment.id, pattern: /année/)
    refused("INSERT INTO liberal_adjustment (year, kind, label, amount, recorded_at) " \
            "VALUES (2026, 'deduction', 'z', 1, now())", pattern: /close/)
    # L'année suivante reste libre.
    ReferentialSpec.fiscal_year(2027)
    Api.add_adjustment(L.actor, Api::AdjustmentInput.new(2027, "deduction", "x", L.d("1"))).success?.should be_true
  end

  it "numérote sans trou ni doublon, même si un contrôle refuse une saisie" do
    L.setup
    L.receipt("2026-09-01", "10")
    Api.record_receipt(L.actor, L.input("2026-09-02", "-1", "RECEIPTS")).failure?.should be_true
    L.receipt("2026-09-03", "10").number.should eq("J2026-00002")
    L.expense("2026-09-04", "1", "OFFICE").number.should eq("J2026-00003")
  end
end
