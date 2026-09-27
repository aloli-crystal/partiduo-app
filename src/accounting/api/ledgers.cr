# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    # Contrat du module Comptabilité — journaux (lot 1, héritiers de `jrn_def`)
    # et droits par journal (`user_sec_jrn`, tenus par le socle, D-AUTH-010).
    module Accounting
      # --- Requêtes ---------------------------------------------------------------

      # Journaux visibles de l'acteur (droit `R` ou `W`, ou administration des
      # journaux), par code. Filtres : type, journaux actifs seulement.
      def self.ledgers(actor : Actor, kind : LedgerKind? = nil, enabled_only : Bool = false) : Array(LedgerView)
        Guard.authorize!(actor, "accounting.ledger.read", module_code: MODULE_CODE)
        ledgers = Partiduo::Accounting::Ledger.all
        ledgers = ledgers.filter(kind: kind.code) if kind
        ledgers = ledgers.filter(enabled: true) if enabled_only
        ledgers.order(:code).to_a.compact_map do |ledger|
          access = Partiduo::Accounting::Ledgers.access(actor, ledger.pk!.as(Int64))
          ledger_view(ledger, access) if Partiduo::Accounting::Ledgers.visible?(actor, access)
        end
      end

      # Un journal visible de l'acteur ; `NotFound` sinon.
      def self.ledger(actor : Actor, id : Int64) : LedgerView
        Guard.authorize!(actor, "accounting.ledger.read", module_code: MODULE_CODE)
        visible_ledger(actor, Partiduo::Accounting::Ledger.filter(id: id).first, id)
      end

      def self.ledger_by_code(actor : Actor, code : String) : LedgerView
        Guard.authorize!(actor, "accounting.ledger.read", module_code: MODULE_CODE)
        normalized = code.strip.upcase
        visible_ledger(actor, Partiduo::Accounting::Ledger.filter(code: normalized).first, normalized)
      end

      # Droit de l'acteur sur un journal (`get_ledger_access`) : l'interface
      # s'en sert pour proposer la saisie ; le lot 2 le vérifie à chaque
      # écriture.
      def self.ledger_access(actor : Actor, ledger_id : Int64) : LedgerAccess
        Guard.authorize!(actor, nil, module_code: MODULE_CODE)
        raise NotFound.new("ledger", ledger_id) unless Partiduo::Accounting::Ledger.filter(id: ledger_id).exists?
        Partiduo::Accounting::Ledgers.access(actor, ledger_id)
      end

      # --- Commandes ------------------------------------------------------------

      # Requête de contrôle : la règle de `create_ledger` / `update_ledger`.
      def self.check_ledger(actor : Actor, input : LedgerInput, id : Int64? = nil) : Result(Nil)
        Guard.authorize!(actor, "accounting.ledger.write", module_code: MODULE_CODE)
        current = id.try { |value| Partiduo::Accounting::Ledger.filter(id: value).first || raise NotFound.new("ledger", value) }
        _, errors = Partiduo::Accounting::Ledgers.validate(actor, input, current)
        errors.empty? ? Result(Nil).success(nil) : Result(Nil).failure(errors)
      end

      def self.create_ledger(actor : Actor, input : LedgerInput) : Result(LedgerView)
        Guard.authorize!(actor, "accounting.ledger.write", module_code: MODULE_CODE)
        Transaction.run do
          values, errors = Partiduo::Accounting::Ledgers.validate(actor, input)
          next Result(LedgerView).failure(errors) if values.nil?
          ledger = Partiduo::Accounting::Ledgers.assign(Partiduo::Accounting::Ledger.new, values)
          ledger.save!
          access = Partiduo::Accounting::Ledgers.access(actor, ledger.pk!.as(Int64))
          Result(LedgerView).success(ledger_view(ledger, access))
        end
      end

      def self.update_ledger(actor : Actor, id : Int64, input : LedgerInput) : Result(LedgerView)
        Guard.authorize!(actor, "accounting.ledger.write", module_code: MODULE_CODE)
        Transaction.run do
          ledger = Partiduo::Accounting::Ledger.filter(id: id).lock.first || raise NotFound.new("ledger", id)
          values, errors = Partiduo::Accounting::Ledgers.validate(actor, input, ledger)
          next Result(LedgerView).failure(errors) if values.nil?
          Partiduo::Accounting::Ledgers.assign(ledger, values).save!
          Result(LedgerView).success(ledger_view(ledger, Partiduo::Accounting::Ledgers.access(actor, id)))
        end
      end

      # Efface un journal (`delete_ledger` : refusé s'il contient des
      # écritures). Les droits par journal du socle qui le citent deviennent
      # sans objet.
      def self.delete_ledger(actor : Actor, id : Int64) : Result(Nil)
        Guard.authorize!(actor, "accounting.ledger.write", module_code: MODULE_CODE)
        Transaction.run do
          ledger = Partiduo::Accounting::Ledger.filter(id: id).lock.first || raise NotFound.new("ledger", id)
          if Partiduo::Accounting::Ledgers.used?(ledger)
            next Result(Nil).failure(FieldError.base("accounting.errors.ledger.in_use"))
          end
          ledger.delete
          Result(Nil).success(nil)
        end
      end

      # --- Outils ---------------------------------------------------------------

      private def self.visible_ledger(actor : Actor, ledger : Partiduo::Accounting::Ledger?, key) : LedgerView
        ledger || raise NotFound.new("ledger", key)
        access = Partiduo::Accounting::Ledgers.access(actor, ledger.pk!.as(Int64))
        raise NotFound.new("ledger", key) unless Partiduo::Accounting::Ledgers.visible?(actor, access)
        ledger_view(ledger, access)
      end

      private def self.ledger_view(ledger : Partiduo::Accounting::Ledger, access : LedgerAccess) : LedgerView
        LedgerView.new(
          id: ledger.pk!.as(Int64),
          code: ledger.code.to_s,
          name: ledger.name.to_s,
          kind: LedgerKind.from_code(ledger.kind.to_s),
          description: ledger.description.to_s,
          enabled: ledger.enabled == true,
          default_account: Partiduo::Accounting::Ledgers.account_of(ledger).try { |account| account_view(account) },
          receipt_prefix: ledger.receipt_prefix.to_s,
          receipt_padding: ledger.receipt_padding!.to_i32,
          last_receipt_number: ledger.last_receipt_number!.to_i64,
          currency_code: ledger.currency_code.to_s,
          access: access,
          bank_card_id: ledger.bank_card_id.try(&.to_i64),
          bank_card_code: ledger.bank_card_id.try { |id| bank_card_code(id.to_i64) },
        )
      end

      private def self.bank_card_code(card_id : Int64) : String?
        Partiduo::Api::Cards.card(Actor.system, card_id).code
      rescue NotFound
        nil
      end
    end
  end
end
