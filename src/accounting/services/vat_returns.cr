# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Accounting
    # Déclarations de TVA (lot 4) : mouvements de TVA relus dans les
    # écritures (successeur des requêtes de `Tva_Amount` sur `quant_sold` et
    # `quant_purchase`, et de l'exigibilité de `Tax_Summary`), calcul par les
    # règles et les formulaires du socle (`Partiduo::Vat::Returns`,
    # `Vat::Be`, `Vat::Fr`), relevés par client, écriture de liquidation
    # (`Ext_Tva::propose_form`). Service interne.
    module VatReturns
      alias Api = Partiduo::Api::Accounting
      alias FieldError = Partiduo::Api::FieldError
      alias Movement = Partiduo::Vat::Returns::Movement
      alias Rule = Partiduo::Vat::Returns::Rule
      alias Returns = Partiduo::Vat::Returns

      ZERO = BigDecimal.new(0)

      # Compte de la créance de TVA par défaut (`CRTVA`) : « TVA à
      # récupérer » du PCMN, « Crédit de TVA à reporter » du PCG.
      RECEIVABLE_ACCOUNTS = {"be" => "411", "fr" => "44567"}

      # Préfixe de la référence (`accounting_entry.source`) d'une écriture de
      # liquidation : `vat_return:<id>`.
      SOURCE_PREFIX = "vat_return:"

      # Paramètres d'une déclaration, contrôlés.
      record Params,
        form : String,
        regime : String,
        year : Int32,
        periodicity : String,
        number : Int32,
        date_from : Time,
        date_to : Time,
        exigibility : String,
        threshold : BigDecimal?

      # Déclaration calculée : montants calculés par case (totaux compris),
      # lignes des relevés, apports des règles, mouvements retenus ; `raw` :
      # les mêmes montants au centime, avant l'arrondi à l'euro des
      # formulaires français (égaux à `computed` ailleurs).
      record Computation,
        params : Params,
        computed : Hash(String, BigDecimal),
        lines : Array(Returns::ListingLine),
        contributions : Array(Returns::Contribution),
        movements : Array(Movement),
        raw : Hash(String, BigDecimal) = {} of String => BigDecimal

      # --- Paramètres --------------------------------------------------------------

      def self.params(input : Api::VatReturnInput) : {Params?, Array(FieldError)}
        errors = [] of FieldError
        form = input.form.strip.downcase
        unless Returns::FORMS.includes?(form)
          errors << FieldError.new("form", "accounting.errors.vat_return.form.invalid", {"value" => input.form})
          return {nil, errors}
        end
        periodicity = input.periodicity.strip.downcase
        exigibility = input.exigibility.strip.downcase
        check_choices(input, form, periodicity, exigibility, errors)
        return {nil, errors} unless errors.empty?

        bounds = period_bounds(input, form, periodicity, errors)
        return {nil, errors} if bounds.nil?
        number = periodicity == "year" ? 1 : input.number
        threshold = form == "be_client_listing" ? (input.threshold || Returns::DEFAULT_THRESHOLD) : nil
        {Params.new(form, Returns.regime(form), input.year, periodicity, number, bounds[0], bounds[1], exigibility,
          threshold), errors}
      end

      # Régime du dossier, périodicité du formulaire, exigibilité, année,
      # seuil.
      private def self.check_choices(input : Api::VatReturnInput, form : String, periodicity : String,
                                     exigibility : String, errors : Array(FieldError)) : Nil
        if (instance = instance_regime) && instance != Returns.regime(form)
          errors << FieldError.new("form", "accounting.errors.vat_return.form.regime", {"regime" => instance})
        end
        unless Returns.periodicities(form).includes?(periodicity)
          errors << FieldError.new("periodicity", "accounting.errors.vat_return.periodicity.invalid",
            {"value" => input.periodicity})
        end
        unless Returns::EXIGIBILITIES.includes?(exigibility)
          errors << FieldError.new("exigibility", "accounting.errors.vat_return.exigibility.invalid",
            {"value" => input.exigibility})
        end
        unless 1900 <= input.year <= 9999
          errors << FieldError.new("year", "accounting.errors.vat_return.year.invalid", {"value" => input.year.to_s})
        end
        if (threshold = input.threshold) && threshold < 0
          errors << FieldError.new("threshold", "accounting.errors.vat_return.threshold.negative")
        end
      end

      # Formulaire dont les bornes peuvent différer de la période
      # (exercice décalé d'une CA12) ; ailleurs, le fichier déposé reprend
      # le mois, le trimestre ou l'année, et non des bornes libres.
      FREE_BOUNDS_FORMS = %w[fr_ca12]

      # Bornes : celles données (CA12), sinon celles de la période.
      private def self.period_bounds(input : Api::VatReturnInput, form : String, periodicity : String,
                                     errors : Array(FieldError)) : {Time, Time}?
        bounds = Returns.period(periodicity, input.year, input.number)
        if bounds.nil?
          errors << FieldError.new("number", "accounting.errors.vat_return.number.invalid", {"value" => input.number.to_s})
          return
        end
        from = input.date_from.try { |day| Posting.day(day) } || bounds[0]
        to = input.date_to.try { |day| Posting.day(day) } || bounds[1]
        if !FREE_BOUNDS_FORMS.includes?(form) && {from, to} != bounds
          errors << FieldError.new(input.date_from ? "date_from" : "date_to", "accounting.errors.vat_return.dates.not_allowed")
          return
        end
        if from > to
          errors << FieldError.new("date_to", "accounting.errors.vat_return.dates.order")
          return
        end
        {from, to}
      end

      def self.stored_params(record : Partiduo::Vat::Return) : Params
        Params.new(record.form.to_s, record.regime.to_s, record.year!.to_i32, record.periodicity.to_s,
          record.period_number!.to_i32, record.date_from!, record.date_to!, record.exigibility.to_s, record.threshold)
      end

      # Régime du dossier (`be`, `fr`), ou nil s'il n'est pas encore
      # provisionné.
      def self.instance_regime : String?
        Partiduo::Api::Core.settings(Partiduo::Api::Actor.system).tax_regime.presence
      rescue Partiduo::Api::NotFound
        nil
      end

      # --- Calcul --------------------------------------------------------------------

      def self.compute(params : Params) : Computation
        rules = rules(params.regime)
        movements = movements(params.date_from, params.date_to, params.exigibility, rules)
        case params.form
        when "be_client_listing"
          listing_rules = rules.select(&.box.in?("listing", "listing_vat"))
          lines = client_listing(listing_rules, movements, params.threshold || Returns::DEFAULT_THRESHOLD)
          Computation.new(params, {} of String => BigDecimal, lines, Returns.evaluate(listing_rules, movements)[1], movements)
        when "be_intra_listing"
          intra_rules = rules.select(&.box.starts_with?("intra_"))
          lines = intra_listing(intra_rules, movements)
          Computation.new(params, {} of String => BigDecimal, lines, Returns.evaluate(intra_rules, movements)[1], movements)
        else
          boxes = Returns.boxes(params.form)
          ruled = boxes.select(&.ruled).map(&.code).to_set
          ruled_rules = rules.select { |rule| ruled.includes?(rule.box) }
          decimals = Returns.decimals(params.form)
          amounts, contributions = Returns.evaluate(ruled_rules, movements, decimals)
          computed = boxes.to_h { |box| {box.code, amounts[box.code]? || ZERO} }
          annex = params.regime == "fr" ? Partiduo::Vat::Fr.annex(ruled_rules, movements, decimals) : [] of {Int64?, BigDecimal, BigDecimal}
          Partiduo::Vat::Fr.report_annex!(computed, annex)
          Returns.totals!(params.form, computed)
          raw = computed
          unless decimals == 2
            cents = Returns.evaluate(ruled_rules, movements, 2)[0]
            raw = boxes.to_h { |box| {box.code, cents[box.code]? || ZERO} }
            Returns.totals!(params.form, raw)
          end
          Computation.new(params, computed, annex_lines(annex), contributions, movements, raw)
        end
      end

      # Montants déclarés : calculés, corrigés par `adjustments`, totaux
      # recalculés.
      def self.declared(form : String, computed : Hash(String, BigDecimal), adjustments : Hash(String, BigDecimal)) : Hash(String, BigDecimal)
        amounts = computed.dup
        adjustments.each { |code, value| amounts[code] = value }
        Returns.totals!(form, amounts)
        amounts
      end

      # Lignes de l'annexe 3310-A : taux (code et libellé), base, taxe.
      private def self.annex_lines(annex : Array({Int64?, BigDecimal, BigDecimal})) : Array(Returns::ListingLine)
        return [] of Returns::ListingLine if annex.empty?
        rates = Partiduo::Vat::Rate.filter(id__in: annex.compact_map(&.[0])).to_a.to_h { |rate| {rate.id!.to_i64, rate} }
        lines = annex.map do |(rate_id, base, tax)|
          rate = rate_id.try { |id| rates[id]? }
          label = rate ? "#{rate.label} (#{percent(rate.rate!)} %)" : ""
          Returns::ListingLine.new(nil, nil, label, rate.try(&.code).to_s, Partiduo::Vat::Fr::ANNEX_CODE, base, tax)
        end
        lines.sort_by(&.vat_number)
      end

      # Taux en pourcentage sans zéros inutiles : `13`, `2.1`.
      private def self.percent(value : BigDecimal) : String
        text = value.to_s
        text.includes?('.') ? text.rstrip('0').rstrip('.') : text
      end

      private def self.client_listing(rules : Array(Rule), movements : Array(Movement), threshold : BigDecimal) : Array(Returns::ListingLine)
        totals = Returns.by_card(rules, movements, "listing", "listing_vat")
        cards = cards(totals.keys)
        rows = totals.compact_map do |card_id, (amount, vat)|
          card = cards[card_id]? || next
          number = normalized_vat(card.vat_number)
          next unless number.starts_with?("BE")
          next if amount < threshold
          Returns::ListingLine.new(card_id, card.code, card.name, number, "", amount, vat)
        end
        rows.sort_by { |row| {row.vat_number, row.card_id || 0_i64} }
      end

      private def self.intra_listing(rules : Array(Rule), movements : Array(Movement)) : Array(Returns::ListingLine)
        totals = Returns::LISTING_CODES.compact_map do |code|
          box = "intra_#{code.downcase}"
          {code, Returns.by_card(rules, movements, box)} if rules.any?(&.box.==(box))
        end
        cards = cards(totals.flat_map { |(_, by_card)| by_card.keys }.uniq!)
        rows = [] of Returns::ListingLine
        totals.each do |(code, by_card)|
          by_card.each do |card_id, (amount, _)|
            next if amount.zero?
            card = cards[card_id]? || next
            number = normalized_vat(card.vat_number)
            next if number.empty? || number.starts_with?("BE")
            rows << Returns::ListingLine.new(card_id, card.code, card.name, number, code, amount, ZERO)
          end
        end
        rows.sort_by { |row| {row.vat_number, row.code} }
      end

      # Fiches des tiers `ids`, par identifiant : clients chargés par pages
      # (une requête pour mille fiches plutôt qu'une par client), les autres
      # fiches une à une.
      private def self.cards(ids : Array(Int64)) : Hash(Int64, Partiduo::Api::Cards::CardView)
        return {} of Int64 => Partiduo::Api::Cards::CardView if ids.empty?
        loaded = ReportData.cards(%w[customer])
        result = {} of Int64 => Partiduo::Api::Cards::CardView
        ids.each do |id|
          if card = loaded[id]? || card(id)
            result[id] = card
          end
        end
        result
      end

      private def self.card(id : Int64) : Partiduo::Api::Cards::CardView?
        Partiduo::Api::Cards.card(Partiduo::Api::Actor.system, id)
      rescue Partiduo::Api::NotFound
        nil
      end

      def self.normalized_vat(number : String) : String
        number.upcase.gsub(/[^A-Z0-9]/, "")
      end

      # --- Mouvements ----------------------------------------------------------------

      # Ligne relue : écriture, dates, journal, compte, taux, rôle, sens,
      # montant, tiers de l'écriture, exigibilité et comptes du taux.
      private record Row,
        entry_id : Int64,
        date : Time,
        ledger_id : Int64,
        ledger_kind : String,
        account_id : Int64,
        account : String,
        vat_rate_id : Int64?,
        vat_role : String,
        debit : Bool,
        amount : BigDecimal,
        card_id : Int64?,
        reverse_charge : Bool,
        sale_on_payment : Bool,
        purchase_on_payment : Bool,
        deductible_account_id : Int64?,
        collected_account_id : Int64?

      # Mouvements de TVA exigibles de `from` à `to` : lignes hors taxe et
      # de TVA des achats et des ventes, datées de l'opération ou des
      # encaissements selon l'exigibilité ; lignes des journaux d'opérations
      # diverses et financiers pour les règles de solde (hors écritures de
      # liquidation).
      #
      # Exigibilité à l'encaissement : au prorata des sommes encaissées
      # (`Collections`, DECISIONS D-R5-005) ; la part d'une période est la
      # part cumulée à sa fin moins la part cumulée avant son début, chaque
      # montant arrondi au centime, de sorte que les périodes successives
      # totalisent exactement l'opération une fois payée.
      def self.movements(from : Time, to : Time, exigibility : String, rules : Array(Rule)) : Array(Movement)
        movements = [] of Movement
        rows = rows(from, to)
        schedules = Collections.schedules(rows.select { |row| on_payment?(row, exigibility) }.map(&.entry_id).uniq!)
        before = from - 1.day
        rows.group_by { |row| {row.entry_id, row.vat_rate_id} }.each_value do |group|
          first = group.first
          if on_payment?(first, exigibility)
            schedule = schedules[first.entry_id]? || next
            date = schedule.last_date(from, to) || next
            share = ->(amount : BigDecimal) { schedule.part(amount, before, to) }
          else
            next if first.date < from || first.date > to
            date = first.date
            share = ->(amount : BigDecimal) { amount }
          end
          bases = group.select(&.vat_role.==("base")).map { |row| {row, share.call(signed_base(row))} }
          group.each do |row|
            case row.vat_role
            when "base"
              movements << movement(row, date, "base", share.call(signed_base(row)), row.account)
            when "tax"
              source = tax_source(row)
              amount = row.debit ? row.amount : -row.amount
              amount = -amount if source == "collected"
              allocate(row, date, source, share.call(amount), bases, movements)
            end
          end
        end
        balance_rules = rules.select(&.source.==("balance"))
        movements.concat(balance_movements(from, to, balance_rules)) unless balance_rules.empty?
        movements
      end

      private def self.movement(row : Row, date : Time, source : String, amount : BigDecimal, account : String,
                                tax_account : String? = nil) : Movement
        Movement.new(entry_id: row.entry_id, date: date, ledger_id: row.ledger_id, ledger_kind: row.ledger_kind,
          account: account, vat_rate_id: row.vat_rate_id, source: source, amount: amount, card_id: row.card_id,
          tax_account: tax_account)
      end

      # Hors taxe dans le sens de l'opération : débit à l'achat, crédit à la
      # vente ; un avoir est négatif.
      private def self.signed_base(row : Row) : BigDecimal
        debit_positive = row.ledger_kind != "sale"
        row.debit == debit_positive ? row.amount : -row.amount
      end

      # TVA déductible ou due : d'après les comptes du taux, sinon d'après
      # le journal (achat : déductible, vente : due), sinon le sens.
      private def self.tax_source(row : Row) : String
        return "deductible" if row.account_id == row.deductible_account_id && row.account_id != row.collected_account_id
        return "collected" if row.account_id == row.collected_account_id && row.account_id != row.deductible_account_id
        unless row.reverse_charge
          return "deductible" if row.ledger_kind == "purchase"
          return "collected" if row.ledger_kind == "sale"
        end
        row.debit ? "deductible" : "collected"
      end

      # TVA d'une ligne répartie sur les lignes hors taxe du même taux, au
      # prorata (le compte d'une règle est celui de la ligne hors taxe,
      # comme `quant_purchase.j_id`) ; le reste d'arrondi va à la dernière.
      private def self.allocate(row : Row, date : Time, source : String, amount : BigDecimal,
                                bases : Array({Row, BigDecimal}), movements : Array(Movement)) : Nil
        total = bases.sum(ZERO) { |(_, base)| base }
        if bases.empty? || total.zero?
          movements << movement(row, date, source, amount, "", row.account)
          return
        end
        remaining = amount
        bases.each_with_index do |(base_row, base), index|
          part = index == bases.size - 1 ? remaining : (amount * base / total).round(2, mode: :ties_away)
          remaining -= part
          movements << movement(row, date, source, part, base_row.account, row.account)
        end
      end

      # Taux exigible à l'encaissement pour cette ligne : par la déclaration
      # (`payment` : tous les achats et ventes ; `operation` : aucun), sinon
      # par le taux (`sale_on_payment`, `purchase_on_payment`).
      private def self.on_payment?(row : Row, exigibility : String) : Bool
        case exigibility
        when "operation" then false
        when "payment"   then row.ledger_kind.in?("sale", "purchase")
        else
          (row.ledger_kind == "sale" && row.sale_on_payment) ||
            (row.ledger_kind == "purchase" && row.purchase_on_payment)
        end
      end

      # Lignes hors taxe et de TVA des écritures datées jusqu'à `to` : celles
      # de la période, et celles d'avant la période lettrées avec une
      # écriture de la période (seules à pouvoir y devenir exigibles à
      # l'encaissement) ; le tiers n'est lu que pour elles, sans parcourir
      # tout l'historique.
      private def self.rows(from : Time, to : Time) : Array(Row)
        sql = <<-SQL
          WITH candidates AS (
            SELECT DISTINCT x.entry_id
            FROM accounting_entry_line x
            JOIN accounting_entry e ON e.id = x.entry_id
            WHERE x.vat_role IS NOT NULL AND e.date >= $1::date AND e.date <= $2::date
            UNION
            SELECT DISTINCT x.entry_id
            FROM accounting_entry_line x
            JOIN accounting_entry e ON e.id = x.entry_id
            JOIN accounting_ledger l ON l.id = e.ledger_id
            JOIN accounting_entry_line y ON y.matching_id = x.matching_id AND y.entry_id <> x.entry_id
            JOIN accounting_entry e2 ON e2.id = y.entry_id
            WHERE x.matching_id IS NOT NULL AND l.kind IN ('sale', 'purchase') AND e.date < $1::date
              AND e2.date >= $1::date AND e2.date <= $2::date
              AND EXISTS (SELECT 1 FROM accounting_entry_line v WHERE v.entry_id = x.entry_id AND v.vat_role IS NOT NULL)
          ),
          third AS (
            SELECT DISTINCT ON (x.entry_id) x.entry_id, x.card_id
            FROM accounting_entry_line x
            JOIN candidates c ON c.entry_id = x.entry_id
            JOIN accounting_entry e ON e.id = x.entry_id
            JOIN accounting_ledger l ON l.id = e.ledger_id
            WHERE l.kind IN ('sale', 'purchase') AND x.vat_role IS NULL AND x.card_id IS NOT NULL
            ORDER BY x.entry_id, x.position DESC
          )
          SELECT x.entry_id, e.date, e.ledger_id, l.kind, a.id, a.number, x.vat_rate_id, x.vat_role,
                 x.side = 'debit', x.amount, t.card_id, COALESCE(r.reverse_charge, false),
                 COALESCE(r.sale_on_payment, false), COALESCE(r.purchase_on_payment, false),
                 va.deductible_account_id, va.collected_account_id
          FROM accounting_entry_line x
          JOIN candidates c ON c.entry_id = x.entry_id
          JOIN accounting_entry e ON e.id = x.entry_id
          JOIN accounting_ledger l ON l.id = e.ledger_id
          JOIN accounting_account a ON a.id = x.account_id
          LEFT JOIN vat_rate r ON r.id = x.vat_rate_id
          LEFT JOIN accounting_vat_rate_account va ON va.vat_rate_id = x.vat_rate_id
          LEFT JOIN third t ON t.entry_id = x.entry_id
          WHERE x.vat_role IS NOT NULL AND e.date <= $2::date
          ORDER BY x.entry_id, x.position
          SQL
        Marten::DB::Connection.default.open do |db|
          db.query_all(sql, args: [from, to] of ::DB::Any) do |result_set|
            Row.new(
              entry_id: result_set.read(Int64), date: result_set.read(Time), ledger_id: result_set.read(Int64),
              ledger_kind: result_set.read(String), account_id: result_set.read(Int64), account: result_set.read(String),
              vat_rate_id: result_set.read(Int64?), vat_role: result_set.read(String), debit: result_set.read(Bool),
              amount: result_set.read(BigDecimal), card_id: result_set.read(Int64?), reverse_charge: result_set.read(Bool),
              sale_on_payment: result_set.read(Bool), purchase_on_payment: result_set.read(Bool),
              deductible_account_id: result_set.read(Int64?), collected_account_id: result_set.read(Int64?),
            )
          end
        end
      end

      # Lignes des journaux d'opérations diverses et financiers de la
      # période, sur les comptes des règles de solde (`get_solde`).
      private def self.balance_movements(from : Time, to : Time, rules : Array(Rule)) : Array(Movement)
        args = [from, to, SOURCE_PREFIX] of ::DB::Any
        prefixes = rules.flat_map(&.accounts)
        clauses = [] of String
        unless rules.any?(&.accounts.empty?)
          conditions = prefixes.uniq.map do |prefix|
            args << "#{prefix}%"
            "a.number LIKE $#{args.size}"
          end
          clauses << "(#{conditions.join(" OR ")})" unless conditions.empty?
        end
        sql = <<-SQL
          SELECT x.entry_id, e.date, e.ledger_id, l.kind, a.number,
                 CASE WHEN x.side = 'debit' THEN x.amount ELSE -x.amount END, x.card_id
          FROM accounting_entry_line x
          JOIN accounting_entry e ON e.id = x.entry_id
          JOIN accounting_ledger l ON l.id = e.ledger_id
          JOIN accounting_account a ON a.id = x.account_id
          WHERE l.kind IN ('misc', 'financial') AND e.date >= $1::date AND e.date <= $2::date
            AND NOT starts_with(COALESCE(e.source, ''), $3)
            #{clauses.map { |clause| "AND #{clause}" }.join(" ")}
          ORDER BY x.entry_id, x.position
          SQL
        Marten::DB::Connection.default.open do |db|
          db.query_all(sql, args: args) do |result_set|
            Movement.new(entry_id: result_set.read(Int64), date: result_set.read(Time), ledger_id: result_set.read(Int64),
              ledger_kind: result_set.read(String), account: result_set.read(String), vat_rate_id: nil, source: "balance",
              amount: result_set.read(BigDecimal), card_id: result_set.read(Int64?))
          end
        end
      end

      # --- Règles --------------------------------------------------------------------

      # Règles en vigueur d'un régime : celles du paramétrage enregistré, ou,
      # s'il est vide, celles par défaut (taux absents ignorés).
      def self.rules(regime : String) : Array(Rule)
        stored = Partiduo::Vat::BoxRule.filter(regime: regime).order(:box, :position).to_a
        return stored.map { |row| rule(row) } unless stored.empty?
        default_rules(regime)
      end

      def self.default_rules(regime : String) : Array(Rule)
        rates = Partiduo::Vat::Rate.all.to_a.to_h { |rate| {rate.code.to_s, rate.id!.to_i64} }
        positions = Hash(String, Int32).new(0)
        Returns.default_rules(regime).flat_map do |default|
          ids = default.rates.try { |codes| codes.compact_map { |code| rates[code]? } }
          next [] of Rule if ids && ids.empty?
          (ids || [nil] of Int64?).map do |rate_id|
            positions[default.box] += 1
            Rule.new(box: default.box, position: positions[default.box], vat_rate_id: rate_id,
              ledger_kind: default.ledger_kind, ledger_id: nil, accounts: Returns.prefixes(default.accounts),
              excluded_accounts: Returns.prefixes(default.excluded_accounts), source: default.source,
              sign: default.sign, operation: default.operation)
          end
        end
      end

      def self.rule(row : Partiduo::Vat::BoxRule) : Rule
        Rule.new(box: row.box.to_s, position: row.position!.to_i32, vat_rate_id: row.vat_rate_id.try(&.as(Int).to_i64),
          ledger_kind: row.ledger_kind, ledger_id: row.ledger_id.try(&.to_i64),
          accounts: Returns.prefixes(row.accounts.to_s), excluded_accounts: Returns.prefixes(row.excluded_accounts.to_s),
          source: row.source.to_s, sign: row.sign.to_s, operation: row.operation.to_s)
      end

      # Enregistre les règles par défaut quand le paramétrage est encore vide
      # (première modification).
      def self.materialize!(regime : String) : Nil
        return if Partiduo::Vat::BoxRule.filter(regime: regime).exists?
        default_rules(regime).each { |rule| store!(regime, rule) }
      end

      def self.store!(regime : String, rule : Rule) : Nil
        Partiduo::Vat::BoxRule.create!(
          regime: regime, box: rule.box, position: rule.position, vat_rate_id: rule.vat_rate_id,
          ledger_kind: rule.ledger_kind, ledger_id: rule.ledger_id, accounts: rule.accounts.join(","),
          excluded_accounts: rule.excluded_accounts.join(","), source: rule.source, sign: rule.sign,
          operation: rule.operation,
        )
      end

      # Règle saisie, contrôlée ; `path` : préfixe des chemins d'erreur.
      def self.rule_from(regime : String, box : String, position : Int32, input : Api::VatBoxRuleInput, path : String,
                         errors : Array(FieldError)) : Rule?
        count = errors.size
        source = choice(input.source, Returns::SOURCES, "#{path}.source", "source", errors)
        sign = choice(input.sign, Returns::SIGNS, "#{path}.sign", "sign", errors)
        operation = choice(input.operation, Returns::OPERATIONS, "#{path}.operation", "operation", errors)
        kind = input.ledger_kind.try(&.strip.downcase.presence)
        if kind && !Returns::LEDGER_KINDS.includes?(kind)
          errors << FieldError.new("#{path}.ledger_kind", "accounting.errors.vat_rule.ledger_kind.invalid", {"value" => kind})
        end
        ledger_id, kind = rule_ledger(input.ledger_code, kind, path, errors)
        rate_id = rule_rate(input.vat_rate_code, path, errors)
        if source == "balance"
          if kind.nil? || !kind.in?("misc", "financial")
            errors << FieldError.new("#{path}.ledger_kind", "accounting.errors.vat_rule.ledger_kind.balance")
          end
          errors << FieldError.new("#{path}.vat_rate_code", "accounting.errors.vat_rule.vat_rate_code.balance") if rate_id
        elsif kind && !kind.in?("purchase", "sale")
          errors << FieldError.new("#{path}.ledger_kind", "accounting.errors.vat_rule.ledger_kind.document")
        end
        accounts = rule_prefixes(input.accounts, path, errors)
        excluded = rule_prefixes(input.excluded_accounts, path, errors)
        return unless errors.size == count
        Rule.new(box: box, position: position, vat_rate_id: rate_id, ledger_kind: kind, ledger_id: ledger_id,
          accounts: accounts, excluded_accounts: excluded, source: source, sign: sign, operation: operation)
      end

      private def self.choice(value : String, allowed : Array(String), path : String, name : String,
                              errors : Array(FieldError)) : String
        normalized = value.strip.downcase
        unless allowed.includes?(normalized)
          errors << FieldError.new(path, "accounting.errors.vat_rule.#{name}.invalid", {"value" => value})
        end
        normalized
      end

      # Journal d'une règle et nature retenue (celle du journal à défaut).
      private def self.rule_ledger(code : String?, kind : String?, path : String,
                                   errors : Array(FieldError)) : {Int64?, String?}
        code = code.try(&.strip.upcase.presence)
        return {nil, kind} if code.nil?
        ledger = Ledger.filter(code: code).first
        if ledger.nil?
          errors << FieldError.new("#{path}.ledger_code", "accounting.errors.vat_rule.ledger_code.not_found", {"code" => code})
          return {nil, kind}
        end
        ledger_kind = ledger.kind.to_s
        if kind && kind != ledger_kind
          errors << FieldError.new("#{path}.ledger_code", "accounting.errors.vat_rule.ledger_code.kind", {"code" => code})
        end
        {ledger.pk!.as(Int64), kind || ledger_kind}
      end

      private def self.rule_rate(code : String?, path : String, errors : Array(FieldError)) : Int64?
        code = code.try(&.strip.upcase.presence)
        return if code.nil?
        rate = Partiduo::Vat::Rate.filter(code: code).first
        return rate.id!.to_i64 if rate
        errors << FieldError.new("#{path}.vat_rate_code", "accounting.errors.vat_rule.vat_rate_code.not_found", {"code" => code})
        nil
      end

      private def self.rule_prefixes(text : String, path : String, errors : Array(FieldError)) : Array(String)
        Returns.prefixes(text).map do |prefix|
          unless prefix.matches?(/\A[0-9A-Za-z]+\z/)
            errors << FieldError.new("#{path}.accounts", "accounting.errors.vat_rule.accounts.invalid", {"value" => prefix})
          end
          Chart.normalize(prefix)
        end
      end

      # --- Liquidation ---------------------------------------------------------------

      # Comptes de l'écriture de liquidation : dette (TVA à payer), créance
      # (TVA à récupérer, crédit à reporter) ; en France, en outre : écart
      # d'arrondi à l'euro (charge, produit), acomptes versés (CA12),
      # remboursement demandé (CA3).
      record SettlementAccounts,
        payable : String,
        receivable : String,
        rounding_expense : String = "658",
        rounding_income : String = "758",
        advance : String = "44581",
        refund : String = "44583"

      # Cases françaises saisies qui n'ont pas de contrepartie connue dans
      # l'écriture de liquidation (sommes à ajouter).
      FR_UNSETTLED_BOXES = %w[29]

      # Lignes de l'écriture de liquidation ; erreurs si elle ne peut pas
      # reprendre les montants déclarés. Chaque compte de TVA des mouvements
      # retenus est soldé pour leur montant. Belgique : la différence va au
      # compte de dette ou de créance. France : la contrepartie reprend les
      # montants *déclarés* (TVA nette due 28 ou solde `sp` au compte de
      # dette ; crédit reporté 22 repris de la créance ; crédit 27 ou `ex` et
      # 25 à la créance, remboursement 26, acomptes `ac`) et l'écart d'arrondi
      # à l'euro va en charge ou en produit. Une case calculée corrigée à la
      # main, ou une case sans contrepartie connue, empêche la liquidation
      # automatique (à passer à la main).
      def self.settlement_lines(form : String, computation : Computation, declared : Hash(String, BigDecimal),
                                adjusted : Array(String), accounts : SettlementAccounts) : {Array(Api::EntryLineInput), Array(FieldError)}
        none = [] of Api::EntryLineInput
        blocking = blocking_boxes(form, declared, adjusted)
        unless blocking.empty?
          return {none, [FieldError.base("accounting.errors.vat_return.settlement.adjusted", {"codes" => blocking.join(", ")})]}
        end

        balances = tax_balances(computation.movements)
        # Solde des comptes de TVA (débit − crédit) : positif, crédit de TVA.
        total = balances.values.sum(ZERO)
        counterparts = Hash(String, BigDecimal).new(ZERO)
        if Returns.regime(form) == "fr"
          return {none, [FieldError.base("accounting.errors.vat_return.settlement.mismatch")]} unless raw_due(computation) == -total
          french_counterparts(form, declared, accounts, counterparts)
          difference = counterparts.values.sum(ZERO) - total
          counterparts[difference > 0 ? accounts.rounding_income : accounts.rounding_expense] -= difference
        else
          counterparts[total > 0 ? accounts.receivable : accounts.payable] += total
        end
        {entry_lines(balances, counterparts), [] of FieldError}
      end

      # Cases qui empêchent la liquidation automatique : cases calculées
      # corrigées, cases françaises sans contrepartie remplies.
      private def self.blocking_boxes(form : String, declared : Hash(String, BigDecimal), adjusted : Array(String)) : Array(String)
        ruled = Returns.boxes(form).select(&.ruled).map(&.code).to_set
        blocking = adjusted.select { |code| ruled.includes?(code) }
        if Returns.regime(form) == "fr"
          blocking += FR_UNSETTLED_BOXES.reject { |code| (declared[code]? || ZERO).zero? }
        end
        blocking.uniq!.sort!
      end

      # TVA nette due au centime (16 − 19 − 20 − 21), avant l'arrondi.
      private def self.raw_due(computation : Computation) : BigDecimal
        raw = computation.raw
        (raw["16"]? || ZERO) - %w[19 20 21].sum(ZERO) { |code| raw[code]? || ZERO }
      end

      private def self.entry_lines(balances : Hash(String, BigDecimal), counterparts : Hash(String, BigDecimal)) : Array(Api::EntryLineInput)
        lines = [] of Api::EntryLineInput
        balances.keys.sort!.each do |account|
          balance = balances[account]
          next if balance.zero?
          lines << Api::EntryLineInput.new(account, balance > 0 ? Api::Side::Credit : Api::Side::Debit, balance.abs)
        end
        counterparts.each do |account, amount|
          next if amount.zero?
          lines << Api::EntryLineInput.new(account, amount > 0 ? Api::Side::Debit : Api::Side::Credit, amount.abs)
        end
        lines
      end

      # Solde (débit − crédit) de chaque compte de TVA des mouvements.
      private def self.tax_balances(movements : Array(Movement)) : Hash(String, BigDecimal)
        balances = Hash(String, BigDecimal).new(ZERO)
        movements.each do |movement|
          account = movement.tax_account || next
          next unless Returns::TAX_SOURCES.includes?(movement.source)
          balances[account] += movement.source == "deductible" ? movement.amount : -movement.amount
        end
        balances
      end

      # Contreparties françaises (débit positif), d'après les montants
      # déclarés.
      private def self.french_counterparts(form : String, declared : Hash(String, BigDecimal), accounts : SettlementAccounts,
                                           counterparts : Hash(String, BigDecimal)) : Nil
        get = ->(code : String) { declared[code]? || ZERO }
        counterparts[accounts.receivable] -= get.call("22")
        if form == "fr_ca12"
          counterparts[accounts.payable] -= get.call("sp")
          counterparts[accounts.advance] -= get.call("ac")
          counterparts[accounts.receivable] += get.call("ex") + get.call("25")
        else
          counterparts[accounts.payable] -= get.call("28")
          counterparts[accounts.refund] += get.call("26")
          counterparts[accounts.receivable] += get.call("27")
        end
      end

      # --- Vues ------------------------------------------------------------------------

      def self.view(record : Partiduo::Vat::Return) : Api::VatReturnView
        id = record.id!.to_i64
        form = record.form.to_s
        regime = record.regime.to_s
        stored = Partiduo::Vat::ReturnBox.filter(vat_return_id: id).to_a.index_by(&.code.to_s)
        boxes = Returns.boxes(form).map do |box|
          row = stored[box.code]?
          box_view(regime, box, row.try(&.computed) || ZERO, row.try(&.amount) || ZERO, row.try(&.adjusted) || false)
        end
        rows = Partiduo::Vat::ReturnLine.filter(vat_return_id: id).order(:position).to_a
        cards = cards(rows.compact_map(&.card_id.try(&.to_i64)).uniq!)
        lines = rows.map do |line|
          card_id = line.card_id.try(&.to_i64)
          Api::VatListingLineView.new(card_id, card_id.try { |value| cards[value]?.try(&.code) }, line.name.to_s,
            line.vat_number.to_s, line.code.to_s, line.amount!, line.vat!)
        end
        Api::VatReturnView.new(
          id: id, form: form, regime: regime, year: record.year!.to_i32, periodicity: record.periodicity.to_s,
          number: record.period_number!.to_i32, date_from: record.date_from!, date_to: record.date_to!,
          exigibility: record.exigibility.to_s, status: record.status.to_s, threshold: record.threshold,
          client_listing_nihil: record.client_listing_nihil!, ask_restitution: record.ask_restitution!,
          boxes: boxes, lines: lines, settlement_entry_id: record.settlement_entry_id.try(&.to_i64),
          closed_at: record.closed_at, closed_by_id: record.closed_by_id.try(&.to_i64), created_at: record.created_at,
        )
      end

      # Vue d'une déclaration calculée mais non enregistrée (aperçu).
      def self.preview_view(computation : Computation) : Api::VatReturnView
        params = computation.params
        amounts = computation.computed
        boxes = Returns.boxes(params.form).map do |box|
          value = amounts[box.code]? || ZERO
          box_view(params.regime, box, value, value, false)
        end
        Api::VatReturnView.new(
          id: nil, form: params.form, regime: params.regime, year: params.year, periodicity: params.periodicity,
          number: params.number, date_from: params.date_from, date_to: params.date_to, exigibility: params.exigibility,
          status: "draft", threshold: params.threshold, client_listing_nihil: false, ask_restitution: false,
          boxes: boxes, lines: computation.lines.map { |line| listing_view(line) }, settlement_entry_id: nil, closed_at: nil, closed_by_id: nil,
          created_at: nil,
        )
      end

      def self.listing_view(line : Returns::ListingLine) : Api::VatListingLineView
        Api::VatListingLineView.new(line.card_id, line.card_code, line.name, line.vat_number, line.code, line.amount,
          line.vat)
      end

      def self.box_view(regime : String, box : Returns::Box, computed : BigDecimal, amount : BigDecimal,
                        adjusted : Bool) : Api::VatBoxView
        Api::VatBoxView.new(code: box.code, label_key: "vat.boxes.#{regime}.#{box.code}",
          section_key: "vat.sections.#{box.section}", computed: computed, amount: amount, adjusted: adjusted,
          total: box.total)
      end

      # Codes des taux et des journaux, par identifiant (une requête chacun).
      def self.rate_codes : Hash(Int64, String)
        Partiduo::Vat::Rate.all.to_a.to_h { |rate| {rate.id!.to_i64, rate.code.to_s} }
      end

      def self.ledger_codes : Hash(Int64, String)
        Ledger.all.to_a.to_h { |ledger| {ledger.pk!.as(Int64), ledger.code.to_s} }
      end

      def self.detail_views(contributions : Array(Returns::Contribution)) : Array(Api::VatDetailView)
        rates = rate_codes
        ledgers = ledger_codes
        contributions.map do |contribution|
          rule = contribution.rule
          Api::VatDetailView.new(
            box: rule.box, position: rule.position, source: rule.source,
            vat_rate_code: rule.vat_rate_id.try { |id| rates[id]? }, ledger_kind: rule.ledger_kind,
            ledger_code: rule.ledger_id.try { |id| ledgers[id]? }, accounts: rule.accounts.join(","),
            excluded_accounts: rule.excluded_accounts.join(","), sign: rule.sign, operation: rule.operation,
            amount: contribution.amount, lines: contribution.count,
          )
        end
      end

      # Vues des règles d'un régime ; taux et journaux lus une fois.
      def self.rule_views(regime : String, rules : Array(Rule), default : Bool) : Array(Api::VatBoxRuleView)
        rates = rate_codes
        ledgers = ledger_codes
        rules.map { |rule| rule_view(regime, rule, default, rates, ledgers) }
      end

      def self.rule_view(regime : String, rule : Rule, default : Bool, rates : Hash(Int64, String),
                         ledgers : Hash(Int64, String)) : Api::VatBoxRuleView
        rate_code = rule.vat_rate_id.try { |id| rates[id]? }
        ledger_code = rule.ledger_id.try { |id| ledgers[id]? }
        Api::VatBoxRuleView.new(
          regime: regime, box: rule.box, position: rule.position, vat_rate_id: rule.vat_rate_id,
          vat_rate_code: rate_code, ledger_kind: rule.ledger_kind, ledger_id: rule.ledger_id, ledger_code: ledger_code,
          accounts: rule.accounts.join(","), excluded_accounts: rule.excluded_accounts.join(","), source: rule.source,
          sign: rule.sign, operation: rule.operation, default: default,
        )
      end

      # --- Enregistrement -------------------------------------------------------------

      # Écrit les cases et les lignes d'une déclaration en brouillon ; les
      # corrections (`adjusted`) sont gardées.
      def self.store_computation!(record : Partiduo::Vat::Return, computation : Computation) : Nil
        id = record.id!.to_i64
        existing = Partiduo::Vat::ReturnBox.filter(vat_return_id: id).to_a.index_by(&.code.to_s)
        adjustments = existing.values.select(&.adjusted!).to_h { |row| {row.code.to_s, row.amount!} }
        write_boxes!(record, computation.computed, adjustments)
        Partiduo::Vat::ReturnLine.filter(vat_return_id: id).delete
        computation.lines.each_with_index do |line, index|
          Partiduo::Vat::ReturnLine.create!(vat_return_id: id, position: index, card_id: line.card_id, name: line.name,
            vat_number: line.vat_number, code: line.code, amount: line.amount, vat: line.vat)
        end
      end

      def self.write_boxes!(record : Partiduo::Vat::Return, computed : Hash(String, BigDecimal),
                            adjustments : Hash(String, BigDecimal)) : Nil
        id = record.id!.to_i64
        form = record.form.to_s
        declared = declared(form, computed, adjustments)
        Partiduo::Vat::ReturnBox.filter(vat_return_id: id).delete
        Returns.boxes(form).each do |box|
          Partiduo::Vat::ReturnBox.create!(vat_return_id: id, code: box.code, computed: computed[box.code]? || ZERO,
            amount: declared[box.code]? || ZERO, adjusted: adjustments.has_key?(box.code))
        end
      end

      def self.stored_computed(record : Partiduo::Vat::Return) : Hash(String, BigDecimal)
        Partiduo::Vat::ReturnBox.filter(vat_return_id: record.id).to_a.to_h { |row| {row.code.to_s, row.computed!} }
      end

      # Montants déclarés enregistrés, par case.
      def self.stored_declared(record : Partiduo::Vat::Return) : Hash(String, BigDecimal)
        Partiduo::Vat::ReturnBox.filter(vat_return_id: record.id).to_a.to_h { |row| {row.code.to_s, row.amount!} }
      end

      def self.stored_adjustments(record : Partiduo::Vat::Return) : Hash(String, BigDecimal)
        Partiduo::Vat::ReturnBox.filter(vat_return_id: record.id, adjusted: true).to_a
          .to_h { |row| {row.code.to_s, row.amount!} }
      end

      # Les écritures ont-elles changé depuis le calcul enregistré ?
      def self.stale?(record : Partiduo::Vat::Return, computation : Computation) : Bool
        stored = stored_computed(record)
        return true if computation.computed.any? { |code, value| (stored[code]? || ZERO) != value }
        lines = Partiduo::Vat::ReturnLine.filter(vat_return_id: record.id).order(:position).to_a
        return true unless lines.size == computation.lines.size
        lines.zip(computation.lines).any? do |(row, line)|
          row.card_id.try(&.to_i64) != line.card_id || row.code.to_s != line.code || row.amount! != line.amount ||
            row.vat! != line.vat
        end
      end

      # Déclaration close dont la période chevauche `from`–`to` : du même
      # formulaire, ou, pour une déclaration périodique (qui liquide la
      # TVA), de n'importe quelle déclaration périodique du même régime (une
      # CA3 et une CA12 sur la même période liquideraient deux fois la même
      # TVA ; une mensuelle et une trimestrielle aussi).
      def self.overlapping_closed(form : String, from : Time, to : Time, except : Int64? = nil) : Partiduo::Vat::Return?
        forms = [form]
        if Returns.settles?(form)
          forms = Returns::FORMS.select { |other| Returns.settles?(other) && Returns.regime(other) == Returns.regime(form) }
        end
        query = Partiduo::Vat::Return.filter(form__in: forms, status: "closed", date_from__lte: to, date_to__gte: from)
        query = query.exclude(id: except) if except
        query.first
      end

      # Verrou transactionnel qui sérialise la création et la clôture des
      # déclarations d'un régime (unicité du brouillon, chevauchements).
      def self.lock_regime(regime : String) : Nil
        Marten::DB::Connection.default.open do |db|
          db.exec("SELECT pg_advisory_xact_lock(hashtext($1))", "vat_return:#{regime}")
        end
      end

      # Numéros de TVA d'un fichier Intervat : celui du déclarant (belge,
      # valide), ceux des clients du listing (belges, valides) ou du relevé
      # (d'un autre pays, forme `CC` suivi de 2 à 13 caractères).
      def self.intervat_errors(view : Api::VatReturnView) : Array(FieldError)
        errors = [] of FieldError
        declarant_number = normalized_vat(declarant.vat_number)
        unless Partiduo::Vat::Be::VatNumber.valid?(declarant_number)
          errors << FieldError.new("vat_number", "accounting.errors.vat_return.declarant_vat_number",
            {"value" => declarant_number})
        end
        view.lines.each_with_index do |line, index|
          number = normalized_vat(line.vat_number)
          valid = if view.form == "be_client_listing"
                    Partiduo::Vat::Be::VatNumber.valid?(number)
                  else
                    number.matches?(/\A[A-Z]{2}[0-9A-Z]{2,13}\z/) && !number.starts_with?("BE")
                  end
          unless valid
            errors << FieldError.new("lines[#{index}].vat_number", "accounting.errors.vat_return.client_vat_number",
              {"value" => line.vat_number, "name" => line.name})
          end
        end
        errors
      end

      # Déclarant des fichiers Intervat : la société du socle.
      def self.declarant : Partiduo::Vat::Be::Intervat::Party
        settings = Partiduo::Api::Core.settings(Partiduo::Api::Actor.system)
        street = [settings.street, settings.street_number].reject(&.empty?).join(" ")
        Partiduo::Vat::Be::Intervat::Party.new(settings.vat_number, settings.company_name, street, settings.postcode,
          settings.city, settings.country_code, settings.email, settings.phone)
      rescue Partiduo::Api::NotFound
        Partiduo::Vat::Be::Intervat::Party.new("", "", "", "", "", "BE", "", "")
      end

      def self.representative : Partiduo::Vat::Be::Intervat::Representative?
        row = Partiduo::Vat::Setting.all.first
        return if row.nil? || row.representative_name.to_s.empty?
        Partiduo::Vat::Be::Intervat::Representative.new(
          row.representative_id.to_s, row.representative_id_type.to_s, row.representative_issued_by.to_s,
          row.representative_name.to_s, row.representative_street.to_s, row.representative_postcode.to_s,
          row.representative_city.to_s, row.representative_country_code.to_s, row.representative_email.to_s,
          row.representative_phone.to_s)
      end

      # Fichier XML Intervat d'une déclaration belge.
      def self.intervat(view : Api::VatReturnView) : String
        case view.form
        when "be_periodic"
          Partiduo::Vat::Be::Intervat.periodic(declarant, representative, view.periodicity, view.number, view.year,
            view.boxes.map { |box| {box.code, box.amount} }, view.client_listing_nihil, view.ask_restitution)
        when "be_client_listing"
          Partiduo::Vat::Be::Intervat.client_listing(declarant, representative, view.year,
            view.lines.map { |line| Partiduo::Vat::Be::Intervat::Client.new(line.vat_number, line.amount, line.vat) })
        else
          Partiduo::Vat::Be::Intervat.intra_listing(declarant, representative, view.periodicity, view.number, view.year,
            view.lines.map { |line| Partiduo::Vat::Be::Intervat::Client.new(line.vat_number, line.amount, code: line.code) })
        end
      end

      # Tableau imprimable (CSV, PDF) d'une déclaration.
      def self.table(view : Api::VatReturnView) : ReportOutput::Table
        name = "#{view.form}-#{view.date_from.to_s("%Y%m%d")}-#{view.date_to.to_s("%Y%m%d")}"
        title = I18n.t(view.name_key)
        subtitle = [ReportOutput.period(view.date_from, view.date_to)]
        if Returns.listing?(view.form)
          columns = [ReportOutput::Column.new(I18n.t("accounting.vat_returns.columns.vat_number"), 1.5),
                     ReportOutput::Column.new(I18n.t("accounting.vat_returns.columns.name"), 3.0),
                     ReportOutput::Column.new(I18n.t("accounting.vat_returns.columns.code"), 0.6),
                     ReportOutput::Column.new(I18n.t("accounting.vat_returns.columns.amount"), 1.3, :amount),
                     ReportOutput::Column.new(I18n.t("accounting.vat_returns.columns.vat"), 1.3, :amount)]
          rows = view.lines.map do |line|
            ReportOutput::Row.new([line.vat_number, line.name, line.code, line.amount, line.vat] of ReportOutput::Cell)
          end
          rows << ReportOutput::Row.new(["", I18n.t("accounting.vat_returns.total"), "",
                                         view.lines.sum(ZERO, &.amount), view.lines.sum(ZERO, &.vat)] of ReportOutput::Cell, :total)
        else
          columns = [ReportOutput::Column.new(I18n.t("accounting.vat_returns.columns.box"), 0.8),
                     ReportOutput::Column.new(I18n.t("accounting.vat_returns.columns.label"), 5.0),
                     ReportOutput::Column.new(I18n.t("accounting.vat_returns.columns.amount"), 1.5, :amount)]
          rows = view.boxes.map do |box|
            ReportOutput::Row.new([box.code, I18n.t(box.label_key), box.amount] of ReportOutput::Cell,
              box.total ? :subtotal : :line)
          end
          rows.concat(annex_rows(view))
        end
        ReportOutput::Table.new(name, title, subtitle, columns, rows)
      end

      # Annexe 3310-A à la suite des cases : base puis taxe de chaque taux.
      private def self.annex_rows(view : Api::VatReturnView) : Array(ReportOutput::Row)
        annex = view.annex_lines
        return [] of ReportOutput::Row if annex.empty?
        rows = [ReportOutput::Row.new(["", I18n.t("accounting.vat_returns.annex_title"), nil] of ReportOutput::Cell, :subtotal)]
        annex.each do |line|
          rows << ReportOutput::Row.new([line.vat_number, I18n.t("accounting.vat_returns.annex_base", {"rate" => line.name}), line.amount] of ReportOutput::Cell)
          rows << ReportOutput::Row.new([line.vat_number, I18n.t("accounting.vat_returns.annex_tax", {"rate" => line.name}), line.vat] of ReportOutput::Cell)
        end
        rows
      end
    end
  end
end
