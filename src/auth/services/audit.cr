# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Auth
    # Journal d'audit nominatif (ADR-002 D4), héritier d'`audit_connect` :
    # connexions réussies et échouées, actions d'administration, et actions
    # que les modules y inscrivent (`Partiduo::Api::Auth.audit`).
    module Audit
      def self.record(action : String, state : String, user : User? = nil, user_id : Int64? = nil,
                      label : String? = nil, module_code : String = "AUTH", ip : String = "",
                      detail : String = "") : AuditEvent
        raise ArgumentError.new("état d'audit inconnu : #{state}") unless AuditEvent::STATES.includes?(state)
        AuditEvent.create!(
          actor_id: user.try(&.pk.as(Int64?)) || user_id,
          user_label: (label || user.try(&.audit_label) || "")[0, 255],
          action: action[0, 64],
          module_code: module_code[0, 64],
          state: state,
          ip: ip[0, 64],
          detail: detail,
        )
      end

      # Événement attribué à un acteur du contrat (utilisateur ou système).
      def self.record_for(actor : Partiduo::Api::Actor, action : String, state : String,
                          module_code : String = "AUTH", detail : String = "") : AuditEvent
        if actor.system
          record(action, state, label: "system", module_code: module_code, detail: detail)
        elsif user_id = actor.user_id
          record(action, state, user: User.get(id: user_id), user_id: user_id,
            module_code: module_code, detail: detail)
        else
          record(action, state, label: "anonymous", module_code: module_code, detail: detail)
        end
      end
    end
  end
end
