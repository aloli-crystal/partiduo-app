# SPDX-License-Identifier: AGPL-3.0-or-later

require "yaml"

module Partiduo
  module Accounting
    # Jeu de données initial du module (convention C6) : plan comptable, comptes
    # par défaut et journaux du régime fiscal, repris des modèles de dossier
    # d'origine (`include/sql/mod1` belge — PCMN —, `mod2` français — PCG) par
    # `scripts/chart_from_legacy.cr` (D-ACC-003). Les fichiers sont embarqués
    # à la compilation. Service interne.
    module ReferenceData
      SOURCES = {
        "be" => {{ read_file("#{__DIR__}/../data/chart_be.yml") }},
        "fr" => {{ read_file("#{__DIR__}/../data/chart_fr.yml") }},
      }

      record AccountRow, number : String, label : String, parent : String?, kind : String, direct_use : Bool
      record LedgerRow, kind : String, code : String, receipt_prefix : String, receipt_padding : Int32, bank_account : String?
      record CategoryRow, code : String, base_account : String, create_account : Bool
      record VatRow, code : String, deductible : String, collected : String
      record Data, accounts : Array(AccountRow), default_accounts : Hash(String, String),
        card_categories : Array(CategoryRow), ledgers : Array(LedgerRow), vat_accounts : Array(VatRow)

      def self.regimes : Array(String)
        SOURCES.keys
      end

      def self.for(regime : String) : Data
        yaml = YAML.parse(SOURCES[regime]? || raise ArgumentError.new("régime inconnu : #{regime}"))
        accounts = yaml["accounts"].as_a.map do |row|
          AccountRow.new(row[0].as_s, row[1].as_s, row[2].as_s?, row[3].as_s, row[4].as_bool)
        end
        defaults = yaml["default_accounts"].as_h.to_h { |code, number| {code.as_s, number.as_s} }
        categories = yaml["card_categories"].as_h.map do |code, row|
          CategoryRow.new(code.as_s, row["base_account"].as_s, row["create_account"].as_bool)
        end
        ledgers = yaml["ledgers"].as_a.map do |row|
          LedgerRow.new(row["kind"].as_s, row["code"].as_s, row["receipt_prefix"].as_s,
            row["receipt_padding"].as_i, row["bank_account"].as_s?)
        end
        vat = yaml["vat_accounts"].as_h.map do |code, pair|
          VatRow.new(code.as_s, pair[0].as_s, pair[1].as_s)
        end
        Data.new(accounts, defaults, categories, ledgers, vat)
      end

      # Charge le plan, les comptes par défaut, le compte de base des catégories
      # de fiches du socle présentes (lues par `Partiduo::Api::Cards`, code
      # stable) et les journaux dans une instance vierge. Noms des journaux dans
      # la langue du dossier.
      def self.load(actor : Partiduo::Api::Actor, regime : String, locale : String) : Partiduo::Api::Accounting::InitialDataView
        data = self.for(regime)
        by_number = {} of String => Account
        data.accounts.each do |row|
          account = Account.new(number: row.number, label: row.label, kind: row.kind, direct_use: row.direct_use)
          account.parent = row.parent.try { |parent| by_number[parent] }
          account.save!
          by_number[row.number] = account
        end
        data.default_accounts.each do |code, number|
          DefaultAccount.create!(code: code, account: by_number[number])
        end
        categories = 0
        data.card_categories.each do |row|
          category = Partiduo::Api::Cards.category_by_code(actor, row.code) || next
          CardCategoryAccount.create!(category_id: category.id, base_account: by_number[row.base_account],
            create_account: row.create_account)
          categories += 1
        end
        load_vat_accounts(data, by_number)
        locale = Partiduo::LOCALES.includes?(locale) ? locale : "fr"
        I18n.with_locale(locale) do
          data.ledgers.each do |row|
            bank_card_id = row.bank_account.try { |number| bank_card(actor, by_number[number]) }
            Ledger.create!(
              code: row.code, kind: row.kind,
              name: I18n.t("accounting.initial_data.ledgers.#{row.kind}.name"),
              description: I18n.t("accounting.initial_data.ledgers.#{row.kind}.description"),
              bank_card_id: bank_card_id,
              receipt_prefix: row.receipt_prefix, receipt_padding: row.receipt_padding,
            )
          end
        end
        Partiduo::Api::Accounting::InitialDataView.new(data.accounts.size, data.default_accounts.size, categories,
          data.ledgers.size)
      end

      # Comptes de TVA des taux du régime déjà chargés par le socle
      # (`VAT.rates`, ordre 8) ; un taux absent est ignoré.
      private def self.load_vat_accounts(data : Data, by_number : Hash(String, Account)) : Nil
        data.vat_accounts.each do |row|
          rate = Partiduo::Api::Vat.rate_by_code(Partiduo::Api::Actor.system, row.code) || next
          VatRateAccount.create!(vat_rate_id: rate.id, deductible_account: by_number[row.deductible],
            collected_account: by_number[row.collected])
        end
      end

      # Fiche Banque du journal financier (`jrn_def_bank`, D-ACC-010) :
      # catégorie `BANK` du socle, rattachée au compte de banque du plan.
      # Sans catégorie `BANK`, le journal financier n'est pas créable : `nil`
      # et l'insertion échoue sur la contrainte, ce qui signale l'anomalie.
      private def self.bank_card(actor : Partiduo::Api::Actor, account : Account) : Int64?
        category = Partiduo::Api::Cards.category_by_code(actor, "BANK") || return
        result = Partiduo::Api::Cards.create_card(actor, Partiduo::Api::Cards::CardInput.new(
          category_id: category.id, name: I18n.t("accounting.initial_data.bank_card")))
        raise ArgumentError.new("fiche Banque refusée : #{result.error_keys.join(", ")}") if result.failure?
        card_id = result.value!.id
        # L'abonné de `card.saved` a pu calculer un compte sous le compte de
        # base de la catégorie : la fiche prend le compte du plan, et le
        # compte calculé, neuf et inutilisé, disparaît.
        computed = CardAccount.filter(card_id: card_id).first.try(&.account)
        CardAccounts.link(card_id, account)
        if computed && computed.pk != account.pk && !CardAccount.filter(account_id: computed.pk).exists?
          computed.delete
        end
        card_id
      end
    end
  end
end
