# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    # Contrat du socle — taux de TVA (ADR-006 D1). Les déclarations et les
    # comptes de TVA relèvent de la Comptabilité (lot 4).
    module Vat
      CATEGORIES = Partiduo::Vat::RateRules::CATEGORIES

      # Saisie d'un taux ; décrit la ligne entière. `category` vide : `Z` pour
      # un taux nul, `S` sinon.
      record RateInput,
        code : String,
        label : String,
        rate : BigDecimal,
        description : String? = nil,
        category : String? = nil,
        exemption_code : String? = nil,
        exemption_reason : String? = nil,
        reverse_charge : Bool = false,
        sale_on_payment : Bool = false,
        purchase_on_payment : Bool = false,
        enabled : Bool = true

      record RateView,
        id : Int64,
        code : String,
        label : String,
        rate : BigDecimal,
        description : String,
        category : String,
        exemption_code : String,
        exemption_reason : String,
        reverse_charge : Bool,
        sale_on_payment : Bool,
        purchase_on_payment : Bool,
        enabled : Bool do
        # Taux en fraction (`0.2`), pour le calcul : montant × fraction.
        def fraction : BigDecimal
          rate / 100
        end

        # Clé i18n de la catégorie (`vat.categories.s`).
        def category_key : String
          "vat.categories.#{category.downcase}"
        end

        # TVA sur `base`, arrondie à `decimals` décimales (au demi supérieur,
        # en valeur absolue).
        def tax_on(base : BigDecimal, decimals : Int32 = 2) : BigDecimal
          (base * rate / 100).round(decimals, mode: :ties_away)
        end

        def to_input : RateInput
          RateInput.new(code: code, label: label, rate: rate, description: description, category: category,
            exemption_code: exemption_code, exemption_reason: exemption_reason, reverse_charge: reverse_charge,
            sale_on_payment: sale_on_payment, purchase_on_payment: purchase_on_payment, enabled: enabled)
        end
      end

      # Taux, par code ; les taux désactivés seulement si `include_disabled`.
      def self.rates(actor : Actor, include_disabled : Bool = false) : Array(RateView)
        Guard.authorize!(actor, "vat.rate.read", module_code: "VAT")
        query = Partiduo::Vat::Rate.all
        query = query.filter(enabled: true) unless include_disabled
        query.order(:code).map { |rate| rate_view(rate) }
      end

      def self.rate(actor : Actor, id : Int64) : RateView
        Guard.authorize!(actor, "vat.rate.read", module_code: "VAT")
        rate_view(Partiduo::Vat::Rate.filter(id: id).first || raise NotFound.new("vat_rate", id))
      end

      # Taux par code (`Acc_Tva::build`), ou `nil`.
      def self.rate_by_code(actor : Actor, code : String) : RateView?
        Guard.authorize!(actor, "vat.rate.read", module_code: "VAT")
        Partiduo::Vat::Rate.filter(code: code.strip.upcase).first.try { |rate| rate_view(rate) }
      end

      # Requête de contrôle : les règles de `create_rate` / `update_rate`.
      def self.check_rate(actor : Actor, input : RateInput, id : Int64? = nil) : Result(Nil)
        Guard.authorize!(actor, "vat.rate.write", module_code: "VAT")
        errors = Partiduo::Vat::RateRules.validate(Partiduo::Vat::RateRules.normalize(input), id)
        errors.empty? ? Result(Nil).success(nil) : Result(Nil).failure(errors)
      end

      def self.create_rate(actor : Actor, input : RateInput) : Result(RateView)
        Guard.authorize!(actor, "vat.rate.write", module_code: "VAT")
        Transaction.run do
          values = Partiduo::Vat::RateRules.normalize(input)
          errors = Partiduo::Vat::RateRules.validate(values)
          next Result(RateView).failure(errors) unless errors.empty?

          rate = Partiduo::Vat::RateRules.assign(Partiduo::Vat::Rate.new, values)
          rate.save!
          Result(RateView).success(rate_view(rate))
        end
      end

      # Modifie un taux. Ce qui qualifie les pièces qui le citent (une fiche,
      # une écriture, une facture) ne change plus une fois le taux cité :
      # taux, code, catégorie UNCL5305, motif d'exonération, autoliquidation
      # et exigibilité (D-REF-009). On crée un nouveau taux et on désactive
      # l'ancien ; libellé, description et activation restent libres.
      def self.update_rate(actor : Actor, id : Int64, input : RateInput) : Result(RateView)
        Guard.authorize!(actor, "vat.rate.write", module_code: "VAT")
        Transaction.run do
          rate = Partiduo::Vat::Rate.all.lock.filter(id: id).first || raise NotFound.new("vat_rate", id)
          values = Partiduo::Vat::RateRules.normalize(input)
          errors = Partiduo::Vat::RateRules.validate(values, id)
          if errors.empty? && qualifying_change?(rate, values) && referenced?(id)
            errors << Partiduo::Vat::RateRules.error("rate", "in_use")
          end
          next Result(RateView).failure(errors) unless errors.empty?

          Partiduo::Vat::RateRules.assign(rate, values).save!
          Result(RateView).success(rate_view(rate))
        end
      end

      # Supprime un taux que rien ne cite ; sinon, le désactiver.
      def self.delete_rate(actor : Actor, id : Int64) : Result(Nil)
        Guard.authorize!(actor, "vat.rate.write", module_code: "VAT")
        Transaction.run do
          Partiduo::Vat::Rate.all.lock.filter(id: id).first || raise NotFound.new("vat_rate", id)
          deleted = Partiduo::Core::Db.delete_unless_referenced([
            {"DELETE FROM vat_rate WHERE id = $1", [id] of ::DB::Any},
          ])
          next Result(Nil).failure(Partiduo::Vat::RateRules.error("base", "in_use")) unless deleted
          Result(Nil).success(nil)
        end
      end

      # Charge les taux d'un régime (`be`, `fr`) : jeu de données initial,
      # libellés dans la langue `locale`. Un code déjà présent est laissé tel
      # quel. Renvoie les codes créés.
      def self.load_rates(actor : Actor, regime : String, locale : String = "fr") : Array(String)
        raise Forbidden.new("vat.rate.write") unless actor.system
        Guard.authorize!(actor, "vat.rate.write", module_code: "VAT")
        defaults = case regime
                   when "be" then Partiduo::Vat::Be::RATES
                   when "fr" then Partiduo::Vat::Fr::RATES
                   else           raise ArgumentError.new("régime inconnu : #{regime}")
                   end
        created = [] of String
        defaults.each do |input|
          next if Partiduo::Vat::Rate.filter(code: input.code).exists?
          label = I18n.with_locale(Partiduo::LOCALES.includes?(locale) ? locale : "fr") { I18n.t(input.label) }
          result = create_rate(actor, input.copy_with(label: label))
          raise ArgumentError.new("taux #{input.code} refusé : #{result.error_keys.join(", ")}") if result.failure?
          created << input.code
        end
        created
      end

      private def self.qualifying_change?(rate : Partiduo::Vat::Rate, values : Partiduo::Vat::RateRules::Values) : Bool
        values.rate != rate.rate || values.code != rate.code || values.category != rate.category ||
          values.exemption_code != rate.exemption_code.to_s || values.reverse_charge != rate.reverse_charge ||
          values.sale_on_payment != rate.sale_on_payment || values.purchase_on_payment != rate.purchase_on_payment
      end

      private def self.referenced?(id : Int64) : Bool
        Partiduo::Core::Db.referenced?([{"DELETE FROM vat_rate WHERE id = $1", [id] of ::DB::Any}])
      end

      private def self.rate_view(rate : Partiduo::Vat::Rate) : RateView
        RateView.new(
          id: rate.id!.to_i64,
          code: rate.code!,
          label: rate.label!,
          rate: rate.rate!,
          description: rate.description.to_s,
          category: rate.category!,
          exemption_code: rate.exemption_code.to_s,
          exemption_reason: rate.exemption_reason.to_s,
          reverse_charge: rate.reverse_charge!,
          sale_on_payment: rate.sale_on_payment!,
          purchase_on_payment: rate.purchase_on_payment!,
          enabled: rate.enabled!,
        )
      end
    end
  end
end
