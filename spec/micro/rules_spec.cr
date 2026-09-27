# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias Api = Partiduo::Api::Micro
private alias M = MicroSpec

# Lot G (tests) : cas limites des registres de la micro-entreprise (ADR-007
# D1, D-MIC-003) — numérotation, contre-passation, filtres, paramètres,
# natures, articles — et contraintes d'intégrité posées en base par la
# migration micro 0001. Tout passe par `Partiduo::Api::Micro` ; seules les
# contraintes en base sont éprouvées en SQL direct.

private def card(category : String, name : String, **options) : Partiduo::Api::Cards::CardView
  cards = Partiduo::Api::Cards
  found = cards.category_by_code(M.system, category) || raise "catégorie #{category} absente"
  cards.create_card(M.system, Partiduo::Api::Cards::CardInput.new(category_id: found.id, name: name).copy_with(**options)).value!
end

describe_module "MICRO", Api do
  describe "numérotation" do
    it "numérote chaque registre séparément, par année de la date de la ligne" do
      M.setup
      ReferentialSpec.fiscal_year(2025)
      M.receipt("2026-09-01").number.should eq("R2026-00001")
      M.purchase("2026-09-01").number.should eq("A2026-00001")
      M.receipt("2025-12-31").number.should eq("R2025-00001")
      M.receipt("2026-01-02").number.should eq("R2026-00002")
      M.purchase("2025-06-30").number.should eq("A2025-00001")
      # Livre tenu par date, puis numéro : la ligne de 2025 vient en tête.
      Api.receipts(M.system).map(&.number).should eq(%w[R2025-00001 R2026-00002 R2026-00001])
    end

    it "numérote une contre-passation dans l'année de sa propre date" do
      M.setup
      Partiduo::Config.travel_to(Time.utc(2027, 1, 10, 9)) do
        line = M.receipt("2026-12-20", "90")
        reversal = Api.reverse_receipt(M.actor, Api::ReverseInput.new(line.id, M.date("2027-01-05"))).value!
        reversal.number.should eq("R2027-00001")
        reversal.reference.should eq(line.number)
      end
    end
  end

  describe "saisie" do
    it "borne les longueurs et contrôle la TVA comprise" do
      M.setup
      Api.record_receipt(M.actor, M.receipt_input(party_name: "x" * 256, label: "y" * 256)).error_keys
        .should eq(%w[micro.errors.line.too_long micro.errors.line.too_long])
      Api.record_receipt(M.actor, M.receipt_input(party_name: "x" * 255, label: "y" * 255)).success?.should be_true
      Api.record_receipt(M.actor, M.receipt_input(amount: "0")).error_keys.should eq(["micro.errors.line.amount.not_positive"])
      Api.record_receipt(M.actor, M.receipt_input(vat_amount: M.d("-1"))).error_keys.should eq(["micro.errors.line.vat_amount.invalid"])
      Api.record_receipt(M.actor, M.receipt_input(vat_amount: M.d("1.001"))).error_keys.should eq(["micro.errors.line.vat_amount.invalid"])
      Api.record_receipt(M.actor, M.receipt_input(amount: "100", vat_amount: M.d("100.01")))
        .error_keys.should eq(["micro.errors.line.vat_amount.exceeds"])
      Api.record_receipt(M.actor, M.receipt_input(amount: "120", vat_amount: M.d("20"))).value!.net_amount.should eq(M.d("100"))
    end

    it "accepte la date du jour, refuse le lendemain" do
      M.setup
      today = Partiduo::Config.today.to_s("%Y-%m-%d")
      tomorrow = (Partiduo::Config.today + 1.day).to_s("%Y-%m-%d")
      M.receipt(today).date.should eq(Partiduo::Config.today)
      Api.record_purchase(M.actor, Api::PurchaseInput.new(date: M.date(tomorrow), nature_id: M.nature("GOODS").id,
        amount: M.d("1"), method: "cash")).error_keys.should eq(["micro.errors.line.date.future"])
    end

    it "n'accepte une nature que dans son registre" do
      M.setup
      Api.record_purchase(M.actor, Api::PurchaseInput.new(date: M.date("2026-09-01"), nature_id: M.nature("SALE").id,
        amount: M.d("1"), method: "cash")).error_keys.should eq(["micro.errors.line.nature.unknown"])
      Api.record_receipt(M.actor, M.receipt_input(nature_id: 999_999_i64)).error_keys.should eq(["micro.errors.line.nature.unknown"])
      Api.check_purchase(M.actor, Api::PurchaseInput.new(date: M.date("2026-09-01"), nature_id: M.nature("GOODS").id,
        amount: M.d("-1"), method: "cheque")).error_keys.should eq(["micro.errors.line.amount.not_positive"])
      Api.purchases(M.system).should be_empty
    end

    it "prend le nom de la fiche quand le tiers n'est pas saisi, et garde le nom saisi sinon" do
      M.setup
      customer = card("CUSTOMER", "Boulangerie Durand")
      M.receipt(party_name: "", card_id: customer.id).party_name.should eq("Boulangerie Durand")
      M.receipt(party_name: "  Mme Durand  ", card_id: customer.id).party_name.should eq("Mme Durand")
      M.receipt(party_name: "").party_name.should eq("")
    end

    it "fige la catégorie de la nature au moment de l'inscription" do
      M.setup
      nature = Api.create_nature(M.actor, Api::NatureInput.new("ATELIER", "Ateliers", "receipt", "bnc")).value!
      Api.update_nature(M.actor, nature.id, Api::NatureInput.new("ATELIER", "Ateliers", "receipt", "service_bic")).value!
      M.receipt(nature: "ATELIER").category.should eq("service_bic")
    end
  end

  describe "contre-passation" do
    it "refuse une contre-passation datée dans le futur" do
      M.setup
      line = M.receipt("2026-09-10", "100")
      Api.reverse_receipt(M.actor, Api::ReverseInput.new(line.id, M.date("2026-09-28")))
        .error_keys.should eq(["micro.errors.line.date.future"])
      purchase = M.purchase("2026-09-10", "10")
      Api.reverse_purchase(M.actor, Api::ReverseInput.new(purchase.id, M.date("2026-10-01")))
        .error_keys.should eq(["micro.errors.line.date.future"])
      Api.receipt(M.system, line.id).reversed_by_id.should be_nil
    end

    it "contre-passe un achat : même nature, montant opposé, récapitulatif net" do
      M.setup
      ReferentialSpec.capture_events("micro.purchase.recorded") do |events|
        purchase = M.purchase("2026-09-12", "40", label: "Stock", reference: "FAC-9")
        reversal = Api.reverse_purchase(M.actor, Api::ReverseInput.new(purchase.id, M.date("2026-09-13"), "Retour")).value!
        reversal.amount.should eq(M.d("-40"))
        reversal.nature_code.should eq("GOODS")
        reversal.label.should eq("Retour")
        reversal.reference.should eq(purchase.number)
        reversal.reversal?.should be_true
        reversal.party_name.should eq("Grossiste SA")
        Api.purchase(M.system, purchase.id).reversed_by_id.should eq(reversal.id)
        events.size.should eq(2)
        events.last.payload["reversal_of_id"].should eq(purchase.id.to_s)
        events.last.payload["amount"].should eq("-40.0")
        events.last.payload["origin"].should eq("manual")
      end
      M.purchase("2026-09-14", "5", "SUPPLIES")
      Api.purchase_totals(M.system, 2026).map { |row| {row.nature_code, row.amount} }
        .should eq([{"GOODS", M.d("0")}, {"SUPPLIES", M.d("5")}])
      Api.purchase_totals(M.system, 2025).should be_empty
    end

    it "contre-passe une recette avec sa TVA et garde la pièce d'origine hors de la contre-passation" do
      M.setup
      stored = Partiduo::Api::Core.store_attachment(M.uploader, Partiduo::Api::Core::AttachmentInput.new("ticket.pdf",
        "application/pdf", IO::Memory.new("%PDF-1.4 ticket"))).value!
      line = M.receipt("2026-09-10", "120", vat_amount: M.d("20"), attachment_id: stored.id)
      reversal = Api.reverse_receipt(M.actor, Api::ReverseInput.new(line.id, M.date("2026-09-10"))).value!
      reversal.vat_amount.should eq(M.d("-20"))
      reversal.net_amount.should eq(M.d("-100"))
      reversal.attachment_id.should be_nil
      reversal.origin.should eq("manual")
    end

    it "signale une ligne inconnue" do
      M.setup
      expect_raises(Partiduo::Api::NotFound) { Api.reverse_receipt(M.actor, Api::ReverseInput.new(999_999_i64, M.date("2026-09-10"))) }
      expect_raises(Partiduo::Api::NotFound) { Api.reverse_purchase(M.actor, Api::ReverseInput.new(999_999_i64, M.date("2026-09-10"))) }
      expect_raises(Partiduo::Api::NotFound) { Api.receipt(M.system, 999_999_i64) }
      expect_raises(Partiduo::Api::NotFound) { Api.purchase(M.system, 999_999_i64) }
    end
  end

  describe "consultation" do
    it "filtre par dates, nature, catégorie, et pagine" do
      M.setup
      M.receipt("2026-07-01", "10", "SALE")
      M.receipt("2026-08-01", "20", "SERVICE")
      M.receipt("2026-09-01", "30", "FEE")
      M.receipt("2026-09-02", "40", "SERVICE")
      range = Api.receipts(M.system, Api::RegisterQuery.new(from: M.date("2026-08-01"), to: M.date("2026-09-01")))
      range.map(&.amount).should eq([M.d("20"), M.d("30")])
      Api.receipts(M.system, Api::RegisterQuery.new(category: "service_bic")).map(&.amount).should eq([M.d("20"), M.d("40")])
      Api.receipts(M.system, Api::RegisterQuery.new(nature_id: M.nature("FEE").id)).map(&.amount).should eq([M.d("30")])
      Api.receipts(M.system, Api::RegisterQuery.new(limit: 2, offset: 1)).map(&.amount).should eq([M.d("20"), M.d("30")])
      csv = String.new(Api.export_receipts(M.system, Api::RegisterQuery.new(category: "bnc"), Api::ExportFormat::Csv).content)
      csv.lines.size.should eq(2)
    end

    it "republie un événement par ligne des deux registres" do
      M.setup
      M.receipt("2026-09-01", "10")
      line = M.receipt("2026-09-02", "20")
      Api.reverse_receipt(M.actor, Api::ReverseInput.new(line.id, M.date("2026-09-03"))).value!
      M.purchase("2026-09-04", "5")
      ReferentialSpec.capture_events("micro.receipt.recorded") do |receipts|
        ReferentialSpec.capture_events("micro.purchase.recorded") do |purchases|
          Api.republish(M.actor).should eq(4)
          receipts.map(&.payload["amount"]).should eq(["10.0", "20.0", "-20.0"])
          purchases.size.should eq(1)
        end
      end
    end
  end

  describe "paramètres" do
    it "contrôle la nature par défaut et note la date de début d'activité au jour" do
      M.setup
      Api.update_settings(M.actor, Api::SettingsInput.new(default_nature_id: M.nature("GOODS").id))
        .error_keys.should eq(["micro.errors.line.nature.unknown"])
      view = Api.update_settings(M.actor, Api::SettingsInput.new(periodicity: "monthly", flat_tax: true,
        activity_started_on: Time.utc(2026, 3, 4, 15, 30), default_nature_id: M.nature("FEE").id)).value!
      view.activity_started_on.should eq(M.date("2026-03-04"))
      view.default_nature_id.should eq(M.nature("FEE").id)
      Api.settings(M.system).flat_tax.should be_true
      Api.settings(M.system).periodicity.should eq("monthly")
    end

    it "remplace un paramètre de même code et même date, sans doublon" do
      M.setup
      before = Api.parameters(M.system, "alert.ratio").size
      Api.set_parameter(M.actor, Api::ParameterInput.new("alert.ratio", M.date("2026-01-01"), M.d("90"))).value!
      Api.set_parameter(M.actor, Api::ParameterInput.new("alert.ratio", M.date("2026-01-01"), M.d("75"), "ignoré")).value!
        .text.should eq("")
      Api.parameters(M.system, "alert.ratio").size.should eq(before + 1)
      Api.parameter_value(M.system, "alert.ratio", M.date("2026-06-30")).should eq(M.d("75"))
      Api.parameter_value(M.system, "alert.ratio", M.date("2025-12-31")).should eq(M.d("80"))
      Api.parameter_value(M.system, "alert.ratio", M.date("2019-12-31")).should be_nil
      box = Api.set_parameter(M.actor, Api::ParameterInput.new("box.sale_bic", M.date("2027-01-01"), M.d("5"), " 5KZ ")).value!
      box.value.should be_nil
      box.text.should eq("5KZ")
    end

    it "refuse une valeur trop précise, une case trop longue, et signale un paramètre inconnu" do
      M.setup
      Api.set_parameter(M.actor, Api::ParameterInput.new("rate.social.bnc", M.date("2026-01-01"), M.d("1.0000001")))
        .error_keys.should eq(["micro.errors.parameter.value.invalid"])
      Api.set_parameter(M.actor, Api::ParameterInput.new("rate.social.bnc", M.date("2026-01-01")))
        .error_keys.should eq(["micro.errors.parameter.value.invalid"])
      Api.set_parameter(M.actor, Api::ParameterInput.new("box.bnc", M.date("2026-01-01"), text: "x" * 61))
        .error_keys.should eq(["micro.errors.line.too_long"])
      expect_raises(Partiduo::Api::NotFound) { Api.delete_parameter(M.actor, 999_999_i64) }
    end

    it "ne recharge rien d'existant, quelle que soit la langue" do
      M.setup
      Api.load_defaults(M.actor, "nl").should eq(0)
      Api.load_defaults(M.actor, "xx").should eq(0)
    end
  end

  describe "natures" do
    it "contrôle code, libellé, sens et catégorie" do
      M.setup
      Api.create_nature(M.actor, Api::NatureInput.new("1AB", "", "gift", "bnc")).error_keys.sort
        .should eq(%w[micro.errors.nature.code.invalid micro.errors.nature.kind.invalid micro.errors.nature.label.blank])
      Api.create_nature(M.actor, Api::NatureInput.new("a b", "x" * 101, "purchase", "bnc")).error_keys.sort
        .should eq(%w[micro.errors.line.too_long micro.errors.nature.category.invalid micro.errors.nature.code.invalid])
      Api.create_nature(M.actor, Api::NatureInput.new("A" * 25, "Trop long", "receipt", "bnc"))
        .error_keys.should eq(["micro.errors.nature.code.invalid"])
      Api.create_nature(M.actor, Api::NatureInput.new(" loyer_2 ", " Loyers ", "purchase", "other")).value!
        .code.should eq("LOYER_2")
    end

    it "laisse changer le code d'une nature inemployée, pas vers un code pris" do
      M.setup
      nature = Api.create_nature(M.actor, Api::NatureInput.new("TEMP", "Temporaire", "purchase", "other")).value!
      Api.update_nature(M.actor, nature.id, Api::NatureInput.new("GOODS", "Temporaire", "purchase", "other"))
        .error_keys.should eq(["micro.errors.nature.code.taken"])
      renamed = Api.update_nature(M.actor, nature.id, Api::NatureInput.new("DIVERS", "Divers", "purchase", "goods")).value!
      renamed.code.should eq("DIVERS")
      renamed.category.should eq("goods")
      # Même code qu'elle-même : pas un doublon.
      Api.update_nature(M.actor, nature.id, Api::NatureInput.new("DIVERS", "Divers bis", "purchase", "goods")).success?.should be_true
      expect_raises(Partiduo::Api::NotFound) do
        Api.update_nature(M.actor, 999_999_i64, Api::NatureInput.new("X", "X", "purchase", "goods"))
      end
      Api.update_nature(M.actor, nature.id, Api::NatureInput.new("DIVERS", "Divers", "purchase", "goods", enabled: false)).value!
      Api.natures(M.system, "purchase", enabled_only: true).map(&.code).should_not contain("DIVERS")
      Api.natures(M.system, "purchase").map(&.code).should contain("DIVERS")
    end

    it "rattache une nature de recette à un article du socle, et l'en retire" do
      M.setup
      item = card("SALE", "Cours de guitare", code: "GUITARE")
      customer = card("CUSTOMER", "Jeanne Martin")
      Api.set_item_nature(M.actor, customer.id, M.nature("FEE").id).error_keys.should eq(["micro.errors.item.not_item"])
      Api.set_item_nature(M.actor, item.id, M.nature("GOODS").id).error_keys.should eq(["micro.errors.line.nature.unknown"])
      Api.set_item_nature(M.actor, item.id, M.nature("FEE").id).value!
      Api.set_item_nature(M.actor, item.id, M.nature("SERVICE").id).value!
      Api.item_natures(M.system).should eq([Api::ItemNatureView.new(item.id, M.nature("SERVICE").id)])
      Api.set_item_nature(M.actor, item.id, nil).value!
      Api.item_natures(M.system).should be_empty
      # Retirer une nature absente ne coûte rien.
      Api.set_item_nature(M.actor, item.id, nil).success?.should be_true
    end
  end

  describe "intégrité en base (migration micro 0001)" do
    it "garde le registre des achats intangible et hors période close" do
      M.setup
      line = M.purchase("2026-08-10", "40")
      InvoicingSpec.sql_error("UPDATE micro_purchase SET label = 'x' WHERE id = $1", line.id).to_s.should contain("intangible")
      InvoicingSpec.sql_error("DELETE FROM micro_purchase WHERE id = $1", line.id).to_s.should contain("intangible")
      M.close_period("2026-08-10")
      sql = "INSERT INTO micro_purchase (number, date, nature_id, category, amount, method, party_name, label, reference, " \
            "recorded_at) VALUES ('X-1', '2026-08-11', $1, 'goods', 5, 'cash', '', '', '', now())"
      InvoicingSpec.sql_error(sql, M.nature("GOODS").id).to_s.should contain("période close")
    end

    it "n'admet qu'une contre-passation par ligne, négative, et une TVA du même signe" do
      M.setup
      line = M.receipt("2026-09-10", "100")
      Api.reverse_receipt(M.actor, Api::ReverseInput.new(line.id, M.date("2026-09-11"))).value!
      nature = M.nature("SERVICE").id
      insert = "INSERT INTO micro_receipt (number, date, nature_id, category, amount, vat_amount, method, party_name, " \
               "label, reference, origin, source, reversal_of_id, recorded_at) VALUES ($1, '2026-09-12', $2, 'service_bic', " \
               "$3::numeric, $4::numeric, 'cash', '', '', '', 'manual', '', $5, now())"
      InvoicingSpec.sql_error(insert, "X-1", nature, "-100", "0", line.id).to_s.should contain("micro_receipt_reversal")
      InvoicingSpec.sql_error(insert, "X-2", nature, "100", "0", nil).should be_nil
      InvoicingSpec.sql_error(insert, "X-3", nature, "10", "-1", nil).to_s.should contain("micro_receipt_amount_check")
      InvoicingSpec.sql_error(insert, "X-4", nature, "10", "10", nil).to_s.should contain("micro_receipt_amount_check")
      InvoicingSpec.sql_error(insert, "X-5", nature, "0", "0", nil).to_s.should contain("micro_receipt_amount_check")
      InvoicingSpec.sql_error(insert, "R2026-00001", nature, "5", "0", nil).to_s.should contain("duplicate key")
    end

    it "ferme les valeurs : catégorie, origine, mode, sens des natures, périodicité" do
      M.setup
      nature = M.nature("SERVICE").id
      insert = "INSERT INTO micro_receipt (number, date, nature_id, category, amount, vat_amount, method, party_name, " \
               "label, reference, origin, source, recorded_at) VALUES ($1, '2026-09-12', $2, $3, 5, 0, $4, '', '', '', $5, " \
               "'', now())"
      InvoicingSpec.sql_error(insert, "X-1", nature, "goods", "cash", "manual").to_s.should contain("micro_receipt_values_check")
      InvoicingSpec.sql_error(insert, "X-2", nature, "bnc", "bitcoin", "manual").to_s.should contain("micro_receipt_values_check")
      InvoicingSpec.sql_error(insert, "X-3", nature, "bnc", "cash", "import").to_s.should contain("micro_receipt_values_check")
      InvoicingSpec.sql_error(insert, "X-4", 999_999_i64, "bnc", "cash", "manual").to_s.should contain("micro_receipt_nature_fk")
      InvoicingSpec.sql_error("INSERT INTO micro_nature (code, label, kind, category, enabled, created_at, updated_at) " \
                              "VALUES ('X', 'X', 'purchase', 'bnc', true, now(), now())").to_s.should contain("micro_nature_kind_check")
      InvoicingSpec.sql_error("UPDATE micro_settings SET periodicity = 'yearly'").to_s.should contain("micro_settings_periodicity_check")
      InvoicingSpec.sql_error("INSERT INTO micro_counter (register, year, next_number) VALUES ('sale', 2026, 1)")
        .to_s.should contain("micro_counter_checks")
    end

    it "n'inscrit une référence d'origine qu'une fois par nature" do
      M.setup
      nature = M.nature("SERVICE").id
      insert = "INSERT INTO micro_receipt (number, date, nature_id, category, amount, vat_amount, method, party_name, " \
               "label, reference, origin, source, recorded_at) VALUES ($1, '2026-09-12', $2, 'service_bic', 5, 0, 'cash', " \
               "'', '', '', 'invoicing', 'payment:1', now())"
      InvoicingSpec.sql_error(insert, "X-1", nature).should be_nil
      InvoicingSpec.sql_error(insert, "X-2", nature).to_s.should contain("micro_receipt_source")
      # Même référence, autre nature : c'est la ventilation d'un encaissement.
      InvoicingSpec.sql_error(insert, "X-3", M.nature("SALE").id).should be_nil
    end
  end
end
