# SPDX-License-Identifier: AGPL-3.0-or-later

require "yaml"

module Partiduo
  module Accounting
    # Bilan et compte de résultat (`Acc_Bilan`, `Impress::parse_formula`) :
    # états intégrés des régimes FR et BE (`data/statements/<régime>.yml`),
    # rubriques calculées par `Formula` sur les sommes de la période ;
    # contrôle des comptes non repris et des soldes à contre-sens
    # (`Acc_Bilan::verify`). Service interne.
    module Statements
      alias Api = Partiduo::Api::Accounting

      ZERO = BigDecimal.new(0)

      SOURCES = {
        "fr" => {{ read_file("#{__DIR__}/../data/statements/fr.yml") }},
        "be" => {{ read_file("#{__DIR__}/../data/statements/be.yml") }},
      }

      record Rubric,
        code : String,
        style : String,
        level : Int32,
        gross : Formula::Parsed?,
        less : Formula::Parsed?,
        net : Formula::Parsed?,
        sum : Array(String)

      record Definition, covers : Array(String), rubrics : Array(Rubric), result_excludes : Array(String) = [] of String do
        def accounts : Array(Formula::AccountRef)
          rubrics.flat_map { |rubric| [rubric.gross, rubric.less, rubric.net].compact.flat_map(&.accounts) }
        end
      end

      @@definitions = {} of {String, Api::StatementKind} => Definition

      def self.regimes : Array(String)
        SOURCES.keys
      end

      def self.definition(regime : String, kind : Api::StatementKind) : Definition
        @@definitions[{regime, kind}] ||= begin
          yaml = YAML.parse(SOURCES[regime]? || raise Partiduo::Api::NotFound.new("statement", regime))
          node = yaml[kind.code]
          rubrics = node["rubrics"].as_a.map do |item|
            parse = ->(key : String) { item[key]?.try { |value| Formula.parse(value.as_s) } }
            Rubric.new(
              code: item["code"].as_s, style: item["style"]?.try(&.as_s) || "line",
              level: item["level"]?.try(&.as_i) || 2, gross: parse.call("gross"), less: parse.call("less"),
              net: parse.call("net"), sum: item["sum"]?.try(&.as_a.map(&.as_s)) || [] of String,
            )
          end
          excludes = yaml["result_excludes"]?.try(&.as_a.map(&.as_s)) || [] of String
          Definition.new(node["covers"].as_a.map(&.as_s), rubrics, excludes)
        end
      end

      # Montants calculés d'une rubrique.
      record Amounts, gross : BigDecimal?, less : BigDecimal?, net : BigDecimal?

      # Contexte d'évaluation : sommes de la période par compte et par fiche.
      class BalanceContext < Formula::Context
        @cache = {} of {String, Bool, Char?} => BigDecimal
        @card_ids = {} of String => Int64?
        @neutral : Set(Int64)?
        @variables : Proc(String, BigDecimal)?

        getter sums : Array(ReportData::Sum)

        def initialize(@sums : Array(ReportData::Sum))
        end

        def on_variable(&block : String -> BigDecimal) : Nil
          @variables = block
        end

        def account(pattern : String, prefix : Bool, mode : Char?) : BigDecimal
          @cache[{pattern, prefix, mode}] ||= compute(@sums.select { |sum| prefix ? sum.number.starts_with?(pattern) : sum.number == pattern }, mode)
        end

        def card(code : String, mode : Char?) : BigDecimal
          id = @card_ids.put_if_absent(code) do
            Partiduo::Api::Cards.card_by_code(Partiduo::Api::Actor.system, code).try(&.id)
          end
          return ZERO unless id
          compute(@sums.select(&.card_id.==(id)), mode)
        end

        def variable(name : String) : BigDecimal
          block = @variables || raise Formula::Error.new("variable", {"name" => name})
          block.call(name)
        end

        private def compute(sums : Array(ReportData::Sum), mode : Char?) : BigDecimal
          debit = sums.sum(ZERO, &.debit)
          credit = sums.sum(ZERO, &.credit)
          case mode
          when 'd' then debit
          when 'c' then credit
          when 's' then debit - credit
          when 'S' then credit - debit
          when 'D' then split(sums).sum(ZERO) { |net| Math.max(net, ZERO) }
          when 'C' then split(sums).sum(ZERO) { |net| Math.max(-net, ZERO) }
          else          (debit - credit).abs
          end
        end

        # Soldes compte par compte et, sur un compte collectif, tiers par
        # tiers. Les lignes d'une fiche Banque ou Article (journal
        # financier, ventes) restent au niveau du compte : un 512 mouvementé
        # avec et sans fiche n'a qu'un solde.
        private def split(sums : Array(ReportData::Sum)) : Array(BigDecimal)
          sums.group_by do |sum|
            id = sum.card_id
            {sum.number, id && !neutral.includes?(id) ? id : nil}
          end.values.map(&.sum(ZERO, &.movement))
        end

        private def neutral : Set(Int64)
          @neutral ||= if @sums.any?(&.card_id)
                         ReportData.neutral_card_ids
                       else
                         Set(Int64).new
                       end
        end
      end

      def self.round(value : BigDecimal) : BigDecimal
        value.round(2, mode: :ties_away)
      end

      # Calcule les rubriques d'un état sur les sommes données.
      def self.compute(definition : Definition, sums : Array(ReportData::Sum)) : Hash(String, Amounts)
        Evaluator.new(definition, BalanceContext.new(sums)).run
      end

      # Calcul des rubriques dans l'ordre, une rubrique citée (`$CODE`,
      # `sum`) étant calculée à la demande ; une dépendance circulaire est
      # refusée.
      class Evaluator
        @results = {} of String => Amounts
        @pending = Set(String).new
        @by_code : Hash(String, Rubric)

        def initialize(@definition : Definition, @context : BalanceContext)
          @by_code = @definition.rubrics.index_by(&.code)
          @context.on_variable { |name| amounts(name).net || ZERO }
        end

        def run : Hash(String, Amounts)
          @definition.rubrics.each { |rubric| amounts(rubric.code) }
          @results
        end

        def amounts(code : String) : Amounts
          if found = @results[code]?
            return found
          end
          rubric = @by_code[code]? || raise Formula::Error.new("variable", {"name" => code})
          raise Formula::Error.new("cycle", {"name" => code}) unless @pending.add?(code)
          @results[code] = compute(rubric)
        end

        private def compute(rubric : Rubric) : Amounts
          if !rubric.sum.empty?
            parts = rubric.sum.map { |part| amounts(part) }
            with_gross = parts.any?(&.gross)
            Amounts.new(
              with_gross ? parts.sum(ZERO) { |part| part.gross || part.net || ZERO } : nil,
              with_gross ? parts.sum(ZERO) { |part| part.less || ZERO } : nil,
              parts.sum(ZERO) { |part| part.net || ZERO },
            )
          elsif gross = rubric.gross
            value = Statements.round(gross.evaluate(@context))
            less = rubric.less.try { |formula| Statements.round(formula.evaluate(@context)) } || ZERO
            Amounts.new(value, less, value - less)
          elsif net = rubric.net
            Amounts.new(nil, nil, Statements.round(net.evaluate(@context)))
          else
            Amounts.new(nil, nil, nil)
          end
        end
      end

      def self.statement(query : Api::FinancialStatementQuery, regime : String, readable : Array(Int64)) : Api::FinancialStatementView
        definition = definition(regime, query.kind)
        from, to = ReportData.range(query.date_from, query.date_to)
        # Un bilan est une position à `date_to` : il part du début de
        # l'exercice, quelle que soit `date_from` (D-ED-013).
        if query.kind.balance_sheet?
          from = ReportData.fiscal_start(to) || from
          from = to if from > to
        end
        sums = ReportData.sums(readable, from, to, by_card: true, opening: false)
        current = compute(definition, sums)
        previous = nil
        previous_from = previous_to = nil
        if query.compare
          previous_to = to.shift(years: -1)
          previous_from = query.kind.balance_sheet? ? (ReportData.fiscal_start(previous_to) || from.shift(years: -1)) : from.shift(years: -1)
          previous = compute(definition, ReportData.sums(readable, previous_from, previous_to, by_card: true, opening: false))
        end
        lines = definition.rubrics.map do |rubric|
          amounts = current[rubric.code]
          Api::FinancialStatementLineView.new(
            code: rubric.code, label_key: "accounting.statements.#{regime}.#{query.kind.code}.#{rubric.code}",
            style: rubric.style, level: rubric.level, gross: amounts.gross, less: amounts.less, net: amounts.net,
            previous: previous.try(&.[rubric.code].net),
          )
        end
        accounts = by_account(sums)
        result = -accounts.select { |(number, _, _, _)| result_account?(definition, number) }.sum(ZERO, &.[3])
        difference = if query.kind.balance_sheet?
                       (current["total_assets"]?.try(&.net) || ZERO) - (current["total_liabilities"]?.try(&.net) || ZERO)
                     else
                       result - (current["net_result"]?.try(&.net) || ZERO)
                     end
        Api::FinancialStatementView.new(
          kind: query.kind, regime: regime, date_from: from, date_to: to, previous_from: previous_from,
          previous_to: previous_to, lines: lines, difference: difference, result: result,
          unmapped: unmapped(definition, accounts), anomalies: anomalies(definition, accounts),
          partial: partial?(readable),
        )
      end

      # Vrai si l'acteur ne voit pas tous les journaux (D-ED-013).
      def self.partial?(readable : Array(Int64)) : Bool
        visible = readable.to_set
        !Ledger.all.pluck(:id).all? { |row| visible.includes?(row.first.as(Int64)) }
      end

      # Compte de charges ou de produits compté dans le résultat : classes 6
      # et 7, hors comptes d'affectation (`result_excludes`, 69 et 79 en
      # BE).
      def self.result_account?(definition : Definition, number : String) : Bool
        (number.starts_with?('6') || number.starts_with?('7')) &&
          definition.result_excludes.none? { |prefix| number.starts_with?(prefix) }
      end

      # Soldes signés par compte : numéro, libellé, type, solde.
      private def self.by_account(sums : Array(ReportData::Sum)) : Array({String, String, String, BigDecimal})
        sums.group_by(&.number).map do |number, list|
          {number, list.first.label, list.first.kind, list.sum(ZERO, &.movement)}
        end.sort_by!(&.[0])
      end

      private def self.covered?(definition : Definition, number : String) : Bool
        definition.covers.any? { |prefix| number.starts_with?(prefix) }
      end

      # Comptes des classes de l'état, soldés non nuls, qu'aucune formule ne cite.
      private def self.unmapped(definition : Definition, accounts) : Array(Api::StatementAccountView)
        refs = definition.accounts
        accounts.compact_map do |(number, label, kind, balance)|
          next if balance.zero? || !covered?(definition, number)
          next if refs.any?(&.covers?(number))
          Api::StatementAccountView.new(number, label, ReportData.account_kind(kind), balance)
        end
      end

      # Soldes à contre-sens du type du compte (`Acc_Bilan::warning`).
      private def self.anomalies(definition : Definition, accounts) : Array(Api::StatementAccountView)
        accounts.compact_map do |(number, label, code, balance)|
          next if balance.zero? || !covered?(definition, number)
          kind = ReportData.account_kind(code) || next
          wrong = case kind
                  when .asset?, .expense?, .liability_contra?, .income_contra? then balance < 0
                  when .liability?, .income?, .asset_contra?, .expense_contra? then balance > 0
                  else                                                              false
                  end
          Api::StatementAccountView.new(number, label, kind, balance) if wrong
        end
      end
    end
  end
end
