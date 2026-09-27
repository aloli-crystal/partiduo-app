# SPDX-License-Identifier: AGPL-3.0-or-later

require "big"

module Partiduo
  module Invoicing
    # Calcul des montants d'un document, en `BigDecimal` exclusivement, avec
    # des arrondis *explicites* au centime (demi supérieur en valeur absolue,
    # `ties_away`) :
    #
    # . brut de ligne = arrondi(quantité × prix unitaire HT) ;
    # . remise de ligne : pourcentage → arrondi(brut exact × % / 100) ;
    #   montant → le montant saisi (deux décimales au plus) ;
    # . net de ligne = brut arrondi − remise ;
    # . total des lignes (BT-106) = Σ nets ;
    # . remise globale (BT-107) : pourcentage → arrondi(total des lignes × % / 100),
    #   ou montant ; ventilée par groupe de TVA au prorata des bases, le reste
    #   d'arrondi sur le groupe de plus forte base ;
    # . base d'un groupe (BT-116) = Σ nets du groupe − part de remise ;
    #   TVA du groupe (BT-117) = arrondi(base × taux / 100) — règle BR-CO-17 ;
    # . total HT (BT-109) = Σ bases ; TVA (BT-110) = Σ TVA ;
    #   TTC (BT-112) = HT + TVA.
    #
    # Un groupe de TVA est défini par la catégorie UNCL5305, le taux et le
    # motif d'exonération (et non par le taux de TVA du socle : deux taux à
    # 2,1 % forment un seul groupe, comme l'exige l'EN 16931).
    module Calculator
      CENT = 2

      # Ligne à calculer. `kind` : `item`, `free`, `note`, `title`, `subtotal`.
      record LineData,
        kind : String,
        quantity : BigDecimal = BigDecimal.new(0),
        unit_price : BigDecimal = BigDecimal.new(0),
        discount_kind : String = "none",
        discount_value : BigDecimal = BigDecimal.new(0),
        vat_rate_id : Int64? = nil,
        vat_percent : BigDecimal = BigDecimal.new(0),
        vat_category : String = "S",
        exemption_code : String = "",
        exemption_reason : String = "",
        item_card_id : Int64? = nil do
        def priced? : Bool
          kind.in?("item", "free")
        end
      end

      record LineResult, gross : BigDecimal, discount : BigDecimal, net : BigDecimal

      record VatGroup,
        category : String,
        percent : BigDecimal,
        exemption_code : String,
        exemption_reason : String,
        lines_total : BigDecimal,
        allowance : BigDecimal,
        base : BigDecimal,
        vat : BigDecimal do
        def key : {String, String, String}
          {category, Calculator.plain(percent), exemption_code}
        end
      end

      # Part du total HT par (article, taux de TVA du socle), remise globale
      # déduite : ce que la Comptabilité passe en produits (`invoice.issued`).
      record SalesShare, item_card_id : Int64?, vat_rate_id : Int64?, amount : BigDecimal

      record Totals,
        lines : Array(LineResult),
        groups : Array(VatGroup),
        shares : Array(SalesShare),
        lines_total : BigDecimal,
        discount_total : BigDecimal,
        total_net : BigDecimal,
        total_vat : BigDecimal,
        total_gross : BigDecimal

      def self.round(value : BigDecimal, digits : Int32 = CENT) : BigDecimal
        value.round(digits, mode: :ties_away)
      end

      # Écriture décimale canonique, sans exposant ni zéro final
      # (`20`, `2.1`, `0.00001`, `-1250.5`).
      def self.plain(value : BigDecimal) : String
        digits = value.value.abs.to_s
        scale = value.scale.to_i32
        if scale > 0
          digits = digits.rjust(scale + 1, '0')
          integer = digits[0, digits.size - scale]
          fraction = digits[digits.size - scale, scale].rstrip('0')
          digits = fraction.empty? ? integer : "#{integer}.#{fraction}"
        end
        value.value < 0 ? "-#{digits}" : digits
      end

      # Nombre de décimales significatives d'un montant.
      def self.scale(value : BigDecimal) : Int32
        text = plain(value)
        text.includes?('.') ? text.split('.')[1].size : 0
      end

      def self.line(data : LineData) : LineResult
        zero = BigDecimal.new(0)
        return LineResult.new(zero, zero, zero) unless data.priced?
        exact = data.quantity * data.unit_price
        gross = round(exact)
        discount = case data.discount_kind
                   when "percent" then round(exact * data.discount_value / 100)
                   when "amount"  then data.discount_value
                   else                zero
                   end
        LineResult.new(gross, discount, gross - discount)
      end

      def self.compute(lines : Array(LineData), discount_kind : String = "none",
                       discount_value : BigDecimal = BigDecimal.new(0)) : Totals
        zero = BigDecimal.new(0)
        results = [] of LineResult
        running = zero
        lines.each do |data|
          case data.kind
          when "subtotal"
            results << LineResult.new(zero, zero, running)
            running = zero
          when "title"
            running = zero
            results << line(data)
          else
            result = line(data)
            running += result.net
            results << result
          end
        end

        priced = lines.each_with_index.select { |(data, _)| data.priced? }.to_a
        lines_total = priced.sum(zero) { |(_, index)| results[index].net }
        discount_total = case discount_kind
                         when "percent" then round(lines_total * discount_value / 100)
                         when "amount"  then discount_value
                         else                zero
                         end

        # Groupes de TVA, dans l'ordre d'apparition.
        group_totals = {} of {String, String, String} => BigDecimal
        group_reasons = {} of {String, String, String} => String
        priced.each do |(data, index)|
          key = {data.vat_category, Calculator.plain(data.vat_percent), data.exemption_code}
          group_totals[key] = group_totals.fetch(key, zero) + results[index].net
          group_reasons[key] ||= data.exemption_reason
        end
        allowances = allocate(discount_total, group_totals)
        groups = group_totals.map do |key, total|
          allowance = allowances[key]
          base = total - allowance
          percent = BigDecimal.new(key[1])
          VatGroup.new(key[0], percent, key[2], group_reasons[key], total, allowance, base, round(base * percent / 100))
        end

        shares = sales_shares(lines, results, allowances)
        total_net = groups.sum(zero, &.base)
        total_vat = groups.sum(zero, &.vat)
        Totals.new(results, groups, shares, lines_total, discount_total, total_net, total_vat, total_net + total_vat)
      end

      # Répartit `amount` entre les clés au prorata de leurs poids ; le reste
      # d'arrondi va à la clé de plus fort poids (la première en cas
      # d'égalité). La somme des parts vaut exactement `amount`.
      def self.allocate(amount : BigDecimal, weights : Hash(K, BigDecimal)) : Hash(K, BigDecimal) forall K
        zero = BigDecimal.new(0)
        shares = {} of K => BigDecimal
        total = weights.values.sum(zero)
        weights.each_key { |key| shares[key] = zero }
        return shares if amount.zero? || total.zero? || weights.empty?
        weights.each { |key, weight| shares[key] = round(amount * weight / total) }
        remainder = amount - shares.values.sum(zero)
        unless remainder.zero?
          largest = weights.max_by { |_, weight| weight.abs }[0]
          shares[largest] += remainder
        end
        shares
      end

      # Ventile la remise globale de chaque groupe de TVA sur ses couples
      # (article, taux) : la somme des parts vaut le total HT.
      private def self.sales_shares(lines : Array(LineData), results : Array(LineResult),
                                    allowances : Hash({String, String, String}, BigDecimal)) : Array(SalesShare)
        zero = BigDecimal.new(0)
        buckets = {} of {String, String, String} => Hash({Int64?, Int64?}, BigDecimal)
        lines.each_with_index do |data, index|
          next unless data.priced?
          key = {data.vat_category, Calculator.plain(data.vat_percent), data.exemption_code}
          bucket = buckets[key] ||= {} of {Int64?, Int64?} => BigDecimal
          pair = {data.item_card_id, data.vat_rate_id}
          bucket[pair] = bucket.fetch(pair, zero) + results[index].net
        end
        shares = [] of SalesShare
        buckets.each do |key, bucket|
          parts = allocate(allowances.fetch(key, zero), bucket)
          bucket.each do |pair, amount|
            shares << SalesShare.new(pair[0], pair[1], amount - parts[pair])
          end
        end
        shares
      end
    end
  end
end
