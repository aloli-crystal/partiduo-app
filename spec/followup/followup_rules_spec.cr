# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Lot 6 — Suivi : cas limites (`Follow_Up::verify`, `Follow_Up::save`,
# `Follow_Up::create_query`, `cfg_action`, `Tag`), droits par commande,
# module inactif et contraintes d'intégrité en base.
private alias Api = Partiduo::Api::Followup

private def system : Partiduo::Api::Actor
  Partiduo::Api::Actor.system
end

private def date(text : String) : Time
  Time.parse_utc(text, "%Y-%m-%d")
end

private def letter : Api::ActionTypeView
  Api.create_action_type(system, Api::ActionTypeInput.new("CO", "Courrier")).value!
end

private def customer(name : String = "Garage Martin") : Partiduo::Api::Cards::CardView
  category = Partiduo::Api::Cards.category_by_code(system, "CUSTOMER") || ReferentialSpec.category("CUSTOMER", "customer")
  ReferentialSpec.card(category.id, name)
end

private def create(type : Api::ActionTypeView, day : String = "2026-09-20", **options) : Api::ActionView
  result = Api.create_action(system, Api::ActionInput.new(action_type_id: type.id, date: date(day)).copy_with(**options))
  raise "action refusée : #{result.error_keys.join(", ")}" if result.failure?
  result.value!
end

private def refused?(& : -> _) : Symbol
  yield
  :allowed
rescue Partiduo::Api::ModuleDisabled
  :disabled
rescue Partiduo::Api::Forbidden
  :forbidden
rescue Partiduo::Api::NotFound
  :not_found
end

private def each_call(actor : Partiduo::Api::Actor, & : String, String, Proc(Nil) ->) : Nil
  input = Api::ActionInput.new(action_type_id: 1_i64, date: date("2026-09-20"))
  {
    {"action_types", Api::READ, -> { Api.action_types(actor); nil }},
    {"action_type", Api::READ, -> { Api.action_type(actor, 1_i64); nil }},
    {"tags", Api::READ, -> { Api.tags(actor); nil }},
    {"actions", Api::READ, -> { Api.actions(actor); nil }},
    {"count_actions", Api::READ, -> { Api.count_actions(actor); nil }},
    {"action", Api::READ, -> { Api.action(actor, 1_i64); nil }},
    {"action_by_reference", Api::READ, -> { Api.action_by_reference(actor, "CO-1"); nil }},
    {"actions_linked_to", Api::READ, -> { Api.actions_linked_to(actor, "entry:1"); nil }},
    {"reminders", Api::READ, -> { Api.reminders(actor); nil }},
    {"export_actions", Api::READ, -> { Api.export_actions(actor); nil }},
    {"check_action", Api::WRITE, -> { Api.check_action(actor, input); nil }},
    {"create_action", Api::WRITE, -> { Api.create_action(actor, input); nil }},
    {"update_action", Api::WRITE, -> { Api.update_action(actor, 1_i64, input); nil }},
    {"set_state", Api::WRITE, -> { Api.set_state(actor, 1_i64, "closed"); nil }},
    {"delete_action", Api::WRITE, -> { Api.delete_action(actor, 1_i64); nil }},
    {"add_comment", Api::WRITE, -> { Api.add_comment(actor, 1_i64, "x"); nil }},
    {"relate", Api::WRITE, -> { Api.relate(actor, 1_i64, 2_i64); nil }},
    {"unrelate", Api::WRITE, -> { Api.unrelate(actor, 1_i64, 2_i64); nil }},
    {"link", Api::WRITE, -> { Api.link(actor, 1_i64, "entry:1"); nil }},
    {"unlink", Api::WRITE, -> { Api.unlink(actor, 1_i64, "entry:1"); nil }},
    {"set_tags", Api::WRITE, -> { Api.set_tags(actor, 1_i64, [] of Int64); nil }},
    {"create_action_type", Api::SETTINGS_WRITE, -> { Api.create_action_type(actor, Api::ActionTypeInput.new("X", "X")); nil }},
    {"update_action_type", Api::SETTINGS_WRITE, -> { Api.update_action_type(actor, 1_i64, Api::ActionTypeInput.new("X", "X")); nil }},
    {"delete_action_type", Api::SETTINGS_WRITE, -> { Api.delete_action_type(actor, 1_i64); nil }},
    {"load_default_action_types", Api::SETTINGS_WRITE, -> { Api.load_default_action_types(actor); nil }},
    {"create_tag", Api::SETTINGS_WRITE, -> { Api.create_tag(actor, Api::TagInput.new("X")); nil }},
    {"update_tag", Api::SETTINGS_WRITE, -> { Api.update_tag(actor, 1_i64, Api::TagInput.new("X")); nil }},
    {"delete_tag", Api::SETTINGS_WRITE, -> { Api.delete_tag(actor, 1_i64); nil }},
  }.each { |(name, permission, call)| yield name, permission, call }
