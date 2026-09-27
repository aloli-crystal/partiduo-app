# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    # Contrat du module Comptabilité — plan comptable et comptes par défaut
    # (lot 1, héritiers de `tmp_pcmn` et `parm_code`).
    module Accounting
      # --- Requêtes ---------------------------------------------------------------

      # Plan comptable en arbre (SQL récursif) : tout le plan, ou le sous-arbre
      # du compte `root` (lui compris, profondeur 0).
      def self.chart(actor : Actor, root : String? = nil) : Array(ChartLineView)
        Guard.authorize!(actor, "accounting.account.read", module_code: MODULE_CODE)
        root_id = root.try { |number| find_account!(number).pk!.as(Int64) }
        Partiduo::Accounting::Chart.tree(root_id).map do |row|
          view = AccountView.new(row.id, row.number, row.label, row.parent_id, row.parent_number,
            AccountKind.from_code(row.kind), row.direct_use)
          ChartLineView.new(view, row.depth, row.children_count)
        end
      end

      # Un compte par son numéro (normalisé comme à la saisie).
      def self.account(actor : Actor, number : String) : AccountView
        Guard.authorize!(actor, "accounting.account.read", module_code: MODULE_CODE)
        account_view(find_account!(number))
      end

      def self.account_by_id(actor : Actor, id : Int64) : AccountView
        Guard.authorize!(actor, "accounting.account.read", module_code: MODULE_CODE)
        account_view(Partiduo::Accounting::Account.filter(id: id).first || raise NotFound.new("account", id))
      end

      # Recherche pour l'autocomplétion : numéros commençant par la saisie
      # normalisée, ou libellés la contenant. `direct_use_only` : seulement les
      # comptes utilisables en saisie.
      def self.search_accounts(actor : Actor, query : String, limit : Int32 = 20,
                               direct_use_only : Bool = false) : Array(AccountView)
        Guard.authorize!(actor, "accounting.account.read", module_code: MODULE_CODE)
        text = query.strip
        return [] of AccountView if text.empty?
        number = Partiduo::Accounting::Chart.normalize(text)
        accounts = Partiduo::Accounting::Account.filter { q(number__startswith: number) | q(label__icontains: text) }
        accounts = accounts.filter(direct_use: true) if direct_use_only
        accounts.order(:number)[0...limit.clamp(1, 200)].to_a.map { |account| account_view(account) }
      end

      # --- Commandes ------------------------------------------------------------

      # Requête de contrôle : la règle de `create_account` / `update_account`.
      def self.check_account(actor : Actor, input : AccountInput, id : Int64? = nil) : Result(Nil)
        Guard.authorize!(actor, "accounting.account.write", module_code: MODULE_CODE)
        current = id.try { |value| Partiduo::Accounting::Account.filter(id: value).first || raise NotFound.new("account", value) }
        _, errors = Partiduo::Accounting::Chart.validate(input, current)
        errors.empty? ? Result(Nil).success(nil) : Result(Nil).failure(errors)
      end

      def self.create_account(actor : Actor, input : AccountInput) : Result(AccountView)
        Guard.authorize!(actor, "accounting.account.write", module_code: MODULE_CODE)
        Transaction.run do
          values, errors = Partiduo::Accounting::Chart.validate(input)
          next Result(AccountView).failure(errors) if values.nil?
          account = Partiduo::Accounting::Chart.assign(Partiduo::Accounting::Account.new, values)
          account.save!
          Result(AccountView).success(account_view(account))
        end
      end

      def self.update_account(actor : Actor, id : Int64, input : AccountInput) : Result(AccountView)
        Guard.authorize!(actor, "accounting.account.write", module_code: MODULE_CODE)
        Transaction.run do
          account = Partiduo::Accounting::Account.filter(id: id).lock.first || raise NotFound.new("account", id)
          values, errors = Partiduo::Accounting::Chart.validate(input, account)
          next Result(AccountView).failure(errors) if values.nil?
          Partiduo::Accounting::Chart.assign(account, values).save!
          Result(AccountView).success(account_view(account))
        end
      end

      # Efface un compte sans enfant ni usage (fiche, catégorie, journal,
      # compte par défaut ; écritures au lot 2).
      def self.delete_account(actor : Actor, id : Int64) : Result(Nil)
        Guard.authorize!(actor, "accounting.account.write", module_code: MODULE_CODE)
        Transaction.run do
          account = Partiduo::Accounting::Account.filter(id: id).lock.first || raise NotFound.new("account", id)
          errors = Partiduo::Accounting::Chart.delete_errors(account)
          next Result(Nil).failure(errors) unless errors.empty?
          account.delete
          Result(Nil).success(nil)
        end
      end

      # --- Comptes par défaut (`parm_code`) --------------------------------------

      def self.default_accounts(actor : Actor) : Array(DefaultAccountView)
        Guard.authorize!(actor, "accounting.account.read", module_code: MODULE_CODE)
        rows = Partiduo::Accounting::DefaultAccount.all.to_a.to_h { |row| {row.code.to_s, row} }
        DEFAULT_ACCOUNT_CODES.compact_map do |code|
          rows[code]?.try { |row| DefaultAccountView.new(code, account_view(row.account!)) }
        end
      end

      # Compte par défaut d'un usage ; `nil` si aucun n'est défini.
      def self.default_account(actor : Actor, code : String) : AccountView?
        Guard.authorize!(actor, "accounting.account.read", module_code: MODULE_CODE)
        Partiduo::Accounting::DefaultAccount.filter(code: code).first.try { |row| account_view(row.account!) }
      end

      # Définit (ou retire, `account` à `nil`) le compte par défaut d'un usage
      # de `DEFAULT_ACCOUNT_CODES`.
      def self.set_default_account(actor : Actor, code : String, account : String?) : Result(Nil)
        Guard.authorize!(actor, "accounting.account.write", module_code: MODULE_CODE)
        Transaction.run do
          unless DEFAULT_ACCOUNT_CODES.includes?(code)
            next Result(Nil).failure(FieldError.new("code", "accounting.errors.default_account.code.invalid"))
          end
          row = Partiduo::Accounting::DefaultAccount.filter(code: code).first
          number = Partiduo::Accounting::Chart.normalize(account || "")
          if number.empty?
            row.try(&.delete)
            next Result(Nil).success(nil)
          end
          target = Partiduo::Accounting::Account.filter(number: number).first
          if target.nil?
            params = {"number" => number}
            next Result(Nil).failure(FieldError.new("account", "accounting.errors.default_account.account.not_found", params))
          end
          row ||= Partiduo::Accounting::DefaultAccount.new(code: code)
          row.account = target
          row.save!
          Result(Nil).success(nil)
        end
      end

      # --- Outils ---------------------------------------------------------------

      private def self.find_account!(number : String) : Partiduo::Accounting::Account
        normalized = Partiduo::Accounting::Chart.normalize(number)
        Partiduo::Accounting::Account.filter(number: normalized).first || raise NotFound.new("account", normalized)
      end

      private def self.account_view(account : Partiduo::Accounting::Account) : AccountView
        parent = account.parent
        AccountView.new(
          id: account.pk!.as(Int64),
          number: account.number.to_s,
          label: account.label.to_s,
          parent_id: parent.try(&.pk!.as(Int64)),
          parent_number: parent.try(&.number),
          kind: AccountKind.from_code(account.kind.to_s),
          direct_use: account.direct_use == true,
        )
      end
    end
  end
end
