# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Stock
    # Droits par dépôt (`profile_sec_repository` d'origine ; DECISIONS
    # D-STK-006 révisée, D-R5-015). Un profil sans ligne garde les droits
    # globaux du Stock (`stock.movement.read`, `.write`) ; un profil qui en a
    # ne voit que les dépôts cités, en lecture (`R`) ou en écriture (`W`).
    # L'acteur système et qui paramètre le Stock (`stock.settings.write`)
    # voient tout ; un acteur sans utilisateur (outil en ligne de commande)
    # aussi.
    module Access
      alias Api = Partiduo::Api::Stock

      ACCESSES = %w[R W]

      # Dépôts lisibles de l'acteur ; `nil` : tous.
      def self.readable(actor : Partiduo::Api::Actor) : Set(Int64)?
        rows(actor).try(&.keys.to_set)
      end

      # Dépôts où l'acteur écrit ; `nil` : tous.
      def self.writable(actor : Partiduo::Api::Actor) : Set(Int64)?
        rows(actor).try(&.select { |_, access| access == "W" }.keys.to_set)
      end

      def self.read?(actor : Partiduo::Api::Actor, repository_id : Int64) : Bool
        readable(actor).try(&.includes?(repository_id)) != false
      end

      def self.write?(actor : Partiduo::Api::Actor, repository_id : Int64) : Bool
        writable(actor).try(&.includes?(repository_id)) != false
      end

      # Droits du profil de l'acteur (dépôt → `R`/`W`) ; `nil` sans restriction.
      private def self.rows(actor : Partiduo::Api::Actor) : Hash(Int64, String)?
        return if actor.system || actor.can?(Api::SETTINGS_WRITE)
        user_id = actor.user_id || return
        profile_id = Partiduo::Auth::User.filter(id: user_id).first.try(&.profile_id.try(&.as(Int).to_i64)) || return
        rows = RepositoryAccess.filter(profile_id: profile_id).to_a
        return if rows.empty?
        rows.to_h { |row| {row.repository_id!.as(Int64), row.access.to_s} }
      end

      # Droits d'un profil sur chaque dépôt (vide : sans restriction).
      def self.profile_rights(profile_id : Int64) : Hash(Int64, String)
        RepositoryAccess.filter(profile_id: profile_id).to_a.to_h { |row| {row.repository_id!.as(Int64), row.access.to_s} }
      end

      # Remplace les droits d'un profil ; liste vide : restriction levée.
      def self.save!(profile_id : Int64, rights : Array(Api::RepositoryRightInput)) : Nil
        RepositoryAccess.filter(profile_id: profile_id).delete
        rights.each do |right|
          next if right.access.empty?
          RepositoryAccess.create!(profile_id: profile_id, repository_id: right.repository_id, access: right.access)
        end
      end
    end
  end
end
