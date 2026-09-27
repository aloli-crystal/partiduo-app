# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias Api = Partiduo::Api::Followup

private def system : Partiduo::Api::Actor
  Partiduo::Api::Actor.system
end

private def date(text : String) : Time
  Time.parse_utc(text, "%Y-%m-%d")
end

private record Book,
  proposal : Api::ActionTypeView,
  letter : Api::ActionTypeView,
  customer : Partiduo::Api::Cards::CardView,
  contact : Partiduo::Api::Cards::CardView,
  other : Partiduo::Api::Cards::CardView

private def book : Book
  Api.load_default_action_types(system, "fr")
  types = Api.action_types(system)
  customers = ReferentialSpec.category("CUSTOMER", "customer")
  contacts = ReferentialSpec.category("CONTACT", "contact")
  Book.new(
    types.find!(&.code.==("PRP")), types.find!(&.code.==("CO")),
    ReferentialSpec.card(customers.id, "Garage Martin"), ReferentialSpec.card(contacts.id, "Paul Martin"),
    ReferentialSpec.card(customers.id, "Carrosserie Durand"))
end

private def create(type : Api::ActionTypeView, day : String = "2026-09-20", **options) : Api::ActionView
  result = Api.create_action(system, Api::ActionInput.new(action_type_id: type.id, date: date(day)).copy_with(**options))
  raise "action refusée : #{result.error_keys.join(", ")}" if result.failure?
  result.value!
end

describe "Suivi : accès" do
  it "refuse l'appel si le module est inactif, et l'acteur sans permission" do
    with_active_modules("accounting") do
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.action_types(system) }
    end
    with_active_modules("accounting,followup") do
      expect_raises(Partiduo::Api::Forbidden) { Api.actions(actor_with) }
      expect_raises(Partiduo::Api::Forbidden) { Api.create_tag(actor_with(Api::WRITE), Api::TagInput.new("VIP")) }
      Api.actions(actor_with(Api::READ)).should be_empty
    end
  end
end