end

describe "Suivi : module inactif et droits, commande par commande" do
  it "lève ModuleDisabled sur chaque appel quand le Suivi est inactif" do
    with_active_modules("accounting,invoicing,stock") do
      each_call(system) do |name, _, call|
        {name, refused? { call.call }}.should eq({name, :disabled})
      end
    end
  end

  it "s'active seul, sans autre module" do
    Partiduo::Modules.activation_errors(Set{"FOLLOWUP"}).should be_empty
  end

  it "exige la permission propre à chaque appel, avant toute recherche" do
    with_active_modules("invoicing,followup") do
      each_call(actor_with) do |name, _, call|
        {name, refused? { call.call }}.should eq({name, :forbidden})
      end
      [Api::READ, Api::WRITE, Api::SETTINGS_WRITE].each do |held|
        each_call(actor_with(held)) do |name, permission, call|
          next if permission == held
          {name, held, refused? { call.call }}.should eq({name, held, :forbidden})
        end
      end
    end
  end

  it "donne les permissions du Suivi au profil ACCOUNTANT par défaut" do
    with_active_modules("invoicing,followup") do
      profile = Partiduo::Api::Auth.ensure_default_profiles(system).find!(&.code.==("ACCOUNTANT"))
      profile.permissions.select(&.starts_with?("followup.")).sort!
        .should eq(["followup.action.read", "followup.action.write", "followup.settings.write"])
    end
  end
end

