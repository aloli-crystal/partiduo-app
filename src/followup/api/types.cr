# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    # Types du contrat du module Suivi (lot 6). Référence :
    # `doc/api/followup.adoc`.
    module Followup
      # États d'une action (`document_state`) : `todo` (à faire), `follow`
      # (à suivre), `closed` (clôturé), `abandoned` (abandonné). Les deux
      # derniers terminent l'action (`s_status = 'C'`).
      STATES      = %w[todo follow closed abandoned]
      OPEN_STATES = %w[todo follow]
      # Priorités (`ag_priority`) : 1 haute, 2 normale, 3 basse.
      PRIORITIES = [1, 2, 3]

      # --- Types d'action et étiquettes ------------------------------------------------

      # Type d'action (`document_type`) : préfixe des références (10
      # caractères au plus, lettres et chiffres, mis en majuscules, unique),
      # libellé (80 caractères au plus). `next_number` : prochain numéro de
      # la série, modifiable (`seq_doc_type_<id>`), 1 au moins.
      record ActionTypeInput, code : String, label : String, next_number : Int32? = nil

      record ActionTypeView, id : Int64, code : String, label : String, next_number : Int32, actions_count : Int64

      # Étiquette (`tags`) : libellé unique (60 caractères au plus),
      # description, active ou non, couleur de 1 à 10.
      record TagInput, label : String, description : String = "", active : Bool = true, color : Int32 = 1

      record TagView, id : Int64, label : String, description : String, active : Bool, color : Int32

      # --- Actions ------------------------------------------------------------------------

      # Saisie d'une action (`Follow_Up::save`, `update`).
      #
      # * `title` : vide = libellé du type ;
      # * `hour` : `HH:MM` ou vide ;
      # * `card_id` : fiche destinataire, `nil` = action interne ;
      #   `contact_card_id` : fiche de contact ;
      # * `remind_on` : date de rappel ;
      # * `concerned_card_ids` : autres fiches concernées (`action_person`) ;
      # * `tag_ids` : étiquettes ;
      # * `comment` : premier commentaire (création seulement) ;
      # * `visible_profile_id` : action réservée aux utilisateurs de ce
      #   profil (plus son auteur et qui paramètre le suivi) ; `nil` :
      #   visible de toute personne qui lit le suivi (D-R5-016).
      record ActionInput,
        action_type_id : Int64,
        date : Time,
        title : String = "",
        hour : String = "",
        priority : Int32 = 2,
        state : String = "todo",
        remind_on : Time? = nil,
        card_id : Int64? = nil,
        contact_card_id : Int64? = nil,
        concerned_card_ids : Array(Int64) = [] of Int64,
        tag_ids : Array(Int64) = [] of Int64,
        comment : String = "",
        visible_profile_id : Int64? = nil

      # Fiche citée par une action.
      record CardRef, id : Int64, code : String, name : String

      # Profil auquel une action peut être réservée (D-R5-016).
      record ProfileRef, id : Int64, name : String

      record CommentView, id : Int64, text : String, author_id : Int64?, created_at : Time

      # Action liée : référence courte.
      record ActionRef, id : Int64, reference : String, title : String, date : Time, state : String

      record ActionView,
        id : Int64,
        action_type_id : Int64,
        action_type_code : String,
        action_type_label : String,
        reference : String,
        title : String,
        date : Time,
        hour : String,
        priority : Int32,
        state : String,
        remind_on : Time?,
        card : CardRef?,
        contact : CardRef?,
        concerned : Array(CardRef),
        tags : Array(TagView),
        links : Array(String),
        related : Array(ActionRef),
        comments : Array(CommentView),
        owner_id : Int64?,
        created_at : Time,
        updated_at : Time,
        visible_profile_id : Int64? = nil do
        def open? : Bool
          OPEN_STATES.includes?(state)
        end

        def internal? : Bool
          card.nil?
        end

        def state_key : String
          "followup.states.#{state}"
        end

        def priority_key : String
          "followup.priorities.p#{priority}"
        end

        # Rappel dépassé au jour `today` (`get_late`).
        def late?(today : Time) : Bool
          open? && !(day = remind_on).nil? && day < today
        end
      end

      # Ligne d'une liste d'actions (sans commentaires ni liens).
      record ActionSummaryView,
        id : Int64,
        reference : String,
        title : String,
        action_type_code : String,
        action_type_label : String,
        date : Time,
        hour : String,
        priority : Int32,
        state : String,
        remind_on : Time?,
        card : CardRef?,
        tags : Array(String),
        last_comment_at : Time? do
        def open? : Bool
          OPEN_STATES.includes?(state)
        end

        def state_key : String
          "followup.states.#{state}"
        end
      end

      # Recherche (`Follow_Up::create_query`).
      #
      # * `search` : titre ou commentaire (contient, sans casse), ou
      #   référence exacte ;
      # * `card_id` : fiche destinataire, contact ou concernée ;
      # * `state` : un état ; sinon `open_only` (défaut) écarte les actions
      #   terminées ;
      # * `internal_only` : actions sans destinataire ;
      # * `date_from`, `date_to` : date de l'action ; `remind_to` : rappel au
      #   plus tard ce jour ;
      # * `tag_ids` : au moins une de ces étiquettes (`all_tags` : toutes).
      record ActionQuery,
        search : String? = nil,
        card_id : Int64? = nil,
        action_type_id : Int64? = nil,
        state : String? = nil,
        open_only : Bool = true,
        internal_only : Bool = false,
        date_from : Time? = nil,
        date_to : Time? = nil,
        remind_to : Time? = nil,
        tag_ids : Array(Int64) = [] of Int64,
        all_tags : Bool = false,
        limit : Int32 = 100,
        offset : Int32 = 0

      # Rappels (tableau de bord, `get_today`, `get_late`) : actions ouvertes
      # dont le rappel tombe ce jour, ou est dépassé.
      record RemindersView, today : Array(ActionSummaryView), late : Array(ActionSummaryView)

      record FileView, filename : String, content_type : String, content : Bytes
    end
  end
end
