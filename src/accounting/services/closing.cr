# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Accounting
    # Écritures de fin d'exercice, héritières d'`Operation_Closing` et
    # d'`Operation_Opening` (NOALYSS 9.x, `operation_exercice.inc.php`) :
    #
    # * *clôture* : les comptes de charges et de produits (classes 6 et 7)
    #   d'un exercice sont soldés, la différence (le résultat) passe au
    #   compte de résultat ;
    # * *réouverture* (à-nouveaux) : les soldes des autres comptes à la fin de
    #   l'exercice précédent sont reportés au premier jour de l'exercice,
    #   par compte et par fiche ; le résultat que la clôture n'a pas soldé va
    #   au compte de résultat.
    #
    # Là où NOALYSS préparait un brouillon déséquilibré à compléter puis à
    # transférer dans un journal, le cœur propose une écriture équilibrée et
    # la passe par `Posting` (D-CLO-001). Service interne.
    module Closing
      alias Api = Partiduo::Api::Accounting

      ZERO = BigDecimal.new(0)

      # Classes soldées à la clôture (charges et produits), dans les deux
      # régimes.
      INCOME_STATEMENT_CLASSES = {'6', '7'}

      # Comptes de résultat proposés par régime : bénéfice, perte
      # (D-CLO-002). PCG : 120 / 129 ; PCMN : 140 / 141.
      RESULT_ACCOUNTS = {
        "fr" => {"120", "129"},
        "be" => {"140", "141"},
      }

      # Solde d'un compte (et d'une fiche) sur un exercice, signé (débit
      # positif).
      record Balance, number : String, label : String, card_id : Int64?, amount : BigDecimal

      def self.source(kind : String, fiscal_year_id : Int64) : String
        "#{kind}:#{fiscal_year_id}"
      end

      # Soldes des comptes, tous journaux confondus, entre deux dates
      # incluses. `income_statement` : seulement les classes 6 et 7 (sinon
      # toutes les autres) ; `by_card` : un solde par fiche.
      def self.balances(from : Time, to : Time, income_statement : Bool, by_card : Bool) : Array(Balance)
        card_column = by_card ? "x.card_id" : "NULL::bigint"
        class_test = income_statement ? "IN ('6', '7')" : "NOT IN ('6', '7')"
        sql = <<-SQL
          SELECT a.number, a.label, #{card_column},
                 sum(CASE WHEN x.side = 'debit' THEN x.amount ELSE -x.amount END)
          FROM accounting_entry_line x
          JOIN accounting_entry e ON e.id = x.entry_id
          JOIN accounting_account a ON a.id = x.account_id
          WHERE e.date >= $1::date AND e.date <= $2::date AND left(a.number, 1) #{class_test}
          GROUP BY a.number, a.label#{by_card ? ", x.card_id" : ""}
          HAVING sum(CASE WHEN x.side = 'debit' THEN x.amount ELSE -x.amount END) <> 0
          ORDER BY a.number#{by_card ? ", x.card_id NULLS FIRST" : ""}
          SQL
        Marten::DB::Connection.default.open do |db|
          db.query_all(sql, args: [from, to] of ::DB::Any) do |result_set|
            Balance.new(
              number: result_set.read(String), label: result_set.read(String),
              card_id: result_set.read(Int64?), amount: result_set.read(BigDecimal),
            )
          end
        end
      end

      # Verrou transactionnel d'un exercice : sérialise les passages de ses
      # écritures de fin d'exercice.
      def self.lock(fiscal_year_id : Int64) : Nil
        Marten::DB::Connection.default.open(&.exec("SELECT pg_advisory_xact_lock(hashtext($1))", "year_end:#{fiscal_year_id}"))
      end

      # Écriture en vigueur (ni extourne ni extournée) qui porte la référence.
      def self.posted_entry_id(source : String) : Int64?
        Entry.filter(source: source, reversal_of_id: nil, reversed: false).first.try(&.id!.to_i64)
      end

      # Comptes de résultat proposés pour le régime de l'instance.
      def self.default_result_accounts : {String, String}
        regime = Partiduo::Api::Core.settings(Partiduo::Api::Actor.system).tax_regime
        RESULT_ACCOUNTS[regime]? || RESULT_ACCOUNTS["fr"]
      rescue Partiduo::Api::NotFound
        RESULT_ACCOUNTS["fr"]
      end

      # Ligne proposée à partir d'un solde : le sens inverse du solde pour
      # la clôture, le même pour la réouverture.
      def self.line(balance : Balance, reverse : Bool, cards : Hash(Int64, Partiduo::Api::Cards::CardView)) : Api::ClosingLineView
        debit = balance.amount > 0
        debit = !debit if reverse
        card = balance.card_id.try { |id| cards[id]? }
        Api::ClosingLineView.new(
          account: balance.number, account_label: balance.label,
          card_id: card.try(&.id), card_code: card.try(&.code), card_name: card.try(&.name),
          card_disabled: card ? !card.enabled : false,
          side: debit ? Api::Side::Debit : Api::Side::Credit, amount: balance.amount.abs,
        )
      end

      # Fiches citées par les soldes (actives ou non).
      def self.cards(balances : Array(Balance)) : Hash(Int64, Partiduo::Api::Cards::CardView)
        result = {} of Int64 => Partiduo::Api::Cards::CardView
        balances.compact_map(&.card_id).uniq!.each do |id|
          result[id] = Partiduo::Api::Cards.card(Partiduo::Api::Actor.system, id)
        rescue Partiduo::Api::NotFound
          next
        end
        result
      end

      # Ligne du compte de résultat qui équilibre les lignes proposées ;
      # `nil` si elles sont déjà équilibrées.
      def self.result_line(lines : Array(Api::ClosingLineView), profit_account : String,
                           loss_account : String) : Api::ClosingLineView?
        debit = lines.select(&.side.debit?).sum(ZERO, &.amount)
        credit = lines.select(&.side.credit?).sum(ZERO, &.amount)
        difference = debit - credit
        return if difference.zero?
        # Plus de débit que de crédit : le résultat est au crédit (bénéfice).
        profit = difference > 0
        number = Chart.normalize(profit ? profit_account : loss_account)
        label = Account.filter(number: number).first.try(&.label.to_s) || ""
        Api::ClosingLineView.new(
          account: number, account_label: label, card_id: nil, card_code: nil, card_name: nil, card_disabled: false,
          side: profit ? Api::Side::Credit : Api::Side::Debit, amount: difference.abs, result: true,
        )
      end
    end
  end
end