describe_module "FOLLOWUP", "Suivi : actions et relations" do
  describe "types d'action" do
    it "charge les types de NOALYSS une seule fois, dans la langue voulue" do
      Api.load_default_action_types(system, "nl").size.should eq(13)
      Api.load_default_action_types(system, "fr").should be_empty
      Api.action_types(system).find!(&.code.==("FAC")).label.should eq("Factuur")
    end

    it "contrôle le préfixe et refuse de supprimer un type utilisé" do
      data = book
      duplicate = Api.create_action_type(system, Api::ActionTypeInput.new(" prp ", "Autre proposition"))
      duplicate.error_keys.should eq(["followup.errors.action_type.code_taken"])
      ReferentialSpec.expect_translated(duplicate)
      Api.create_action_type(system, Api::ActionTypeInput.new("A-1", "", 0)).error_keys.should eq([
        "followup.errors.action_type.code_invalid", "followup.errors.action_type.label_required",
        "followup.errors.action_type.next_number_invalid",
      ])
      create(data.proposal)
      Api.delete_action_type(system, data.proposal.id).error_keys.should eq(["followup.errors.action_type.in_use"])
      Api.delete_action_type(system, data.letter.id).success?.should be_true
    end
  end

  describe "actions" do
    it "attribue les références par type, reprend le libellé du type et garde le premier commentaire" do
      data = book
      first = create(data.proposal, card_id: data.customer.id, contact_card_id: data.contact.id, hour: "9:05",
        concerned_card_ids: [data.other.id], comment: "Premier contact")
      first.reference.should eq("PRP-1")
      first.title.should eq("Proposition")
      first.hour.should eq("09:05")
      first.card.try(&.name).should eq("Garage Martin")
      first.contact.try(&.name).should eq("Paul Martin")
      first.concerned.map(&.name).should eq(["Carrosserie Durand"])
      first.comments.map(&.text).should eq(["Premier contact"])
      first.state.should eq("todo")
      create(data.proposal).reference.should eq("PRP-2")
      create(data.letter, title: "Relance").reference.should eq("CO-1")

      # Numéro de départ déplacé sur une référence déjà prise : sautée.
      Api.update_action_type(system, data.proposal.id, Api::ActionTypeInput.new("PRP", "Proposition", 2)).value!
      create(data.proposal).reference.should eq("PRP-3")
      Api.action_type(system, data.proposal.id).next_number.should eq(4)
    end

    it "refuse champ par champ" do
      data = book
      result = Api.create_action(system, Api::ActionInput.new(action_type_id: 999_i64, date: date("2026-09-20"),
        hour: "25:00", priority: 7, state: "done", card_id: 999_999_i64, tag_ids: [888_i64]))
      result.errors.map { |error| {error.field, error.key} }.should eq([
        {"action_type_id", "followup.errors.action.type_unknown"},
        {"hour", "followup.errors.action.hour_invalid"},
        {"priority", "followup.errors.action.priority_invalid"},
        {"state", "followup.errors.action.state_invalid"},
        {"card_id", "followup.errors.action.card_unknown"},
        {"tag_ids[0]", "followup.errors.action.tag_unknown"},
      ])
      ReferentialSpec.expect_translated(result)
      Api.check_action(system, Api::ActionInput.new(action_type_id: data.letter.id, date: date("2026-09-20")))
        .success?.should be_true
      Api.count_actions(system).should eq(0)
    end

    it "modifie, change l'état, commente, lie les actions et rattache des opérations" do
      data = book
      action = create(data.proposal, card_id: data.customer.id)
      other = create(data.letter)
      input = Api::ActionInput.new(action_type_id: data.proposal.id, date: date("2026-09-21"), title: "Devis atelier",
        priority: 1, state: "follow", remind_on: date("2026-10-01"), card_id: data.other.id, comment: "Rappeler lundi")
      updated = Api.update_action(system, action.id, input).value!
      {updated.reference, updated.title, updated.priority, updated.state}.should eq({"PRP-1", "Devis atelier", 1, "follow"})
      updated.card.try(&.id).should eq(data.other.id)
      updated.comments.map(&.text).should eq(["Rappeler lundi"])

      Api.add_comment(system, action.id, "  ").error_keys.should eq(["followup.errors.comment.text_required"])
      Api.add_comment(actor_with(Api::WRITE), action.id, "Devis envoyé").value!.author_id.should eq(1_i64)

      Api.relate(system, other.id, action.id).success?.should be_true
      Api.relate(system, action.id, other.id).success?.should be_true
      Api.relate(system, action.id, action.id).error_keys.should eq(["followup.errors.relation.self"])
      Api.action(system, action.id).related.map(&.reference).should eq(["CO-1"])
      Api.action(system, other.id).related.map(&.reference).should eq(["PRP-1"])

      Api.link(system, action.id, "invoice:12").success?.should be_true
      Api.link(system, action.id, "facture 12").error_keys.should eq(["followup.errors.link.invalid"])
      Api.actions_linked_to(system, "invoice:12").map(&.id).should eq([action.id])

      Api.set_state(system, action.id, "closed").value!.open?.should be_false
      Api.set_state(system, action.id, "fini").error_keys.should eq(["followup.errors.action.state_invalid"])

      Api.unrelate(system, action.id, other.id).success?.should be_true
      Api.unlink(system, action.id, "invoice:12").success?.should be_true
      Api.action(system, action.id).links.should be_empty
      Api.delete_action(system, action.id).success?.should be_true
      expect_raises(Partiduo::Api::NotFound) { Api.action(system, action.id) }
      Api.action(system, other.id).related.should be_empty
    end
  end

  describe "recherche, étiquettes, rappels, export" do
    it "cherche par texte, fiche, état, dates et étiquettes" do
      data = book
      vip = Api.create_tag(system, Api::TagInput.new("VIP", color: 3)).value!
      urgent = Api.create_tag(system, Api::TagInput.new("Urgent")).value!
      Api.create_tag(system, Api::TagInput.new("vip")).error_keys.should eq(["followup.errors.tag.label_taken"])
      Api.create_tag(system, Api::TagInput.new("Rouge", color: 11)).error_keys.should eq(["followup.errors.tag.color_invalid"])

      garage = create(data.proposal, "2026-09-01", title: "Devis garage", card_id: data.customer.id, tag_ids: [vip.id, urgent.id])
      contact = create(data.letter, "2026-09-10", title: "Courrier", contact_card_id: data.customer.id, tag_ids: [vip.id])
      internal = create(data.letter, "2026-09-15", title: "Note interne", comment: "Stock de carrosserie à revoir")
      closed = create(data.letter, "2026-09-16", title: "Classé", state: "closed")

      ids = ->(query : Api::ActionQuery) { Api.actions(system, query).map(&.id) }
      ids.call(Api::ActionQuery.new).should eq([internal.id, contact.id, garage.id])
      ids.call(Api::ActionQuery.new(open_only: false)).should eq([closed.id, internal.id, contact.id, garage.id])
      ids.call(Api::ActionQuery.new(state: "closed")).should eq([closed.id])
      ids.call(Api::ActionQuery.new(search: "carrosserie")).should eq([internal.id])
      ids.call(Api::ActionQuery.new(search: "PRP-1")).should eq([garage.id])
      ids.call(Api::ActionQuery.new(search: "100%")).should be_empty
      ids.call(Api::ActionQuery.new(card_id: data.customer.id)).should eq([contact.id, garage.id])
      ids.call(Api::ActionQuery.new(internal_only: true)).should eq([internal.id, contact.id])
      ids.call(Api::ActionQuery.new(date_from: date("2026-09-05"), date_to: date("2026-09-12"))).should eq([contact.id])
      ids.call(Api::ActionQuery.new(tag_ids: [vip.id, urgent.id])).should eq([contact.id, garage.id])
      ids.call(Api::ActionQuery.new(tag_ids: [vip.id, urgent.id], all_tags: true)).should eq([garage.id])
      ids.call(Api::ActionQuery.new(action_type_id: data.proposal.id)).should eq([garage.id])
      Api.count_actions(system, Api::ActionQuery.new(open_only: false)).should eq(4)
      Api.actions(system, Api::ActionQuery.new(limit: 1, offset: 1)).map(&.id).should eq([contact.id])

      summary = Api.actions(system, Api::ActionQuery.new(search: "garage")).first
      summary.tags.should eq(["Urgent", "VIP"])
      Api.set_tags(system, garage.id, [urgent.id]).value!.tags.map(&.label).should eq(["Urgent"])
      Api.delete_tag(system, urgent.id).success?.should be_true
      Api.action(system, garage.id).tags.should be_empty

      csv = String.new(Api.export_actions(system, Api::ActionQuery.new(search: "garage")).content)
      csv.lines.first.should eq("Référence;Date;Heure;Type;Titre;Destinataire;État;Priorité;Rappel;Étiquettes")
      csv.lines[1].should eq("PRP-1;2026-09-01;;Proposition;Devis garage;#{data.customer.code} Garage Martin;À faire;Normale;;")
    end

    it "liste les rappels du jour et les rappels dépassés des actions ouvertes" do
      data = book
      today = create(data.letter, remind_on: date("2026-09-27"), title: "Aujourd'hui")
      late = create(data.letter, remind_on: date("2026-09-20"), title: "En retard")
      create(data.letter, remind_on: date("2026-09-20"), title: "Clôturée", state: "closed")
      create(data.letter, remind_on: date("2026-10-20"), title: "Plus tard")
      reminders = Api.reminders(system, date("2026-09-27"))
      reminders.today.map(&.id).should eq([today.id])
      reminders.late.map(&.id).should eq([late.id])
      Api.action(system, late.id).late?(date("2026-09-27")).should be_true
    end
  end

  it "empêche la suppression d'une fiche citée par une action" do
    data = book
    create(data.proposal, card_id: data.customer.id)
    Partiduo::Api::Cards.delete_card(system, data.customer.id).error_keys.first.should contain("in_use")
    Partiduo::Api::Cards.delete_card(system, data.other.id).success?.should be_true
  end
end
