# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    # Contrat du module Suivi (lot 6) : types d'action, étiquettes, actions
    # de suivi (création, modification, état, commentaires, fiches
    # concernées, actions liées, opérations rattachées), recherche, rappels
    # et export CSV. Types dans `types.cr` ; référence :
    # `doc/api/followup.adoc`.
    #
    # Toute commande et toute requête lèvent `ModuleDisabled` si le Suivi est
    # inactif. Les documents joints (GED) relèvent de l'extension
    # `partiduo-document`.
    module Followup
      MODULE_CODE    = "FOLLOWUP"
      READ           = "followup.action.read"
      WRITE          = "followup.action.write"
      SETTINGS_WRITE = "followup.settings.write"

      # --- Types d'action ------------------------------------------------------------------

      def self.action_types(actor : Actor) : Array(ActionTypeView)
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        counts = {} of Int64 => Int64
        Marten::DB::Connection.default.open do |db|
          db.query("SELECT action_type_id, count(*) FROM followup_action GROUP BY action_type_id") do |result_set|
            result_set.each { counts[result_set.read(Int64)] = result_set.read(Int64) }
          end
        end
        Partiduo::Followup::ActionType.all.order(:label).to_a.map do |type|
          Partiduo::Followup::Actions.action_type_view(type, counts.fetch(type.pk!.as(Int64), 0_i64))
        end
      end

      def self.action_type(actor : Actor, id : Int64) : ActionTypeView
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        Partiduo::Followup::Actions.action_type_view(find_type(id))
      end

      def self.create_action_type(actor : Actor, input : ActionTypeInput) : Result(ActionTypeView)
        Guard.authorize!(actor, SETTINGS_WRITE, module_code: MODULE_CODE)
        Transaction.run do
          lock("followup_action_type")
          errors = Partiduo::Followup::Rules.action_type_errors(input)
          next Result(ActionTypeView).failure(errors) unless errors.empty?
          type = Partiduo::Followup::ActionType.create!(code: Partiduo::Followup::Rules.normalize_code(input.code),
            label: input.label.strip, next_number: input.next_number || 1)
          Result(ActionTypeView).success(Partiduo::Followup::Actions.action_type_view(type, 0_i64))
        end
      end

      # Changer le préfixe ne renomme pas les références déjà attribuées.
      def self.update_action_type(actor : Actor, id : Int64, input : ActionTypeInput) : Result(ActionTypeView)
        Guard.authorize!(actor, SETTINGS_WRITE, module_code: MODULE_CODE)
        Transaction.run do
          lock("followup_action_type")
          type = Partiduo::Followup::ActionType.filter(id: id).lock.first || raise NotFound.new("followup_action_type", id)
          errors = Partiduo::Followup::Rules.action_type_errors(input, id)
          next Result(ActionTypeView).failure(errors) unless errors.empty?
          type.code = Partiduo::Followup::Rules.normalize_code(input.code)
          type.label = input.label.strip
          input.next_number.try { |number| type.next_number = number }
          type.save!
          Result(ActionTypeView).success(Partiduo::Followup::Actions.action_type_view(type))
        end
      end

      # Refusé si une action est de ce type (`action_document_type_mtable`).
      def self.delete_action_type(actor : Actor, id : Int64) : Result(Nil)
        Guard.authorize!(actor, SETTINGS_WRITE, module_code: MODULE_CODE)
        Transaction.run do
          type = find_type(id)
          if Partiduo::Followup::Action.filter(action_type_id: id).exists?
            next Result(Nil).failure(Partiduo::Followup::Rules.error(FieldError::BASE, "action_type", "in_use"))
          end
          type.delete
          Result(Nil).success(nil)
        end
      end

      # Types d'action d'origine (`document_type`), libellés dans la langue
      # `locale` ; déjà présents (même préfixe) : conservés. Renvoie les
      # préfixes créés.
      def self.load_default_action_types(actor : Actor, locale : String = "fr") : Array(String)
        Guard.authorize!(actor, SETTINGS_WRITE, module_code: MODULE_CODE)
        created = [] of String
        Transaction.run do
          lock("followup_action_type")
          I18n.with_locale(Partiduo::LOCALES.includes?(locale) ? locale : "fr") do
            Partiduo::Followup::DEFAULT_TYPES.each do |code|
              next if Partiduo::Followup::ActionType.filter(code: code).exists?
              Partiduo::Followup::ActionType.create!(code: code, label: I18n.t("followup.default_types.#{code.downcase}"))
              created << code
            end
          end
          Result(Nil).success(nil)
        end
        created
      end

      # --- Étiquettes ---------------------------------------------------------------------

      def self.tags(actor : Actor, active_only : Bool = false) : Array(TagView)
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        tags = Partiduo::Followup::Tag.all
        tags = tags.filter(active: true) if active_only
        tags.order(:label).to_a.map { |tag| Partiduo::Followup::Actions.tag_view(tag) }
      end

      def self.create_tag(actor : Actor, input : TagInput) : Result(TagView)
        Guard.authorize!(actor, SETTINGS_WRITE, module_code: MODULE_CODE)
        Transaction.run do
          lock("followup_tag")
          errors = Partiduo::Followup::Rules.tag_errors(input)
          next Result(TagView).failure(errors) unless errors.empty?
          tag = Partiduo::Followup::Tag.create!(label: input.label.strip, description: input.description.strip,
            active: input.active, color: input.color)
          Result(TagView).success(Partiduo::Followup::Actions.tag_view(tag))
        end
      end

      def self.update_tag(actor : Actor, id : Int64, input : TagInput) : Result(TagView)
        Guard.authorize!(actor, SETTINGS_WRITE, module_code: MODULE_CODE)
        Transaction.run do
          lock("followup_tag")
          tag = find_tag(id)
          errors = Partiduo::Followup::Rules.tag_errors(input, id)
          next Result(TagView).failure(errors) unless errors.empty?
          tag.label = input.label.strip
          tag.description = input.description.strip
          tag.active = input.active
          tag.color = input.color
          tag.save!
          Result(TagView).success(Partiduo::Followup::Actions.tag_view(tag))
        end
      end

      # Retire l'étiquette de toutes les actions.
      def self.delete_tag(actor : Actor, id : Int64) : Result(Nil)
        Guard.authorize!(actor, SETTINGS_WRITE, module_code: MODULE_CODE)
        Transaction.run do
          find_tag(id).delete
          Result(Nil).success(nil)
        end
      end

      # --- Actions ------------------------------------------------------------------------

      def self.actions(actor : Actor, query : ActionQuery = ActionQuery.new) : Array(ActionSummaryView)
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        Partiduo::Followup::Actions.search(query)
      end

      def self.count_actions(actor : Actor, query : ActionQuery = ActionQuery.new) : Int64
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        Partiduo::Followup::Actions.count(query)
      end

      def self.action(actor : Actor, id : Int64) : ActionView
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        Partiduo::Followup::Actions.view(find_action(id))
      end

      def self.action_by_reference(actor : Actor, reference : String) : ActionView?
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        Partiduo::Followup::Action.filter(reference: reference.strip).first.try { |action| Partiduo::Followup::Actions.view(action) }
      end

      def self.check_action(actor : Actor, input : ActionInput) : Result(Nil)
        Guard.authorize!(actor, WRITE, module_code: MODULE_CODE)
        errors = Partiduo::Followup::Rules.action_errors(input)
        errors.empty? ? Result(Nil).success(nil) : Result(Nil).failure(errors)
      end

      # Crée l'action ; sa référence (`<préfixe>-<n>`) est attribuée par le
      # type ; titre vide = libellé du type ; `comment` non vide devient le
      # premier commentaire.
      def self.create_action(actor : Actor, input : ActionInput) : Result(ActionView)
        Guard.authorize!(actor, WRITE, module_code: MODULE_CODE)
        Transaction.run do
          errors = Partiduo::Followup::Rules.action_errors(input)
          errors.concat(Partiduo::Followup::Rules.comment_errors(input.comment).map(&.copy_with(field: "comment"))) unless input.comment.strip.empty?
          next Result(ActionView).failure(errors) unless errors.empty?
          action = Partiduo::Followup::Actions.assign(Partiduo::Followup::Action.new, input)
          action.reference = Partiduo::Followup::Actions.next_reference(input.action_type_id)
          action.owner_id = actor.user_id
          action.save!
          Partiduo::Followup::Actions.replace_relations!(action, input)
          unless input.comment.strip.empty?
            Partiduo::Followup::Comment.create!(action: action, text: input.comment.strip, author_id: actor.user_id)
          end
          Result(ActionView).success(Partiduo::Followup::Actions.view(action))
        end
      end

      # Modifie l'action entière (référence et auteur inchangés ; changer le
      # type ne renumérote pas) ; `comment` non vide est ajouté.
      def self.update_action(actor : Actor, id : Int64, input : ActionInput) : Result(ActionView)
        Guard.authorize!(actor, WRITE, module_code: MODULE_CODE)
        Transaction.run do
          action = Partiduo::Followup::Action.filter(id: id).lock.first || raise NotFound.new("followup_action", id)
          errors = Partiduo::Followup::Rules.action_errors(input)
          errors.concat(Partiduo::Followup::Rules.comment_errors(input.comment).map(&.copy_with(field: "comment"))) unless input.comment.strip.empty?
          next Result(ActionView).failure(errors) unless errors.empty?
          Partiduo::Followup::Actions.assign(action, input).save!
          Partiduo::Followup::Actions.replace_relations!(action, input)
          unless input.comment.strip.empty?
            Partiduo::Followup::Comment.create!(action: action, text: input.comment.strip, author_id: actor.user_id)
          end
          Result(ActionView).success(Partiduo::Followup::Actions.view(action))
        end
      end

      # Change l'état (`action_set_state`).
      def self.set_state(actor : Actor, id : Int64, state : String) : Result(ActionView)
        Guard.authorize!(actor, WRITE, module_code: MODULE_CODE)
        Transaction.run do
          action = Partiduo::Followup::Action.filter(id: id).lock.first || raise NotFound.new("followup_action", id)
          unless STATES.includes?(state)
            next Result(ActionView).failure(Partiduo::Followup::Rules.error("state", "action", "state_invalid"))
          end
          action.state = state
          action.save!
          Result(ActionView).success(Partiduo::Followup::Actions.view(action))
        end
      end

      # Supprime l'action, ses commentaires et ses liens (`Follow_Up::remove`).
      def self.delete_action(actor : Actor, id : Int64) : Result(Nil)
        Guard.authorize!(actor, WRITE, module_code: MODULE_CODE)
        Transaction.run do
          find_action(id).delete
          Result(Nil).success(nil)
        end
      end

      def self.add_comment(actor : Actor, id : Int64, text : String) : Result(CommentView)
        Guard.authorize!(actor, WRITE, module_code: MODULE_CODE)
        Transaction.run do
          action = find_action(id)
          errors = Partiduo::Followup::Rules.comment_errors(text)
          next Result(CommentView).failure(errors) unless errors.empty?
          comment = Partiduo::Followup::Comment.create!(action: action, text: text.strip, author_id: actor.user_id)
          action.save!
          Result(CommentView).success(Partiduo::Followup::Actions.comment_view(comment))
        end
      end

      # Lie deux actions (`action_gestion_related`) ; sans effet si elles le
      # sont déjà.
      def self.relate(actor : Actor, id : Int64, other_id : Int64) : Result(Nil)
        Guard.authorize!(actor, WRITE, module_code: MODULE_CODE)
        Transaction.run do
          find_action(id)
          find_action(other_id)
          if id == other_id
            next Result(Nil).failure(Partiduo::Followup::Rules.error("other_id", "relation", "self"))
          end
          least, greatest = Partiduo::Followup::Actions.pair(id, other_id)
          unless Partiduo::Followup::Relation.filter(least_id: least, greatest_id: greatest).exists?
            Partiduo::Followup::Relation.create!(least_id: least, greatest_id: greatest)
          end
          Result(Nil).success(nil)
        end
      end

      def self.unrelate(actor : Actor, id : Int64, other_id : Int64) : Result(Nil)
        Guard.authorize!(actor, WRITE, module_code: MODULE_CODE)
        Transaction.run do
          least, greatest = Partiduo::Followup::Actions.pair(id, other_id)
          Partiduo::Followup::Relation.filter(least_id: least, greatest_id: greatest).delete
          Result(Nil).success(nil)
        end
      end

      # Rattache une opération d'un module (`action_gestion_operation`) par
      # sa référence (`entry:<id>`, `invoice:<id>`…) ; le Suivi ne la
      # vérifie pas (D-FUP-005).
      def self.link(actor : Actor, id : Int64, reference : String) : Result(Nil)
        Guard.authorize!(actor, WRITE, module_code: MODULE_CODE)
        Transaction.run do
          action = find_action(id)
          errors = Partiduo::Followup::Rules.link_errors(reference)
          next Result(Nil).failure(errors) unless errors.empty?
          unless Partiduo::Followup::Link.filter(action_id: id, reference: reference.strip).exists?
            Partiduo::Followup::Link.create!(action: action, reference: reference.strip)
          end
          Result(Nil).success(nil)
        end
      end

      def self.unlink(actor : Actor, id : Int64, reference : String) : Result(Nil)
        Guard.authorize!(actor, WRITE, module_code: MODULE_CODE)
        Transaction.run do
          Partiduo::Followup::Link.filter(action_id: id, reference: reference.strip).delete
          Result(Nil).success(nil)
        end
      end

      # Actions qui citent une opération (`Follow_Up::get_all_operation`).
      def self.actions_linked_to(actor : Actor, reference : String) : Array(ActionSummaryView)
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        ids = Partiduo::Followup::Link.filter(reference: reference.strip).to_a.map(&.action_id!.as(Int64)).uniq!
        Partiduo::Followup::Actions.summaries(ids)
      end

      def self.set_tags(actor : Actor, id : Int64, tag_ids : Array(Int64)) : Result(ActionView)
        Guard.authorize!(actor, WRITE, module_code: MODULE_CODE)
        Transaction.run do
          action = find_action(id)
          known = Partiduo::Followup::Tag.filter(id__in: tag_ids.uniq).to_a.map(&.pk!.as(Int64)).to_set
          errors = tag_ids.each_with_index.compact_map do |(tag_id, index)|
            next if known.includes?(tag_id)
            Partiduo::Followup::Rules.error("tag_ids[#{index}]", "action", "tag_unknown", {"id" => tag_id.to_s})
          end.to_a
          next Result(ActionView).failure(errors) unless errors.empty?
          Partiduo::Followup::Actions.set_tags!(action, tag_ids)
          Result(ActionView).success(Partiduo::Followup::Actions.view(action))
        end
      end

      # --- Rappels et export ---------------------------------------------------------------

      def self.reminders(actor : Actor, today : Time = Partiduo::Config.today) : RemindersView
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        Partiduo::Followup::Actions.reminders(today)
      end

      # Export CSV d'une recherche (`export_follow_up_csv.php`), sans plafond :
      # `limit` et `offset` de la requête sont ignorés.
      def self.export_actions(actor : Actor, query : ActionQuery = ActionQuery.new) : FileView
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        Partiduo::Followup::Exports.actions(Partiduo::Followup::Actions.search_all(query))
      end

      # --- Interne ---------------------------------------------------------------------------

      private def self.lock(name : String) : Nil
        Marten::DB::Connection.default.open(&.exec("SELECT pg_advisory_xact_lock(hashtext($1))", name))
      end

      private def self.find_type(id : Int64) : Partiduo::Followup::ActionType
        Partiduo::Followup::ActionType.filter(id: id).first || raise NotFound.new("followup_action_type", id)
      end

      private def self.find_tag(id : Int64) : Partiduo::Followup::Tag
        Partiduo::Followup::Tag.filter(id: id).first || raise NotFound.new("followup_tag", id)
      end

      private def self.find_action(id : Int64) : Partiduo::Followup::Action
        Partiduo::Followup::Action.filter(id: id).first || raise NotFound.new("followup_action", id)
      end
    end
  end
end
