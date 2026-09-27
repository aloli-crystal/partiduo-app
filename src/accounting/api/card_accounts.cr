# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    # Contrat du module Comptabilité — rattachement des fiches et catégories de
    # fiches du socle au plan comptable (lot 1). Le socle ignore ce
    # rattachement (ADR-006 D3) : la Comptabilité crée le compte d'une fiche
    # neuve à l'événement `card.saved` (selon sa catégorie), et l'interface
    # appelle `assign_card_account` pour en choisir un autre.
    module Accounting
      # Compte d'une fiche ; `nil` si elle n'en a pas.
      def self.card_account(actor : Actor, card_id : Int64) : CardAccountView?
        Guard.authorize!(actor, "accounting.account.read", module_code: MODULE_CODE)
        Partiduo::Accounting::CardAccount.filter(card_id: card_id).first.try do |row|
          CardAccountView.new(card_id, account_view(row.account!))
        end
      end

      # Fiches rattachées à un compte (« Toutes les fiches » du plan comptable).
      def self.card_ids_for_account(actor : Actor, number : String) : Array(Int64)
        Guard.authorize!(actor, "accounting.account.read", module_code: MODULE_CODE)
        account = find_account!(number)
        Partiduo::Accounting::CardAccount.filter(account_id: account.pk).order(:card_id).map(&.card_id!.to_i64)
      end

      # Rattache une fiche à un compte, en créant le compte au besoin
      # (`comptaproc.account_insert`) ; remplace un rattachement existant. La
      # fiche est lue par le contrat du socle (`cards.card.read` requis).
      def self.assign_card_account(actor : Actor, input : AssignCardAccountInput) : Result(CardAccountView)
        Guard.authorize!(actor, "accounting.account.write", module_code: MODULE_CODE)
        Transaction.run do
          card = Partiduo::Accounting::CardAccounts.card(actor, input.card_id)
          if card.nil?
            next Result(CardAccountView).failure(FieldError.new("card_id", "accounting.errors.card_account.card_id.not_found"))
          end
          account, errors = Partiduo::Accounting::CardAccounts.resolve(card, input.account)
          next Result(CardAccountView).failure(errors) if account.nil? || !errors.empty?
          Partiduo::Accounting::CardAccounts.link(input.card_id, account)
          Result(CardAccountView).success(CardAccountView.new(input.card_id, account_view(account)))
        end
      end

      # Détache une fiche de son compte (le compte est conservé).
      def self.unassign_card_account(actor : Actor, card_id : Int64) : Result(Nil)
        Guard.authorize!(actor, "accounting.account.write", module_code: MODULE_CODE)
        Transaction.run do
          Partiduo::Accounting::CardAccount.filter(card_id: card_id).delete
          Result(Nil).success(nil)
        end
      end

      # Compte de base et création automatique d'une catégorie ; `nil` si la
      # catégorie n'est pas paramétrée côté comptabilité.
      def self.card_category_account(actor : Actor, category_id : Int64) : CardCategoryAccountView?
        Guard.authorize!(actor, "accounting.account.read", module_code: MODULE_CODE)
        Partiduo::Accounting::CardCategoryAccount.filter(category_id: category_id).first.try do |row|
          category_account_view(row)
        end
      end

      def self.set_card_category_account(actor : Actor, input : CardCategoryAccountInput) : Result(CardCategoryAccountView)
        Guard.authorize!(actor, "accounting.account.write", module_code: MODULE_CODE)
        Transaction.run do
          errors = [] of FieldError
          begin
            Partiduo::Api::Cards.category(actor, input.category_id)
          rescue NotFound
            errors << FieldError.new("category_id", "accounting.errors.card_category.category_id.not_found")
          end
          base = nil
          if number = input.base_account.presence.try { |value| Partiduo::Accounting::Chart.normalize(value) }.presence
            base = Partiduo::Accounting::Account.filter(number: number).first
            if base.nil?
              errors << FieldError.new("base_account", "accounting.errors.card_category.base_account.not_found", {"number" => number})
            end
          elsif input.create_account
            errors << FieldError.new("base_account", "accounting.errors.card_category.base_account.required")
          end
          next Result(CardCategoryAccountView).failure(errors) unless errors.empty?

          row = Partiduo::Accounting::CardCategoryAccount.filter(category_id: input.category_id).first ||
                Partiduo::Accounting::CardCategoryAccount.new(category_id: input.category_id)
          row.base_account = base
          row.create_account = input.create_account
          row.save!
          Result(CardCategoryAccountView).success(category_account_view(row))
        end
      end

      private def self.category_account_view(row : Partiduo::Accounting::CardCategoryAccount) : CardCategoryAccountView
        CardCategoryAccountView.new(row.category_id!.to_i64, row.base_account.try { |account| account_view(account) },
          row.create_account == true)
      end
    end
  end
end
