# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Accounting
    # Rattachement des fiches du socle au plan comptable, héritier de
    # `comptaproc.account_insert`, `account_compute` et `account_auto`
    # (attribut 5 de `fiche_detail`, `fiche_def.fd_class_base`,
    # `fd_create_account`). La fiche est lue par le contrat du socle
    # (`Partiduo::Api::Cards`). Service interne.
    module CardAccounts
      alias FieldError = Partiduo::Api::FieldError

      DIGITS = /\A[0-9]+\z/

      # Fiche lue par le contrat du socle ; `nil` si elle n'existe pas.
      def self.card(actor : Partiduo::Api::Actor, card_id : Int64) : Partiduo::Api::Cards::CardView?
        Partiduo::Api::Cards.card(actor, card_id)
      rescue Partiduo::Api::NotFound
        nil
      end

      # Résout le compte d'une fiche, en le préparant s'il faut le créer.
      # Renvoie le compte (non enregistré s'il est nouveau) ou les erreurs.
      def self.resolve(card : Partiduo::Api::Cards::CardView, requested : String?) : {Account?, Array(FieldError)}
        errors = [] of FieldError
        category = CardCategoryAccount.filter(category_id: card.category_id).first
        base = category.try(&.base_account)

        if number = requested.try { |value| Chart.normalize(value) }.presence
          if account = Account.filter(number: number).first
            unless account.direct_use
              errors << FieldError.new("account", "accounting.errors.card_account.account.not_direct_use", {"number" => number})
            end
            return {account, errors}
          end
          # Compte absent : créé sous le compte de base de la catégorie, ou
          # sous son plus long préfixe, avec le nom de la fiche.
          return {new_account(number, card.name, base, errors), errors}
        end

        if category.nil? || base.nil?
          errors << FieldError.new("account", "accounting.errors.card_account.account.required")
          return {nil, errors}
        end
        if category.create_account && base.number!.matches?(DIGITS)
          return {new_account(compute(base), card.name, base, errors), errors}
        end
        unless base.direct_use
          errors << FieldError.new("account", "accounting.errors.card_account.account.not_direct_use", {"number" => base.number.to_s})
        end
        {base, errors}
      end

      # Enregistre le rattachement (et le compte s'il est nouveau).
      def self.link(card_id : Int64, account : Account) : Account
        account.save! if account.new_record?
        row = CardAccount.filter(card_id: card_id).first || CardAccount.new(card_id: card_id)
        row.account = account
        row.save!
        account
      end

      # Abonné de `card.saved` : une fiche sans compte reçoit celui que sa
      # catégorie prévoit (compte calculé ou compte de base), comme
      # `account_insert` à l'enregistrement d'une fiche d'origine. Une catégorie
      # sans paramétrage, ou un compte impossible à déterminer, laisse la fiche
      # sans compte : l'enregistrement de la fiche n'échoue jamais pour cela.
      def self.on_card_saved(card_id : Int64) : Nil
        return if CardAccount.filter(card_id: card_id).exists?
        card = card(Partiduo::Api::Actor.system, card_id) || return
        account, errors = resolve(card, nil)
        link(card_id, account) if account && errors.empty?
      end

      private def self.new_account(number : String, label : String, parent : Account?,
                                   errors : Array(FieldError)) : Account?
        input = Partiduo::Api::Accounting::AccountInput.new(number: number, label: label, parent: parent.try(&.number))
        values, account_errors = Chart.validate(input)
        account_errors.each do |error|
          field = error.field == "number" ? "account" : error.field
          errors << FieldError.new(field, error.key, error.params)
        end
        values.try { |value| Chart.assign(Account.new, value) }
      end

      # `comptaproc.account_compute`, numérotation numérique : sous le compte
      # de base `B`, `B0001` pour le premier compte, puis le plus grand numéro
      # existant de la forme `B…` augmenté de 1 (suffixe sur 4 chiffres au
      # moins). Un numéro déjà pris est sauté.
      def self.compute(base : Account) : String
        prefix = base.number!
        numbers = Account.filter(parent_id: base.pk).map(&.number!).select(&.matches?(DIGITS))
        highest = numbers.max_by? { |number| {number.size, number} }
        candidate = if highest.nil? || highest.size < prefix.size + 4
                      "#{prefix}0001"
                    else
                      within = numbers.select(&.starts_with?(prefix)).max_by? { |number| {number.size, number} } || "#{prefix}0000"
                      "#{prefix}#{(within[prefix.size..].to_big_i + 1).to_s.rjust(4, '0')}"
                    end
        while Account.filter(number: candidate).exists?
          candidate = "#{prefix}#{(candidate[prefix.size..].to_big_i + 1).to_s.rjust(4, '0')}"
        end
        candidate
      end
    end
  end
end
