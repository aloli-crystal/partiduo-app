# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Followup
    # Actions de suivi : références, enregistrement, vues, recherche
    # (`Follow_Up::create_query`), rappels, actions liées. Service interne.
    module Actions
      alias Api = Partiduo::Api::Followup

      # --- Références -------------------------------------------------------------------

      # Référence suivante du type (`<préfixe>-<n>`), sous verrou de la
      # ligne du type ; un numéro déjà pris (numéro de départ modifié) est
      # sauté, comme la boucle de `Follow_Up::save`.
      def self.next_reference(type_id : Int64) : String
        type = ActionType.filter(id: type_id).lock.first || raise Partiduo::Api::NotFound.new("followup_action_type", type_id)
        number = type.next_number!.to_i32
        loop do
          reference = "#{type.code}-#{number}"
          number += 1
          next if Action.filter(reference: reference).exists?
          type.next_number = number
          type.save!
          return reference
        end
      end

      # --- Enregistrement --------------------------------------------------------------

      def self.assign(action : Action, input : Api::ActionInput) : Action
        title = input.title.strip
        title = ActionType.filter(id: input.action_type_id).first.try(&.label.to_s) || "" if title.empty?
        action.action_type_id = input.action_type_id
        action.title = title
        action.date = day(input.date)
        action.hour = Rules.normalized_hour(input.hour)
        action.priority = input.priority
        action.state = input.state
        action.remind_on = input.remind_on.try { |date| day(date) }
        action.card_id = input.card_id
        action.contact_card_id = input.contact_card_id
        action.visible_profile_id = input.visible_profile_id
        action
      end

      # Fiches concernées et étiquettes : remplacées par celles de la saisie.
      def self.replace_relations!(action : Action, input : Api::ActionInput) : Nil
        ActionCard.filter(action_id: action.pk).delete
        input.concerned_card_ids.uniq.each { |card_id| ActionCard.create!(action: action, card_id: card_id) }
        set_tags!(action, input.tag_ids)
      end

      def self.set_tags!(action : Action, tag_ids : Array(Int64)) : Nil
        ActionTag.filter(action_id: action.pk).delete
        tag_ids.uniq.each { |tag_id| ActionTag.create!(action: action, tag_id: tag_id) }
      end

      def self.day(date : Time) : Time
        Time.utc(date.year, date.month, date.day)
      end

      # --- Vues ---------------------------------------------------------------------

      def self.tag_view(tag : Tag) : Api::TagView
        Api::TagView.new(tag.pk!.as(Int64), tag.label!, tag.description.to_s, tag.active!, tag.color!.to_i32)
      end

      def self.action_type_view(type : ActionType, count : Int64? = nil) : Api::ActionTypeView
        id = type.pk!.as(Int64)
        Api::ActionTypeView.new(id, type.code!, type.label!, type.next_number!.to_i32,
          count || Action.filter(action_type_id: id).count.to_i64)
      end

      def self.view(action : Action) : Api::ActionView
        id = action.pk!.as(Int64)
        type = action.action_type!
        concerned_ids = ActionCard.filter(action_id: id).order(:id).to_a.map(&.card_id!.as(Int64))
        cards = Cards.by_id(([action.card_id, action.contact_card_id].compact.map(&.to_i64) + concerned_ids))
        tags = Tag.filter(id__in: ActionTag.filter(action_id: id).to_a.map(&.tag_id!.as(Int64))).order(:label).to_a
        Api::ActionView.new(
          id: id, action_type_id: type.pk!.as(Int64), action_type_code: type.code!, action_type_label: type.label!,
          reference: action.reference!, title: action.title!, date: action.date!, hour: action.hour.to_s,
          priority: action.priority!.to_i32, state: action.state!, remind_on: action.remind_on,
          card: action.card_id.try { |card_id| cards[card_id.to_i64]? }, contact: action.contact_card_id.try { |card_id| cards[card_id.to_i64]? },
          concerned: concerned_ids.compact_map { |card_id| cards[card_id]? }, tags: tags.map { |tag| tag_view(tag) },
          links: Link.filter(action_id: id).order(:reference).to_a.map(&.reference!), related: related(id),
          comments: Comment.filter(action_id: id).order(:created_at, :id).to_a.map { |comment| comment_view(comment) },
          owner_id: action.owner_id.try(&.to_i64), created_at: action.created_at!, updated_at: action.updated_at!,
          visible_profile_id: action.visible_profile_id.try(&.to_i64))
      end

      def self.comment_view(comment : Comment) : Api::CommentView
        Api::CommentView.new(comment.pk!.as(Int64), comment.text!, comment.author_id.try(&.to_i64), comment.created_at!)
      end

      # Actions liées à une action (dans les deux sens), par date.
      def self.related(id : Int64) : Array(Api::ActionRef)
        ids = Relation.filter(least_id: id).to_a.map(&.greatest_id!.as(Int64)) +
              Relation.filter(greatest_id: id).to_a.map(&.least_id!.as(Int64))
        return [] of Api::ActionRef if ids.empty?
        Action.filter(id__in: ids.uniq).order(:date, :id).to_a.map do |action|
          Api::ActionRef.new(action.pk!.as(Int64), action.reference!, action.title!, action.date!, action.state!)
        end
      end

      # Paire rangée (plus petit, plus grand).
      def self.pair(a : Int64, b : Int64) : {Int64, Int64}
        a < b ? {a, b} : {b, a}
      end

      # --- Recherche ------------------------------------------------------------------

      alias Arg = ::DB::Any | Array(Int64)

      def self.search_sql(query : Api::ActionQuery, viewer : Visibility::Viewer? = nil) : {String, Array(Arg)}
        args = [] of Arg
        conditions = [] of String
        arg = ->(value : Arg) { args << value; "$#{args.size}" }
        viewer.try { |reader| conditions << Visibility.condition(reader, arg) }
        if text = query.search.try(&.strip).presence
          pattern = "%#{text.gsub(/[\\%_]/) { |char| "\\#{char}" }}%"
          like = arg.call(pattern)
          exact = arg.call(text)
          conditions << "(a.title ILIKE #{like} OR a.reference = #{exact} OR EXISTS " \
                        "(SELECT 1 FROM followup_comment c WHERE c.action_id = a.id AND c.text ILIKE #{like}))"
        end
        if card_id = query.card_id
          ref = arg.call(card_id)
          conditions << "(a.card_id = #{ref} OR a.contact_card_id = #{ref} OR EXISTS " \
                        "(SELECT 1 FROM followup_action_card p WHERE p.action_id = a.id AND p.card_id = #{ref}))"
        end
        query.action_type_id.try { |id| conditions << "a.action_type_id = #{arg.call(id)}" }
        if state = query.state
          conditions << "a.state = #{arg.call(state)}"
        elsif query.open_only
          conditions << "a.state IN ('todo', 'follow')"
        end
        conditions << "a.card_id IS NULL" if query.internal_only
        query.date_from.try { |date| conditions << "a.date >= #{arg.call(day(date).to_s("%Y-%m-%d"))}::date" }
        query.date_to.try { |date| conditions << "a.date <= #{arg.call(day(date).to_s("%Y-%m-%d"))}::date" }
        query.remind_to.try { |date| conditions << "a.remind_on <= #{arg.call(day(date).to_s("%Y-%m-%d"))}::date" }
        unless query.tag_ids.empty?
          tags = arg.call(query.tag_ids.uniq)
          if query.all_tags
            conditions << "(SELECT count(DISTINCT t.tag_id) FROM followup_action_tag t WHERE t.action_id = a.id " \
                          "AND t.tag_id = ANY(#{tags})) = #{query.tag_ids.uniq.size}"
          else
            conditions << "EXISTS (SELECT 1 FROM followup_action_tag t WHERE t.action_id = a.id AND t.tag_id = ANY(#{tags}))"
          end
        end
        where = conditions.empty? ? "" : " WHERE #{conditions.join(" AND ")}"
        {where, args}
      end

      def self.search(query : Api::ActionQuery, viewer : Visibility::Viewer? = nil) : Array(Api::ActionSummaryView)
        where, args = search_sql(query, viewer)
        limit = query.limit.clamp(0, 10_000)
        offset = query.offset.clamp(0, Int32::MAX)
        ids = [] of Int64
        Marten::DB::Connection.default.open do |db|
          db.query("SELECT a.id FROM followup_action a#{where} ORDER BY a.date DESC, a.id DESC " \
                   "LIMIT #{limit} OFFSET #{offset}", args: args) do |result_set|
            result_set.each { ids << result_set.read(Int64) }
          end
        end
        summaries(ids)
      end

      # Toutes les actions d'une recherche, sans LIMIT (export) : les
      # identifiants d'abord, puis les résumés par paquets de 1 000.
      def self.search_all(query : Api::ActionQuery, viewer : Visibility::Viewer? = nil) : Array(Api::ActionSummaryView)
        where, args = search_sql(query, viewer)
        ids = [] of Int64
        Marten::DB::Connection.default.open do |db|
          db.query("SELECT a.id FROM followup_action a#{where} ORDER BY a.date DESC, a.id DESC", args: args) do |result_set|
            result_set.each { ids << result_set.read(Int64) }
          end
        end
        ids.each_slice(1_000).flat_map { |slice| summaries(slice) }.to_a
      end

      def self.count(query : Api::ActionQuery, viewer : Visibility::Viewer? = nil) : Int64
        where, args = search_sql(query, viewer)
        Marten::DB::Connection.default.open do |db|
          db.query_one("SELECT count(*) FROM followup_action a#{where}", args: args, &.read(Int64))
        end
      end

      # Résumés d'actions, dans l'ordre des identifiants donnés.
      def self.summaries(ids : Array(Int64)) : Array(Api::ActionSummaryView)
        return [] of Api::ActionSummaryView if ids.empty?
        actions = Action.filter(id__in: ids).to_a.index_by(&.pk!.as(Int64))
        types = ActionType.all.to_a.index_by(&.pk!.as(Int64))
        cards = Cards.by_id(actions.values.compact_map(&.card_id.try(&.to_i64)))
        tags = {} of Int64 => Array(String)
        last_comments = {} of Int64 => Time
        Marten::DB::Connection.default.open do |db|
          db.query("SELECT t.action_id, g.label FROM followup_action_tag t JOIN followup_tag g ON g.id = t.tag_id " \
                   "WHERE t.action_id = ANY($1) ORDER BY g.label", args: [ids]) do |result_set|
            result_set.each { (tags[result_set.read(Int64)] ||= [] of String) << result_set.read(String) }
          end
          db.query("SELECT action_id, max(created_at) FROM followup_comment WHERE action_id = ANY($1) GROUP BY action_id",
            args: [ids]) do |result_set|
            result_set.each { last_comments[result_set.read(Int64)] = result_set.read(Time) }
          end
        end
        ids.compact_map do |id|
          action = actions[id]? || next
          type = types[action.action_type_id!.as(Int64)]
          Api::ActionSummaryView.new(
            id: id, reference: action.reference!, title: action.title!, action_type_code: type.code!,
            action_type_label: type.label!, date: action.date!, hour: action.hour.to_s, priority: action.priority!.to_i32,
            state: action.state!, remind_on: action.remind_on, card: action.card_id.try { |card_id| cards[card_id.to_i64]? },
            tags: tags.fetch(id, [] of String), last_comment_at: last_comments[id]?)
        end
      end

      # --- Rappels ---------------------------------------------------------------------

      def self.reminders(today : Time, viewer : Visibility::Viewer? = nil) : Api::RemindersView
        day = day(today).to_s("%Y-%m-%d")
        today_ids = [] of Int64
        late_ids = [] of Int64
        Marten::DB::Connection.default.open do |db|
          db.query("SELECT id FROM followup_action WHERE state IN ('todo', 'follow') AND remind_on = $1::date " \
                   "ORDER BY hour, id", args: [day]) do |result_set|
            result_set.each { today_ids << result_set.read(Int64) }
          end
          db.query("SELECT id FROM followup_action WHERE state IN ('todo', 'follow') AND remind_on < $1::date " \
                   "ORDER BY remind_on DESC, id", args: [day]) do |result_set|
            result_set.each { late_ids << result_set.read(Int64) }
          end
        end
        Api::RemindersView.new(summaries(Visibility.filter(today_ids, viewer)), summaries(Visibility.filter(late_ids, viewer)))
      end
    end
  end
end