describe_module "FOLLOWUP", "Suivi : cas limites" do
  describe "types d'action" do
    it "charge les 13 types de NOALYSS, libellés en anglais au besoin, et retombe sur le français" do
      Api.load_default_action_types(system, "en").should eq(%w[DI BCL BFO FAC RAP CO PRP EL DS NFR RFO RCL RMG])
      Api.action_types(system).map(&.next_number).uniq!.should eq([1])
      Api.action_types(system).find!(&.code.==("FAC")).label.should eq("Invoice")
      Api.delete_action_type(system, Api.action_types(system).find!(&.code.==("FAC")).id).success?.should be_true
      Api.load_default_action_types(system, "xx").should eq(["FAC"])
      Api.action_types(system).find!(&.code.==("FAC")).label.should eq("Facture")
    end

    it "contrôle longueurs et numéro, met le préfixe en majuscules" do
      Api.create_action_type(system, Api::ActionTypeInput.new("ABCDEFGHIJK", "x" * 81)).error_keys.should eq([
        "followup.errors.action_type.code_too_long", "followup.errors.action_type.label_too_long",
      ])
      Api.create_action_type(system, Api::ActionTypeInput.new(" ", " ")).error_keys.should eq([
        "followup.errors.action_type.code_required", "followup.errors.action_type.label_required",
      ])
      type = Api.create_action_type(system, Api::ActionTypeInput.new(" dev1 ", " Devis ", 40)).value!
      {type.code, type.label, type.next_number, type.actions_count}.should eq({"DEV1", "Devis", 40, 0})
      expect_raises(Partiduo::Api::NotFound) { Api.action_type(system, 999_999_i64) }
      expect_raises(Partiduo::Api::NotFound) { Api.delete_action_type(system, 999_999_i64) }
      expect_raises(Partiduo::Api::NotFound) do
        Api.update_action_type(system, 999_999_i64, Api::ActionTypeInput.new("X", "X"))
      end
    end

    it "garde les références attribuées quand le préfixe change ; la série continue sous le nouveau" do
      type = letter
      first = create(type)
      Api.update_action_type(system, type.id, Api::ActionTypeInput.new("LET", "Lettre")).value!
      Api.action(system, first.id).reference.should eq("CO-1")
      create(type).reference.should eq("LET-2")
      Api.action_type(system, type.id).actions_count.should eq(2)
      # Garder le préfixe : pas de conflit avec lui-même.
      Api.update_action_type(system, type.id, Api::ActionTypeInput.new("let", "Lettre")).success?.should be_true
    end
  end

  describe "saisie des actions" do
    it "contrôle heure, titre, priorité, contact et fiches concernées" do
      type = letter
      {"7:30" => true, "23:59" => true, "24:00" => false, "07:3" => false, "7h30" => false, "12:60" => false}.each do |hour, valid|
        input = Api::ActionInput.new(action_type_id: type.id, date: date("2026-09-20"), hour: hour)
        {hour, Api.check_action(system, input).success?}.should eq({hour, valid})
      end
      result = Api.check_action(system, Api::ActionInput.new(action_type_id: type.id, date: date("2026-09-20"),
        title: "t" * 256, priority: 0, contact_card_id: 999_998_i64, concerned_card_ids: [999_997_i64]))
      result.errors.map { |error| {error.field, error.key} }.should eq([
        {"title", "followup.errors.action.title_too_long"},
        {"priority", "followup.errors.action.priority_invalid"},
        {"contact_card_id", "followup.errors.action.card_unknown"},
        {"concerned_card_ids[0]", "followup.errors.action.card_unknown"},
      ])
      ReferentialSpec.expect_translated(result)
    end

    it "refuse un premier commentaire trop long sans rien créer" do
      type = letter
      result = Api.create_action(system, Api::ActionInput.new(action_type_id: type.id, date: date("2026-09-20"),
        comment: "c" * 10_001))
      result.errors.map { |error| {error.field, error.key} }.should eq([{"comment", "followup.errors.comment.text_too_long"}])
      Api.count_actions(system, Api::ActionQuery.new(open_only: false)).should eq(0)
      # Numéro non consommé.
      create(type).reference.should eq("CO-1")
    end

    it "dédoublonne les fiches concernées et les étiquettes, garde l'auteur et la référence à la modification" do
      type = letter
      garage = customer
      vip = Api.create_tag(system, Api::TagInput.new("VIP")).value!
      _, writer = AccountingSpec.user_actor("suivi@example.test", Api::WRITE, Api::READ)
      action = Api.create_action(writer, Api::ActionInput.new(action_type_id: type.id, date: date("2026-09-20"),
        concerned_card_ids: [garage.id, garage.id], tag_ids: [vip.id, vip.id])).value!
      action.concerned.map(&.id).should eq([garage.id])
      action.tags.map(&.label).should eq(["VIP"])
      action.owner_id.should eq(writer.user_id)
      action.internal?.should be_true

      other = Api.create_action_type(system, Api::ActionTypeInput.new("PRP", "Proposition")).value!
      updated = Api.update_action(system, action.id, Api::ActionInput.new(action_type_id: other.id,
        date: date("2026-09-21"))).value!
      {updated.reference, updated.action_type_code, updated.title, updated.owner_id}
        .should eq({"CO-1", "PRP", "Proposition", writer.user_id})
      updated.concerned.should be_empty
      updated.tags.should be_empty
      expect_raises(Partiduo::Api::NotFound) do
        Api.update_action(system, 999_999_i64, Api::ActionInput.new(action_type_id: other.id, date: date("2026-09-21")))
      end
    end

    it "trouve une action par sa référence exacte" do
      type = letter
      action = create(type)
      Api.action_by_reference(system, " CO-1 ").try(&.id).should eq(action.id)
      Api.action_by_reference(system, "co-1").should be_nil
    end
  end

  describe "suppression, liens et opérations" do
    it "efface l'action avec ses commentaires, liens, étiquettes et fiches, sans toucher aux autres" do
      type = letter
      garage = customer
      vip = Api.create_tag(system, Api::TagInput.new("VIP")).value!
      action = create(type, concerned_card_ids: [garage.id], tag_ids: [vip.id], comment: "Premier")
      other = create(type)
      Api.relate(system, action.id, other.id).value!
      Api.link(system, action.id, "entry:42").value!
      Api.delete_action(system, action.id).success?.should be_true
      %w[followup_comment followup_relation followup_link followup_action_tag followup_action_card].each do |table|
        {table, EntrySpec.scalar("SELECT count(*) FROM #{table}")}.should eq({table, 0})
      end
      Api.action(system, other.id).related.should be_empty
      Api.tags(system).map(&.label).should eq(["VIP"])
      Api.actions_linked_to(system, "entry:42").should be_empty
      Partiduo::Api::Cards.delete_card(system, garage.id).success?.should be_true
    end

    it "contrôle la référence d'une opération et ne la rattache qu'une fois" do
      type = letter
      action = create(type)
      Api.link(system, action.id, " entry:42 ").success?.should be_true
      Api.link(system, action.id, "entry:42").success?.should be_true
      Api.action(system, action.id).links.should eq(["entry:42"])
      ["Entry:42", "entry:", "entry:4x", "#{"a" * 35}:12345", "delivery_note:7"].each do |reference|
        {reference, Api.link(system, action.id, reference).success?}.should eq({reference, reference == "delivery_note:7"})
      end
      expect_raises(Partiduo::Api::NotFound) { Api.link(system, 999_999_i64, "entry:1") }
      expect_raises(Partiduo::Api::NotFound) { Api.relate(system, action.id, 999_999_i64) }
    end

    it "refuse une étiquette inconnue à l'étiquetage" do
      type = letter
      action = create(type)
      Api.set_tags(system, action.id, [999_i64]).errors.map { |error| {error.field, error.key} }
        .should eq([{"tag_ids[0]", "followup.errors.action.tag_unknown"}])
    end
  end

  describe "étiquettes" do
    it "contrôle, modifie et filtre les étiquettes actives" do
      Api.create_tag(system, Api::TagInput.new(" ", color: 0)).error_keys
        .should eq(["followup.errors.tag.label_required", "followup.errors.tag.color_invalid"])
      Api.create_tag(system, Api::TagInput.new("x" * 61)).error_keys.should eq(["followup.errors.tag.label_too_long"])
      vip = Api.create_tag(system, Api::TagInput.new("VIP")).value!
      Api.create_tag(system, Api::TagInput.new("Archivé", active: false, color: 10)).value!
      Api.tags(system, active_only: true).map(&.label).should eq(["VIP"])
      Api.update_tag(system, vip.id, Api::TagInput.new("vip", "Clients choyés", color: 2)).value!.label.should eq("vip")
      Api.update_tag(system, vip.id, Api::TagInput.new("archivé")).error_keys.should eq(["followup.errors.tag.label_taken"])
      expect_raises(Partiduo::Api::NotFound) { Api.delete_tag(system, 999_999_i64) }
    end
  end

  describe "recherche, rappels et export" do
    it "cherche par rappel au plus tard, et traite les jokers comme du texte" do
      type = letter
      soon = create(type, title: "Relance 50%", remind_on: date("2026-09-25"))
      create(type, title: "Relance 5_0", remind_on: date("2026-10-25"))
      create(type, title: "Sans rappel")
      Api.actions(system, Api::ActionQuery.new(remind_to: date("2026-09-30"))).map(&.id).should eq([soon.id])
      Api.actions(system, Api::ActionQuery.new(search: "50%")).map(&.id).should eq([soon.id])
      Api.actions(system, Api::ActionQuery.new(search: "5_")).map(&.title).should eq(["Relance 5_0"])
      Api.actions(system, Api::ActionQuery.new(search: "   ")).size.should eq(3)
      Api.actions(system, Api::ActionQuery.new(limit: 0)).should be_empty
    end

    it "écarte des rappels les actions terminées et range ceux du jour par heure" do
      type = letter
      late = create(type, hour: "16:00", remind_on: date("2026-09-27"))
      early = create(type, hour: "08:30", remind_on: date("2026-09-27"))
      abandoned = create(type, remind_on: date("2026-09-01"), state: "abandoned")
      follow = create(type, remind_on: date("2026-09-01"), state: "follow")
      reminders = Api.reminders(system, date("2026-09-27"))
      reminders.today.map(&.id).should eq([early.id, late.id])
      reminders.late.map(&.id).should eq([follow.id])
      Api.action(system, abandoned.id).late?(date("2026-09-27")).should be_false
      Api.action(system, follow.id).late?(date("2026-09-27")).should be_true
      Api.action(system, early.id).late?(date("2026-09-27")).should be_false
    end

    it "protège l'export contre les formules et l'écrit dans la langue courante" do
      type = letter
      create(type, title: "=SUM(A1)", priority: 1, state: "follow", remind_on: date("2026-10-01"))
      csv = String.new(Api.export_actions(system).content)
      csv.lines[1].should eq("CO-1;2026-09-20;;Courrier;'=SUM(A1);;À suivre;Haute;2026-10-01;")
      I18n.with_locale("en") do
        String.new(Api.export_actions(system).content).lines.first.should start_with("Reference;Date;")
      end
    end

    it "exporte toute la recherche, sans tenir compte de limit ni d'offset" do
      type = letter
      create(type, title: "Premier")
      create(type, title: "Second")
      csv = String.new(Api.export_actions(system, Api::ActionQuery.new(limit: 1, offset: 5)).content)
      csv.lines.size.should eq(3)
    end
  end

  describe "intégrité en base" do
    it "refuse état, priorité, couleur, numéro et paire d'actions hors des règles" do
      type = letter
      first = create(type)
      second = create(type)
      tag = Api.create_tag(system, Api::TagInput.new("VIP")).value!
      {
        "UPDATE followup_action SET state = 'done' WHERE id = $1"           => /followup_action_state_check/,
        "UPDATE followup_action SET priority = 4 WHERE id = $1"             => /followup_action_priority_check/,
        "UPDATE followup_action SET card_id = 987654 WHERE id = $1"         => /followup_action_card_fk/,
        "UPDATE followup_action SET contact_card_id = 987654 WHERE id = $1" => /followup_action_contact_fk/,
      }.each do |sql, error|
        expect_raises(Exception, error) { EntrySpec.sql_transaction(&.exec(sql, first.id)) }
      end
      expect_raises(Exception, /followup_tag_color_check/) do
        EntrySpec.sql_transaction(&.exec("UPDATE followup_tag SET color = 11 WHERE id = $1", tag.id))
      end
      expect_raises(Exception, /followup_action_type_number_check/) do
        EntrySpec.sql_transaction(&.exec("UPDATE followup_action_type SET next_number = 0 WHERE id = $1", type.id))
      end
      expect_raises(Exception, /followup_relation_order_check/) do
        EntrySpec.sql_transaction(&.exec("INSERT INTO followup_relation (least_id, greatest_id) VALUES ($1, $2)",
          second.id, first.id))
      end
      expect_raises(Exception, /followup_action_card_card_fk/) do
        EntrySpec.sql_transaction(&.exec("INSERT INTO followup_action_card (action_id, card_id) VALUES ($1, 987654)", first.id))
      end
      expect_raises(Exception, /unique|duplicate/i) do
        EntrySpec.sql_transaction(&.exec("UPDATE followup_action SET reference = 'CO-1' WHERE id = $1", second.id))
      end
      expect_raises(Exception, /foreign key|violates/i) do
        EntrySpec.sql_transaction(&.exec("DELETE FROM followup_action_type WHERE id = $1", type.id))
      end
    end

    it "protège les fiches citées comme contact ou fiche concernée" do
      type = letter
      contact = customer("Paul Martin")
      concerned = customer("Carrosserie Durand")
      create(type, contact_card_id: contact.id, concerned_card_ids: [concerned.id])
      Partiduo::Api::Cards.delete_card(system, contact.id).error_keys.should eq(["cards.errors.card.base.in_use"])
      Partiduo::Api::Cards.delete_card(system, concerned.id).error_keys.should eq(["cards.errors.card.base.in_use"])
    end
  end
end
