# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Accounting
    # Règles du plan comptable, héritières de `Acc_Account::verify`,
    # `Acc_Plan_MTable::check` et des fonctions `comptaproc.format_account`,
    # `account_parent`, `find_pcm_type`, `get_pcm_tree`. Service interne.
    module Chart
      alias FieldError = Partiduo::Api::FieldError
      alias AccountKind = Partiduo::Api::Accounting::AccountKind

      MAX_NUMBER =  40
      MAX_LABEL  = 255

      ACCENTS = {'É' => 'E', 'È' => 'E', 'Ê' => 'E', 'Ë' => 'E', 'À' => 'A', 'Â' => 'A', 'Ä' => 'A',
                 'Ï' => 'I', 'Î' => 'I', 'Ü' => 'U', 'Û' => 'U', 'Ù' => 'U', 'Ö' => 'O', 'Ô' => 'O', 'Ç' => 'C'}
      REMOVED = " \t$€µ£%.+-/\\!(){},;_&|\"#'^<>*"
      VALID   = /\A[A-Z0-9]+\z/

      # `comptaproc.format_account` : majuscules, accents retirés, espaces et
      # ponctuation supprimés. Un caractère hors de `[A-Z0-9]` qui subsiste
      # rend le numéro invalide (le cœur refuse plutôt que de deviner).
      def self.normalize(number : String) : String
        String.build do |io|
          number.strip.upcase.each_char do |char|
            next if REMOVED.includes?(char)
            io << (ACCENTS[char]? || char)
          end
        end
      end

      record Values, number : String, label : String, parent : Account?, kind : String, direct_use : Bool

      # Normalise et contrôle une saisie ; `current` : le compte modifié.
      def self.validate(input : Partiduo::Api::Accounting::AccountInput,
                        current : Account? = nil) : {Values?, Array(FieldError)}
        errors = [] of FieldError
        number = normalize(input.number)
        label = input.label.strip
        number_errors(number, current, errors)
        label_errors(label, errors)
        parent = resolve_parent(input.parent, number, current, errors)

        return {nil, errors} unless errors.empty?
        kind = input.kind.try(&.code) || parent.try(&.kind!) || AccountKind::Context.code
        {Values.new(number, label, parent, kind, input.direct_use), errors}
      end

      private def self.number_errors(number : String, current : Account?, errors : Array(FieldError)) : Nil
        if number.empty?
          errors << FieldError.new("number", "accounting.errors.account.number.blank")
        elsif number.size > MAX_NUMBER
          errors << FieldError.new("number", "accounting.errors.account.number.too_long", {"max" => MAX_NUMBER.to_s})
        elsif !number.matches?(VALID)
          errors << FieldError.new("number", "accounting.errors.account.number.invalid")
        elsif Account.filter(number: number).exclude(id: current.try(&.pk)).exists?
          errors << FieldError.new("number", "accounting.errors.account.number.taken", {"number" => number})
        elsif current && current.number != number && EntryLine.filter(account_id: current.pk).exists?
          # `Acc_Plan_MTable::check` : « Poste utilisé », renumérotation refusée.
          errors << FieldError.new("number", "accounting.errors.account.number.in_use")
        end
      end

      private def self.label_errors(label : String, errors : Array(FieldError)) : Nil
        if label.empty?
          errors << FieldError.new("label", "accounting.errors.account.label.blank")
        elsif label.size > MAX_LABEL
          errors << FieldError.new("label", "accounting.errors.account.label.too_long", {"max" => MAX_LABEL.to_s})
        end
      end

      # Parent demandé (contrôlé), ou plus long préfixe existant.
      private def self.resolve_parent(requested : String?, number : String, current : Account?,
                                      errors : Array(FieldError)) : Account?
        wanted = requested.presence.try { |value| normalize(value) }
        if wanted.nil?
          return if number.empty?
          parent = closest_parent(number, current)
          errors << FieldError.new("parent", "accounting.errors.account.parent.required") if parent.nil? && number.size > 1
          return parent
        end

        parent = Account.filter(number: wanted).first
        if wanted == number || (current && parent && parent.pk == current.pk)
          errors << FieldError.new("parent", "accounting.errors.account.parent.self")
        elsif parent.nil?
          errors << FieldError.new("parent", "accounting.errors.account.parent.not_found", {"number" => wanted})
        elsif current && descendant?(parent, current)
          errors << FieldError.new("parent", "accounting.errors.account.parent.cycle")
        else
          return parent
        end
        nil
      end

      # `comptaproc.account_parent` : le plus long préfixe existant du numéro
      # (le compte lui-même exclu).
      def self.closest_parent(number : String, current : Account? = nil) : Account?
        prefixes = (1...number.size).map { |size| number[0, size] }
        return if prefixes.empty?
        Account.filter(number__in: prefixes).exclude(id: current.try(&.pk)).to_a.max_by?(&.number!.size)
      end

      # Vrai si `candidate` est `account` ou l'un de ses descendants.
      def self.descendant?(candidate : Account, account : Account) : Bool
        subtree_ids(account.pk!.as(Int64)).includes?(candidate.pk!.as(Int64))
      end

      def self.assign(account : Account, values : Values) : Account
        account.number = values.number
        account.label = values.label
        account.parent = values.parent
        account.kind = values.kind
        account.direct_use = values.direct_use
        account
      end

      # Motifs de refus d'effacement (`Acc_Account::delete` : compte utilisé
      # ou parent d'un autre).
      def self.delete_errors(account : Account) : Array(FieldError)
        errors = [] of FieldError
        id = account.pk!
        if Account.filter(parent_id: id).exists?
          errors << FieldError.base("accounting.errors.account.has_children")
        end
        if CardAccount.filter(account_id: id).exists? || CardCategoryAccount.filter(base_account_id: id).exists? ||
           Ledger.filter(default_account_id: id).exists? || DefaultAccount.filter(account_id: id).exists? ||
           EntryLine.filter(account_id: id).exists? || Matching.filter(account_id: id).exists?
          errors << FieldError.base("accounting.errors.account.in_use")
        end
        errors
      end

      # --- Arbre (SQL récursif) --------------------------------------------------

      TREE_SQL = <<-SQL
        WITH RECURSIVE tree(id, depth, path) AS (
          SELECT a.id, 0, ARRAY[a.number::text]
          FROM accounting_account a
          WHERE %{root}
          UNION ALL
          SELECT c.id, t.depth + 1, t.path || c.number::text
          FROM accounting_account c
          JOIN tree t ON c.parent_id = t.id
        )
        SELECT a.id, a.number, a.label, a.parent_id, p.number, a.kind, a.direct_use, t.depth,
               (SELECT count(*) FROM accounting_account k WHERE k.parent_id = a.id)::int
        FROM tree t
        JOIN accounting_account a ON a.id = t.id
        LEFT JOIN accounting_account p ON p.id = a.parent_id
        ORDER BY t.path
        SQL

      record TreeRow, id : Int64, number : String, label : String, parent_id : Int64?, parent_number : String?,
        kind : String, direct_use : Bool, depth : Int32, children_count : Int32

      # Tout le plan (racines et descendants), ou le sous-arbre d'un compte
      # (`get_pcm_tree`, le compte compris à la profondeur 0), dans l'ordre de
      # l'arbre : chaque compte suivi de ses descendants, frères par numéro.
      def self.tree(root_id : Int64? = nil) : Array(TreeRow)
        sql = TREE_SQL % {root: root_id.nil? ? "a.parent_id IS NULL" : "a.id = $1"}
        args = root_id.nil? ? [] of Int64 : [root_id]
        Marten::DB::Connection.default.open do |db|
          db.query_all(sql, args: args) do |row|
            TreeRow.new(
              id: row.read(Int64), number: row.read(String), label: row.read(String),
              parent_id: row.read(Int64?), parent_number: row.read(String?), kind: row.read(String),
              direct_use: row.read(Bool), depth: row.read(Int32), children_count: row.read(Int32),
            )
          end
        end
      end

      def self.subtree_ids(root_id : Int64) : Set(Int64)
        tree(root_id).map(&.id).to_set
      end
    end
  end
end
