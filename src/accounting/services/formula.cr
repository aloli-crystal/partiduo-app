# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Accounting
    # Formules des états (`Impress::parse_formula`, `form_definition`), sans
    # `eval` : une formule est analysée en arbre puis calculée en
    # `BigDecimal`.
    #
    # * `[606%]` : comptes dont le numéro commence par `606` ; `[606]` : le
    #   compte `606` seul. Suffixe de calcul : aucun = solde en valeur
    #   absolue (`all`), `-d` total débit, `-c` total crédit, `-s` débit −
    #   crédit (`signed`), `-S` crédit − débit (`cdsigned`) ; ajouts de
    #   Partiduo : `-D` somme des soldes débiteurs et `-C` somme des soldes
    #   créditeurs, compte par compte et, sur un compte collectif, tiers par
    #   tiers (un client créditeur passe au passif) ;
    # * `{QCODE}` : lignes d'une fiche, mêmes suffixes ;
    # * `$CODE` : valeur d'une autre rubrique (états intégrés) ;
    # * nombres, `+ - * /`, parenthèses, `abs(x)`, `round(x[, n])`,
    #   `min(a, b)`, `max(a, b)` ; une division par zéro vaut zéro
    #   (`remove_divide_zero`) ;
    # * `FROM=MM.AAAA` en fin de formule : le calcul part du premier jour de
    #   ce mois (`Impress::compute_periode`).
    #
    # Non repris : `{{…}}` (analytique, lot 5), opérateurs de comparaison et
    # conditions (`?:`), remplacés par `min` et `max`.
    module Formula
      MODES = {'d', 'c', 's', 'S', 'D', 'C'}

      # Longueur et profondeur d'imbrication maximales d'une formule : un
      # analyseur récursif sans borne ferait déborder la pile de la fibre,
      # ce qui arrête tout le processus.
      MAX_LENGTH = 1000
      MAX_DEPTH  =   50

      # Décimales admises par `round(x, n)`.
      MAX_ROUND_DIGITS = 10

      class Error < Exception
        getter key : String
        getter params : Hash(String, String)

        def initialize(@key : String, @params = {} of String => String)
          super("#{key} #{params}")
        end

        def field_error(path : String) : Partiduo::Api::FieldError
          Partiduo::Api::FieldError.new(path, "accounting.errors.formula.#{key}", params)
        end
      end

      # Source des montants d'une formule.
      abstract class Context
        abstract def account(pattern : String, prefix : Bool, mode : Char?) : BigDecimal
        abstract def card(code : String, mode : Char?) : BigDecimal
        abstract def variable(name : String) : BigDecimal
      end

      abstract class Node
        abstract def evaluate(context : Context) : BigDecimal
      end

      class Number < Node
        getter value : BigDecimal

        def initialize(@value : BigDecimal)
        end

        def evaluate(context : Context) : BigDecimal
          @value
        end
      end

      class Negate < Node
        getter operand : Node

        def initialize(@operand : Node)
        end

        def evaluate(context : Context) : BigDecimal
          -@operand.evaluate(context)
        end
      end

      class Binary < Node
        def initialize(@operator : Char, @left : Node, @right : Node)
        end

        def evaluate(context : Context) : BigDecimal
          left = @left.evaluate(context)
          right = @right.evaluate(context)
          case @operator
          when '+' then left + right
          when '-' then left - right
          when '*' then left * right
          else
            right.zero? ? BigDecimal.new(0) : left / right
          end
        end
      end

      class Call < Node
        def initialize(@name : String, @arguments : Array(Node))
        end

        def evaluate(context : Context) : BigDecimal
          values = @arguments.map(&.evaluate(context))
          case @name
          when "abs" then values[0].abs
          when "min" then values.min
          when "max" then values.max
          else
            digits = values[1]?.try { |value| Call.digits(value) } || 0
            values[0].round(digits, mode: :ties_away)
          end
        end

        # Nombre de décimales de `round` : entier de 0 à `MAX_ROUND_DIGITS`.
        def self.digits(value : BigDecimal) : Int32
          unless value == value.trunc && value >= 0 && value <= MAX_ROUND_DIGITS
            raise Error.new("round", {"max" => MAX_ROUND_DIGITS.to_s})
          end
          value.to_i
        end

        # Contrôle, dès l'analyse, un nombre de décimales constant.
        def check! : Nil
          return unless @name == "round"
          digits = @arguments[1]? || return
          constant = case digits
                     when Number then digits.value
                     when Negate then (operand = digits.operand).is_a?(Number) ? -operand.value : nil
                     end
          Call.digits(constant) if constant
        end
      end

      class AccountRef < Node
        getter pattern : String
        getter? prefix : Bool
        getter mode : Char?

        def initialize(@pattern : String, @prefix : Bool, @mode : Char?)
        end

        def evaluate(context : Context) : BigDecimal
          context.account(@pattern, @prefix, @mode)
        end

        def covers?(number : String) : Bool
          prefix? ? number.starts_with?(pattern) : number == pattern
        end
      end

      class CardRef < Node
        def initialize(@code : String, @mode : Char?)
        end

        def evaluate(context : Context) : BigDecimal
          context.card(@code, @mode)
        end
      end

      class Variable < Node
        getter name : String

        def initialize(@name : String)
        end

        def evaluate(context : Context) : BigDecimal
          context.variable(@name)
        end
      end

      # Formule analysée : arbre, comptes cités, date de départ imposée.
      class Parsed
        getter root : Node
        getter accounts : Array(AccountRef)
        getter variables : Array(String)
        getter from : Time?

        def initialize(@root, @accounts, @variables, @from)
        end

        def evaluate(context : Context) : BigDecimal
          @root.evaluate(context)
        end
      end

      FUNCTIONS = {"abs" => 1..1, "round" => 1..2, "min" => 2..2, "max" => 2..2}

      # Caractères interdits dans le code d'une fiche `{…}`.
      CARD_FORBIDDEN = /[\s$€µ£%+*\/\\!(),;&|"#'^<>=?\[\]]/

      def self.parse(text : String) : Parsed
        Parser.new(text).parse
      end

      # Erreur d'une formule (clé `accounting.errors.formula.<clé>`), `nil`
      # si elle est valide ; `variables` : les références `$CODE` sont
      # admises (états intégrés).
      def self.check(text : String, variables : Bool = false) : Error?
        parsed = parse(text)
        if !variables && (name = parsed.variables.first?)
          return Error.new("variable", {"name" => name})
        end
        nil
      rescue error : Error
        error
      end

      class Parser
        @accounts = [] of AccountRef
        @variables = [] of String
        @position = 0
        @depth = 0
        @from : Time? = nil

        def initialize(text : String)
          raise Error.new("too_long", {"max" => MAX_LENGTH.to_s}) if text.size > MAX_LENGTH
          @text = text.strip
          if match = @text.match(/\s*FROM\s*=\s*(\d{1,2})\.(\d{4})\s*\z/)
            month = match[1].to_i
            raise Error.new("from", {"value" => match[0].strip}) unless 1 <= month <= 12
            @from = Time.utc(match[2].to_i, month, 1)
            @text = @text[0, match.begin(0)]
          end
        end

        def parse : Parsed
          raise Error.new("empty") if @text.blank?
          root = expression
          skip_spaces
          syntax! if @position < @text.size
          Parsed.new(root, @accounts, @variables, @from)
        end

        private def expression : Node
          node = term
          loop do
            skip_spaces
            char = peek
            break unless char && (char == '+' || char == '-')
            @position += 1
            node = Binary.new(char, node, term)
          end
          node
        end

        private def term : Node
          node = factor
          loop do
            skip_spaces
            char = peek
            break unless char && (char == '*' || char == '/')
            @position += 1
            node = Binary.new(char, node, factor)
          end
          node
        end

        # Chaque facteur (parenthèse, signe, appel) descend d'un niveau ;
        # au-delà de `MAX_DEPTH`, la formule est refusée.
        private def factor : Node
          @depth += 1
          raise Error.new("depth", {"max" => MAX_DEPTH.to_s}) if @depth > MAX_DEPTH
          begin
            factor_body
          ensure
            @depth -= 1
          end
        end

        private def factor_body : Node
          skip_spaces
          char = peek || syntax!
          case char
          when '-'
            @position += 1
            Negate.new(factor)
          when '+'
            @position += 1
            factor
          when '('
            @position += 1
            node = expression
            expect(')')
            node
          when '['
            account_ref
          when '{'
            card_ref
          when '$'
            variable
          else
            if char.ascii_number? || char == '.'
              number
            elsif char.ascii_letter?
              call
            else
              syntax!
            end
          end
        end

        private def number : Node
          match = @text.match(/\G\d*(?:\.\d+)?/, @position) || syntax!
          syntax! if match[0].empty? || match[0] == "."
          @position += match[0].size
          Number.new(BigDecimal.new(match[0]))
        end

        private def call : Node
          match = @text.match(/\G[a-z]+/, @position) || syntax!
          name = match[0]
          range = FUNCTIONS[name]? || raise Error.new("function", {"name" => name})
          @position += name.size
          expect('(')
          arguments = [expression]
          loop do
            skip_spaces
            break unless peek == ','
            @position += 1
            arguments << expression
          end
          expect(')')
          raise Error.new("arguments", {"name" => name}) unless range.includes?(arguments.size)
          Call.new(name, arguments).tap(&.check!)
        end

        private def account_ref : Node
          match = @text.match(/\G\[([0-9A-Za-z]*)(%?)(?:-([cdsSDC]))?\]/, @position) || syntax!
          @position += match[0].size
          pattern = Chart.normalize(match[1])
          prefix = match[2] == "%"
          raise Error.new("account", {"value" => match[0]}) if pattern.empty? && !prefix
          ref = AccountRef.new(pattern, prefix, match[3]?.try(&.[0]))
          @accounts << ref
          ref
        end

        private def card_ref : Node
          raise Error.new("analytic") if @text[@position + 1]? == '{'
          match = @text.match(/\G\{([^{}]+)\}/, @position) || syntax!
          @position += match[0].size
          body = match[1]
          mode = nil
          if suffix = body.match(/-([cdsSDC])\z/)
            mode = suffix[1][0]
            body = body[0, body.size - 2]
          end
          # Opérateurs, blancs et caractères qu'ôte le quick code : refusés
          # (`{T*EL}` n'est pas `{TEL}`, `Impress::check_formula`).
          raise Error.new("card", {"value" => match[0]}) if body.matches?(CARD_FORBIDDEN)
          code = Partiduo::Api::Cards.format_code(body)
          raise Error.new("card", {"value" => match[0]}) if code.empty?
          CardRef.new(code, mode)
        end

        private def variable : Node
          match = @text.match(/\G\$([A-Za-z0-9_]+)/, @position) || syntax!
          @position += match[0].size
          @variables << match[1]
          Variable.new(match[1])
        end

        private def expect(char : Char) : Nil
          skip_spaces
          syntax! unless peek == char
          @position += 1
        end

        private def peek : Char?
          @text[@position]?
        end

        private def skip_spaces : Nil
          while (char = peek) && char.whitespace?
            @position += 1
          end
        end

        private def syntax! : NoReturn
          raise Error.new("syntax", {"position" => (@position + 1).to_s})
        end
      end
    end
  end
end
