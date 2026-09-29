# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Followup
    # Visibilité des actions réservées à un profil (`ag_dest` d'origine ;
    # DECISIONS D-FUP-001 révisée, D-R5-016). Une action sans profil est
    # vue de toute personne qui lit le suivi ; une action réservée, des
    # utilisateurs du profil, de son auteur et de qui paramètre le suivi
    # (`followup.settings.write`) ; l'acteur système voit tout.
    module Visibility
      # Lecteur restreint : utilisateur et son profil.
      record Viewer, user_id : Int64?, profile_id : Int64?

      # `nil` : l'acteur voit toutes les actions.
      def self.viewer(actor : Partiduo::Api::Actor) : Viewer?
        return if actor.system || actor.can?(Partiduo::Api::Followup::SETTINGS_WRITE)
        user_id = actor.user_id
        profile_id = user_id.try { |id| Partiduo::Auth::User.filter(id: id).first.try(&.profile_id.try(&.as(Int).to_i64)) }
        Viewer.new(user_id, profile_id)
      end

      def self.visible?(action : Action, viewer : Viewer?) : Bool
        viewer.nil? || (profile = action.visible_profile_id).nil? ||
          (!viewer.user_id.nil? && action.owner_id.try(&.to_i64) == viewer.user_id) ||
          (!viewer.profile_id.nil? && profile.to_i64 == viewer.profile_id)
      end

      # Condition SQL sur l'alias `a` ; `arg` enregistre un paramètre.
      def self.condition(viewer : Viewer, arg : Proc(Actions::Arg, String)) : String
        parts = ["a.visible_profile_id IS NULL"]
        viewer.user_id.try { |id| parts << "a.owner_id = #{arg.call(id)}" }
        viewer.profile_id.try { |id| parts << "a.visible_profile_id = #{arg.call(id)}" }
        "(#{parts.join(" OR ")})"
      end

      # Parmi `ids`, ceux que le lecteur voit, dans le même ordre.
      def self.filter(ids : Array(Int64), viewer : Viewer?) : Array(Int64)
        return ids if viewer.nil? || ids.empty?
        visible = Action.filter(id__in: ids).to_a.select { |action| visible?(action, viewer) }.map(&.pk!.as(Int64)).to_set
        ids.select { |id| visible.includes?(id) }
      end
    end
  end
end
