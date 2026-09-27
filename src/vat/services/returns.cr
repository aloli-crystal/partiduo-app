# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Vat
    # Moteur commun des déclarations de TVA (lot 4) : cases calculées par des
    # règles (successeur de `Tva_Amount::amount_operation` et `amount_vat`)
    # appliquées à des *mouvements* neutres que fournit le module Comptabilité
    # depuis ses écritures, relevés par client, périodes. Les formulaires
    # nationaux (cases, totaux, règles par défaut, fichiers) sont dans
    # `Vat::Be` et `Vat::Fr`. Service interne, sans accès à la base.
    module Returns
      ZERO = BigDecimal.new(0)

      FORMS             = %w[be_periodic be_client_listing be_intra_listing fr_ca3 fr_ca12]
      PERIODICITIES     = %w[month quarter year]
      EXIGIBILITIES     = %w[rates operation payment]
      SOURCES           = %w[base deductible collected balance]
      SIGNS             = %w[all positive negative]
      OPERATIONS        = %w[add subtract]
      LEDGER_KINDS      = %w[purchase sale financial misc]
      TAX_SOURCES       = %w[deductible collected]
      LISTING_CODES     = %w[L S T]
      DEFAULT_THRESHOLD = BigDecimal.new(250)

      # Mouvement d'une écriture retenu pour la TVA, montant signé dans le sens
      # « normal » de sa source :
      #
      # * `base` : ligne hors taxe d'un achat (débit positif) ou d'une vente
      #   (crédit positif) ; un avoir est négatif ;
      # * `deductible` : TVA déductible (débit positif) ; `collected` : TVA
      #   due (crédit positif) ; `account` est le compte de la ligne hors taxe
      #   à laquelle la TVA est rattachée (au prorata), `tax_account` celui de
      #   la ligne de TVA ;
      # * `balance` : ligne d'un journal d'opérations diverses ou financier
      #   (débit − crédit).
      #
      # `date` : date d'exigibilité retenue ; `card_id` : tiers de l'écriture.
      record Movement,
        entry_id : Int64,
        date : Time,
        ledger_id : Int64,
        ledger_kind : String,
        account : String,
        vat_rate_id : Int64?,
        source : String,
        amount : BigDecimal,
        card_id : Int64? = nil,
        tax_account : String? = nil

      # Règle d'une case (`parameter_chld`). `vat_rate_id` nil : tous les
      # taux ; `ledger_kind`, `ledger_id` nil : tous les journaux ;
      # `accounts` vide : tous les comptes.
      record Rule,
        box : String,
        position : Int32,
        vat_rate_id : Int64?,
        ledger_kind : String?,
        ledger_id : Int64?,
        accounts : Array(String),
        excluded_accounts : Array(String),
        source : String,
        sign : String = "all",
        operation : String = "add" do
        def matches?(movement : Movement) : Bool
          movement.source == source && scope?(movement) && account?(movement.account) && sign?(movement.amount)
        end

        # Taux (sauf pour un solde), nature de journal, journal.
        private def scope?(movement : Movement) : Bool
          rate = vat_rate_id
          return false if rate && source != "balance" && movement.vat_rate_id != rate
          kind = ledger_kind
          return false if kind && movement.ledger_kind != kind
          ledger = ledger_id
          ledger.nil? || movement.ledger_id == ledger
        end

        private def account?(number : String) : Bool
          return false unless accounts.empty? || accounts.any? { |prefix| number.starts_with?(prefix) }
          excluded_accounts.none? { |prefix| number.starts_with?(prefix) }
        end

        private def sign?(amount : BigDecimal) : Bool
          case sign
          when "positive" then amount > 0
          when "negative" then amount < 0
          else                 true
          end
        end

        def factor : Int32
          operation == "subtract" ? -1 : 1
        end
      end

      # Ligne d'un relevé : tiers, numéro de TVA, code (`L`, `S`, `T`),
      # montant hors taxe, TVA.
      record ListingLine,
        card_id : Int64?,
        card_code : String?,
        name : String,
        vat_number : String,
        code : String,
        amount : BigDecimal,
        vat : BigDecimal

      # Apport d'une règle à une case (`declaration_amount_detail`).
      record Contribution, rule : Rule, amount : BigDecimal, count : Int32

      # Case d'un formulaire : section (clé de libellé), case calculée par
      # des règles (`ruled`), total calculé par le formulaire (`total`) ;
      # une case réglée ou saisie se corrige, pas un total.
      record Box, code : String, section : String, ruled : Bool = true, total : Bool = false do
        def editable? : Bool
          !total
        end
      end

      # Liste des préfixes de comptes d'une chaîne `60,61%, 22` (le `%` de
      # NOALYSS est admis et ignoré).
      def self.prefixes(text : String) : Array(String)
        text.split(',').compact_map(&.strip.rchop('%').strip.presence).uniq!
      end

      # Bornes d'une période : mois ou trimestre `number` de `year`, ou
      # l'année entière.
      def self.period(periodicity : String, year : Int32, number : Int32) : {Time, Time}?
        case periodicity
        when "month"
          return unless 1 <= number <= 12
          from = Time.utc(year, number, 1)
          {from, from.shift(months: 1) - 1.day}
        when "quarter"
          return unless 1 <= number <= 4
          from = Time.utc(year, (number - 1) * 3 + 1, 1)
          {from, from.shift(months: 3) - 1.day}
        when "year"
          {Time.utc(year, 1, 1), Time.utc(year, 12, 31)}
        end
      end

      # Applique les règles aux mouvements : montant de chaque case réglée
      # (arrondi à `decimals` décimales) et apports de chaque règle.
      def self.evaluate(rules : Array(Rule), movements : Array(Movement), decimals : Int32 = 2) : {Hash(String, BigDecimal), Array(Contribution)}
        boxes = {} of String => BigDecimal
        contributions = [] of Contribution
        rules.each do |rule|
          total = ZERO
          count = 0
          movements.each do |movement|
            next unless rule.matches?(movement)
            total += movement.amount
            count += 1
          end
          amount = total * rule.factor
          boxes[rule.box] = (boxes[rule.box]? || ZERO) + amount
          contributions << Contribution.new(rule, amount, count) unless count.zero?
        end
        {boxes.transform_values(&.round(decimals, mode: :ties_away)), contributions}
      end

      # Relevé par client : montant hors taxe (règles `amount_box`) et TVA
      # (règles `vat_box`) par tiers, depuis les mouvements qui portent un
      # tiers.
      def self.by_card(rules : Array(Rule), movements : Array(Movement), amount_box : String,
                       vat_box : String? = nil) : Hash(Int64, {BigDecimal, BigDecimal})
        result = {} of Int64 => {BigDecimal, BigDecimal}
        movements.group_by(&.card_id).each do |card_id, list|
          next if card_id.nil?
          amount = sum(rules.select(&.box.==(amount_box)), list)
          vat = vat_box ? sum(rules.select(&.box.==(vat_box)), list) : ZERO
          next if amount.zero? && vat.zero?
          result[card_id] = {amount.round(2, mode: :ties_away), vat.round(2, mode: :ties_away)}
        end
        result
      end

      private def self.sum(rules : Array(Rule), movements : Array(Movement)) : BigDecimal
        rules.sum(ZERO) do |rule|
          movements.sum(ZERO) { |movement| rule.matches?(movement) ? movement.amount : ZERO } * rule.factor
        end
      end

      # --- Formulaires ------------------------------------------------------------

      def self.regime(form : String) : String
        form[0, 2]
      end

      def self.listing?(form : String) : Bool
        form.in?("be_client_listing", "be_intra_listing")
      end

      # Déclarations qui se liquident (écriture de liquidation).
      def self.settles?(form : String) : Bool
        form.in?("be_periodic", "fr_ca3", "fr_ca12")
      end

      # Cases d'un formulaire, dans l'ordre du formulaire.
      def self.boxes(form : String) : Array(Box)
        case form
        when "be_periodic" then Be::Periodic::BOXES
        when "fr_ca3"      then Fr::Ca3::BOXES
        when "fr_ca12"     then Fr::Ca12::BOXES
        else                    [] of Box
        end
      end

      # Périodicités admises d'un formulaire.
      def self.periodicities(form : String) : Array(String)
        case form
        when "be_periodic", "be_intra_listing", "fr_ca3" then %w[month quarter]
        else                                                  %w[year]
        end
      end

      # Décimales des montants déclarés : euros entiers en France (CA3, CA12),
      # centimes en Belgique.
      def self.decimals(form : String) : Int32
        regime(form) == "fr" ? 0 : 2
      end

      # Complète les totaux d'un formulaire depuis les montants déclarés.
      def self.totals!(form : String, amounts : Hash(String, BigDecimal)) : Nil
        case form
        when "be_periodic" then Be::Periodic.totals!(amounts)
        when "fr_ca3"      then Fr::Ca3.totals!(amounts)
        when "fr_ca12"     then Fr::Ca12.totals!(amounts)
        end
        nil
      end

      # Règles par défaut d'un régime (codes de taux, résolus par l'appelant).
      def self.default_rules(regime : String) : Array(DefaultRule)
        regime == "be" ? Be::DEFAULT_RULES : Fr::DEFAULT_RULES
      end

      # Case réglée par des règles, pour un régime : cases des formulaires et
      # pseudo-cases des relevés.
      def self.rule_boxes(regime : String) : Array(String)
        if regime == "be"
          Be::Periodic::BOXES.select(&.ruled).map(&.code) + Be::LISTING_BOXES
        else
          (Fr::Ca3::BOXES + Fr::Ca12::BOXES).select(&.ruled).map(&.code).uniq!
        end
      end

      # Règle par défaut : codes de taux (`nil` : tous), nature de journal,
      # comptes, comptes exclus, source, signe, opération.
      record DefaultRule,
        box : String,
        rates : Array(String)?,
        ledger_kind : String?,
        source : String,
        accounts : String = "",
        excluded_accounts : String = "",
        sign : String = "all",
        operation : String = "add"

      # Arrondi d'un montant positif ou négatif, au demi supérieur.
      def self.round(value : BigDecimal, decimals : Int32) : BigDecimal
        value.round(decimals, mode: :ties_away)
      end

      def self.positive(value : BigDecimal) : BigDecimal
        value > 0 ? value : ZERO
      end
    end
  end
end
