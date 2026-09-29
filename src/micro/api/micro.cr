# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    # Contrat du module micro-entreprise (ADR-007 D1, D2) : livre des
    # recettes et registre des achats (saisie, contre-passation, éditions),
    # aide à la déclaration URSSAF, montants de la 2042-C-PRO, suivi des
    # seuils et bascules guidées, paramètres datés. Types dans `types.cr` ;
    # référence : `doc/api/micro.adoc`.
    #
    # Toute commande et toute requête lèvent `ModuleDisabled` si le module
    # est inactif. Le module ne cite aucun autre module : la Facturation
    # l'alimente par ses événements, la Comptabilité passe les écritures à
    # `micro.receipt.recorded` et `micro.purchase.recorded` (ADR-006 D3).
    module Micro
      MODULE_CODE    = "MICRO"
      READ           = "micro.register.read"
      WRITE          = "micro.register.write"
      SETTINGS_WRITE = "micro.settings.write"

      alias Registers = Partiduo::Micro::Registers
      alias Urssaf = Partiduo::Micro::Urssaf
      alias Parameters = Partiduo::Micro::Parameters

      # --- Paramètres -----------------------------------------------------------------

      def self.settings(actor : Actor) : SettingsView
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        Registers.settings_view
      end

      def self.update_settings(actor : Actor, input : SettingsInput) : Result(SettingsView)
        Guard.authorize!(actor, SETTINGS_WRITE, module_code: MODULE_CODE)
        Transaction.run do
          errors = [] of FieldError
          errors << Registers.error("periodicity", "settings.periodicity.invalid") unless PERIODICITIES.includes?(input.periodicity)
          if id = input.default_nature_id
            unless Partiduo::Micro::Nature.filter(id: id, kind: "receipt").exists?
              errors << Registers.error("default_nature_id", "line.nature.unknown")
            end
          end
          next Result(SettingsView).failure(errors) unless errors.empty?
          row = Registers.settings
          row.periodicity = input.periodicity
          row.flat_tax = input.flat_tax
          row.activity_started_on = input.activity_started_on.try { |date| Registers.day(date) }
          row.default_nature_id = input.default_nature_id
          row.save!
          Result(SettingsView).success(Registers.settings_view(row))
        end
      end

      # Natures et paramètres par défaut (`src/micro/data/parameters.yml`),
      # libellés dans la langue `locale` ; ce qui existe est conservé.
      # Renvoie le nombre de lignes créées.
      def self.load_defaults(actor : Actor, locale : String = "fr") : Int32
        Guard.authorize!(actor, SETTINGS_WRITE, module_code: MODULE_CODE)
        count = 0
        Transaction.run do
          count = Parameters.load_defaults(locale)
          Result(Nil).success(nil)
        end
        count
      end

      # --- Natures ----------------------------------------------------------------------

      def self.natures(actor : Actor, kind : String? = nil, enabled_only : Bool = false) : Array(NatureView)
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        rows = Partiduo::Micro::Nature.all
        rows = rows.filter(kind: kind) if kind
        rows = rows.filter(enabled: true) if enabled_only
        rows.order(:kind, :code).to_a.map { |row| Registers.nature_view(row) }
      end

      def self.create_nature(actor : Actor, input : NatureInput) : Result(NatureView)
        Guard.authorize!(actor, SETTINGS_WRITE, module_code: MODULE_CODE)
        Transaction.run do
          errors = nature_errors(input, nil)
          next Result(NatureView).failure(errors) unless errors.empty?
          row = Partiduo::Micro::Nature.create!(code: input.code.strip.upcase, label: input.label.strip, kind: input.kind,
            category: input.category, enabled: input.enabled)
          Result(NatureView).success(Registers.nature_view(row))
        end
      end

      # Libellé et activation seulement une fois la nature employée : son
      # code, son sens et sa catégorie sont figés par les registres.
      def self.update_nature(actor : Actor, id : Int64, input : NatureInput) : Result(NatureView)
        Guard.authorize!(actor, SETTINGS_WRITE, module_code: MODULE_CODE)
        Transaction.run do
          row = Partiduo::Micro::Nature.filter(id: id).lock.first || raise NotFound.new("micro_nature", id)
          errors = nature_errors(input, id)
          used = Partiduo::Micro::Receipt.filter(nature_id: id).exists? || Partiduo::Micro::Purchase.filter(nature_id: id).exists?
          if used && (input.code.strip.upcase != row.code || input.kind != row.kind || input.category != row.category)
            errors << Registers.error("code", "nature.in_use")
          end
          next Result(NatureView).failure(errors) unless errors.empty?
          row.code = input.code.strip.upcase
          row.label = input.label.strip
          row.kind = input.kind
          row.category = input.category
          row.enabled = input.enabled
          row.save!
          Result(NatureView).success(Registers.nature_view(row))
        end
      end

      private def self.nature_errors(input : NatureInput, id : Int64?) : Array(FieldError)
        errors = [] of FieldError
        code = input.code.strip.upcase
        errors << Registers.error("code", "nature.code.invalid") unless code.matches?(/\A[A-Z][A-Z0-9_]{0,23}\z/)
        duplicate = Partiduo::Micro::Nature.filter(code: code)
        duplicate = duplicate.exclude(id: id) if id
        errors << Registers.error("code", "nature.code.taken") if duplicate.exists?
        errors << Registers.error("label", "nature.label.blank") if input.label.strip.empty?
        errors << Registers.error("label", "line.too_long", {"max" => "100"}) if input.label.size > 100
        if !KINDS.includes?(input.kind)
          errors << Registers.error("kind", "nature.kind.invalid")
        elsif !(input.kind == "receipt" ? RECEIPT_CATEGORIES : PURCHASE_CATEGORIES).includes?(input.category)
          errors << Registers.error("category", "nature.category.invalid")
        end
        errors
      end

      # Nature de recette d'un article du socle (ventilation d'une facture
      # encaissée) ; `nature_id` à `nil` la retire.
      def self.set_item_nature(actor : Actor, item_card_id : Int64, nature_id : Int64?) : Result(Nil)
        Guard.authorize!(actor, SETTINGS_WRITE, module_code: MODULE_CODE)
        Transaction.run do
          card = Partiduo::Api::Cards.card(Actor.system, item_card_id)
          next Result(Nil).failure(Registers.error("item_card_id", "item.not_item")) unless card.item?
          row = Partiduo::Micro::ItemNature.filter(item_card_id: item_card_id).first
          if nature_id.nil?
            row.try(&.delete)
            next Result(Nil).success(nil)
          end
          unless Partiduo::Micro::Nature.filter(id: nature_id, kind: "receipt").exists?
            next Result(Nil).failure(Registers.error("nature_id", "line.nature.unknown"))
          end
          row ||= Partiduo::Micro::ItemNature.new(item_card_id: item_card_id)
          row.nature_id = nature_id
          row.save!
          Result(Nil).success(nil)
        end
      end

      def self.item_natures(actor : Actor) : Array(ItemNatureView)
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        Partiduo::Micro::ItemNature.all.order(:item_card_id).to_a.map do |row|
          ItemNatureView.new(row.item_card_id!.to_i64, row.nature_id!.to_i64)
        end
      end

      # --- Paramètres datés -----------------------------------------------------------

      def self.parameters(actor : Actor, code : String? = nil) : Array(ParameterView)
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        rows = Partiduo::Micro::Parameter.all
        rows = rows.filter(code: code) if code
        rows.order(:code, :valid_from).to_a.map { |row| Parameters.view(row) }
      end

      # Valeur numérique en vigueur à `on`, ou `nil`.
      def self.parameter_value(actor : Actor, code : String, on : Time) : BigDecimal?
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        Parameters.value(code, on)
      end

      # Crée ou remplace le paramètre `code` en vigueur à partir de
      # `valid_from`.
      def self.set_parameter(actor : Actor, input : ParameterInput) : Result(ParameterView)
        Guard.authorize!(actor, SETTINGS_WRITE, module_code: MODULE_CODE)
        Transaction.run do
          errors = Parameters.errors(input)
          next Result(ParameterView).failure(errors) unless errors.empty?
          day = Registers.day(input.valid_from)
          row = Partiduo::Micro::Parameter.filter(code: input.code, valid_from: day).first ||
                Partiduo::Micro::Parameter.new(code: input.code, valid_from: day)
          row.value = input.code.starts_with?("box.") ? nil : input.value
          row.text = input.code.starts_with?("box.") ? input.text.strip : ""
          row.save!
          Result(ParameterView).success(Parameters.view(row))
        end
      end

      def self.delete_parameter(actor : Actor, id : Int64) : Result(Nil)
        Guard.authorize!(actor, SETTINGS_WRITE, module_code: MODULE_CODE)
        Transaction.run do
          row = Partiduo::Micro::Parameter.filter(id: id).first || raise NotFound.new("micro_parameter", id)
          row.delete
          Result(Nil).success(nil)
        end
      end

      # --- Livre des recettes ---------------------------------------------------------

      def self.receipts(actor : Actor, query : RegisterQuery = RegisterQuery.new) : Array(LineView)
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        Registers.views(Registers.receipt_query(query).offset(query.offset).limit(query.bounded_limit).to_a)
      end

      def self.receipt(actor : Actor, id : Int64) : LineView
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        Registers.view(Partiduo::Micro::Receipt.filter(id: id).first || raise NotFound.new("micro_receipt", id))
      end

      # Requête de contrôle de `record_receipt`.
      def self.check_receipt(actor : Actor, input : ReceiptInput) : Result(Nil)
        Guard.authorize!(actor, WRITE, module_code: MODULE_CODE)
        errors = Registers.receipt_errors(input, actor: actor)
        errors.empty? ? Result(Nil).success(nil) : Result(Nil).failure(errors)
      end

      # Inscrit une recette (saisie directe) et publie `micro.receipt.recorded`.
      def self.record_receipt(actor : Actor, input : ReceiptInput) : Result(LineView)
        Guard.authorize!(actor, WRITE, module_code: MODULE_CODE)
        Transaction.run do
          errors = Registers.receipt_errors(input, actor: actor)
          next Result(LineView).failure(errors) unless errors.empty?
          Result(LineView).success(Registers.view(Registers.create_receipt!(input, actor.user_id)))
        end
      end

      # Contre-passation datée d'une recette (montant opposé, même nature,
      # même client) ; publie `micro.receipt.recorded`. Origine `manual`,
      # même pour une recette issue de la Facturation : la Comptabilité
      # passe l'écriture inverse (remboursement, D-MIC-011).
      def self.reverse_receipt(actor : Actor, input : ReverseInput) : Result(LineView)
        Guard.authorize!(actor, WRITE, module_code: MODULE_CODE)
        Transaction.run do
          row = Partiduo::Micro::Receipt.filter(id: input.id).lock.first || raise NotFound.new("micro_receipt", input.id)
          errors = Registers.reverse_errors(row, input)
          next Result(LineView).failure(errors) unless errors.empty?
          Result(LineView).success(Registers.view(Registers.reverse_receipt!(row, input, actor.user_id)))
        end
      end

      # Modifie une recette d'une période ouverte — ni déclarée à l'URSSAF,
      # ni close au socle — saisie directement, ni contre-passée ni
      # contre-passation (D-MIC2-001) ; mêmes contrôles que la saisie, la
      # nouvelle date aussi dans une période ouverte. Publie
      # `micro.receipt.updated` : la Comptabilité remplace son écriture ou
      # refuse, et rien n'est alors modifié (D-MIC2-003).
      def self.update_receipt(actor : Actor, id : Int64, input : ReceiptInput) : Result(LineView)
        Guard.authorize!(actor, WRITE, module_code: MODULE_CODE)
        Transaction.run do
          row = Partiduo::Micro::Receipt.filter(id: id).lock.first || raise NotFound.new("micro_receipt", id)
          errors = Registers.change_errors(row, update: true)
          errors.concat(Registers.receipt_errors(input, actor: actor)) if errors.empty?
          next Result(LineView).failure(errors) unless errors.empty?
          refused(Result(LineView)) { Result(LineView).success(Registers.view(Registers.update_receipt!(row, input, actor.user_id))) }
        end
      end

      # Supprime une recette d'une période ouverte (mêmes conditions que la
      # modification ; une contre-passation se supprime) ; publie
      # `micro.receipt.deleted`.
      def self.delete_receipt(actor : Actor, id : Int64) : Result(Nil)
        Guard.authorize!(actor, WRITE, module_code: MODULE_CODE)
        Transaction.run do
          row = Partiduo::Micro::Receipt.filter(id: id).lock.first || raise NotFound.new("micro_receipt", id)
          errors = Registers.change_errors(row, update: false)
          next Result(Nil).failure(errors) unless errors.empty?
          refused(Result(Nil)) do
            Registers.delete!(row, actor.user_id)
            Result(Nil).success(nil)
          end
        end
      end

      # Refus d'un abonné (la Comptabilité ne peut remplacer ou extourner
      # son écriture) : échec avec ses erreurs, la transaction est annulée.
      private def self.refused(type : Result(T).class, & : -> Result(T)) : Result(T) forall T
        yield
      rescue ex : Partiduo::Events::Refused
        Result(T).failure(ex.errors)
      end

      # Totaux du livre des recettes sur toute la requête (sans pagination).
      def self.receipts_total(actor : Actor, query : RegisterQuery = RegisterQuery.new) : TotalsView
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        Registers.totals("receipt", query)
      end

      # Récapitulatif annuel des recettes par nature.
      def self.receipt_totals(actor : Actor, year : Int32) : Array(NatureTotalView)
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        Registers.nature_totals("receipt", RegisterQuery.new(from: Time.utc(year, 1, 1), to: Time.utc(year, 12, 31)))
      end

      def self.export_receipts(actor : Actor, query : RegisterQuery, format : ExportFormat) : FileView
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        lines = Registers.views(Registers.receipt_query(query).to_a)
        Partiduo::Micro::Output.file("receipt", lines, query, format)
      end

      # --- Registre des achats --------------------------------------------------------

      def self.purchases(actor : Actor, query : RegisterQuery = RegisterQuery.new) : Array(LineView)
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        Registers.views(Registers.purchase_query(query).offset(query.offset).limit(query.bounded_limit).to_a)
      end

      def self.purchase(actor : Actor, id : Int64) : LineView
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        Registers.view(Partiduo::Micro::Purchase.filter(id: id).first || raise NotFound.new("micro_purchase", id))
      end

      def self.check_purchase(actor : Actor, input : PurchaseInput) : Result(Nil)
        Guard.authorize!(actor, WRITE, module_code: MODULE_CODE)
        errors = Registers.purchase_errors(input, actor)
        errors.empty? ? Result(Nil).success(nil) : Result(Nil).failure(errors)
      end

      def self.record_purchase(actor : Actor, input : PurchaseInput) : Result(LineView)
        Guard.authorize!(actor, WRITE, module_code: MODULE_CODE)
        Transaction.run do
          errors = Registers.purchase_errors(input, actor)
          next Result(LineView).failure(errors) unless errors.empty?
          Result(LineView).success(Registers.view(Registers.create_purchase!(input, actor.user_id)))
        end
      end

      def self.reverse_purchase(actor : Actor, input : ReverseInput) : Result(LineView)
        Guard.authorize!(actor, WRITE, module_code: MODULE_CODE)
        Transaction.run do
          row = Partiduo::Micro::Purchase.filter(id: input.id).lock.first || raise NotFound.new("micro_purchase", input.id)
          errors = Registers.reverse_errors(row, input)
          next Result(LineView).failure(errors) unless errors.empty?
          Result(LineView).success(Registers.view(Registers.reverse_purchase!(row, input, actor.user_id)))
        end
      end

      # Modifie un achat d'une période ouverte (voir `update_receipt`) ;
      # publie `micro.purchase.updated`.
      def self.update_purchase(actor : Actor, id : Int64, input : PurchaseInput) : Result(LineView)
        Guard.authorize!(actor, WRITE, module_code: MODULE_CODE)
        Transaction.run do
          row = Partiduo::Micro::Purchase.filter(id: id).lock.first || raise NotFound.new("micro_purchase", id)
          errors = Registers.change_errors(row, update: true)
          errors.concat(Registers.purchase_errors(input, actor)) if errors.empty?
          next Result(LineView).failure(errors) unless errors.empty?
          refused(Result(LineView)) { Result(LineView).success(Registers.view(Registers.update_purchase!(row, input, actor.user_id))) }
        end
      end

      # Supprime un achat d'une période ouverte ; publie
      # `micro.purchase.deleted`.
      def self.delete_purchase(actor : Actor, id : Int64) : Result(Nil)
        Guard.authorize!(actor, WRITE, module_code: MODULE_CODE)
        Transaction.run do
          row = Partiduo::Micro::Purchase.filter(id: id).lock.first || raise NotFound.new("micro_purchase", id)
          errors = Registers.change_errors(row, update: false)
          next Result(Nil).failure(errors) unless errors.empty?
          refused(Result(Nil)) do
            Registers.delete!(row, actor.user_id)
            Result(Nil).success(nil)
          end
        end
      end

      # Totaux du registre des achats sur toute la requête (sans pagination).
      def self.purchases_total(actor : Actor, query : RegisterQuery = RegisterQuery.new) : TotalsView
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        Registers.totals("purchase", query)
      end

      # Récapitulatif annuel des achats par nature (registre des achats) :
      # payé, TVA déductible comprise, hors taxe (`net_amount`).
      def self.purchase_totals(actor : Actor, year : Int32) : Array(NatureTotalView)
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        Registers.nature_totals("purchase", RegisterQuery.new(from: Time.utc(year, 1, 1), to: Time.utc(year, 12, 31)))
      end

      def self.export_purchases(actor : Actor, query : RegisterQuery, format : ExportFormat) : FileView
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        lines = Registers.views(Registers.purchase_query(query).to_a)
        Partiduo::Micro::Output.file("purchase", lines, query, format)
      end

      # Republie `micro.receipt.recorded` et `micro.purchase.recorded` pour
      # toutes les lignes (Comptabilité activée plus tard, ADR-007 D2) ;
      # renvoie le nombre de lignes publiées.
      def self.republish(actor : Actor) : Int32
        Guard.authorize!(actor, SETTINGS_WRITE, module_code: MODULE_CODE)
        count = 0
        Transaction.run do
          count = Registers.republish(actor.user_id)
          Result(Nil).success(nil)
        end
        count
      end

      # --- URSSAF ---------------------------------------------------------------------

      # Périodes de déclaration de l'année (périodicité des paramètres),
      # chiffre d'affaires par catégorie et cotisations estimées.
      def self.declarations(actor : Actor, year : Int32, today : Time = Partiduo::Config.today) : Array(DeclarationView)
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        Urssaf.declarations(year, today)
      end

      # Note la déclaration faite sur le site de l'URSSAF (ou transmise par
      # l'extension URSSAF) pour la période qui commence le `starts_on` : la
      # période est dès lors close, ses lignes intangibles (D-MIC2-001).
      def self.mark_declared(actor : Actor, input : DeclarationInput) : Result(DeclarationView)
        Guard.authorize!(actor, WRITE, module_code: MODULE_CODE)
        Transaction.run do
          period = Urssaf.period_starting(input.starts_on)
          if period.nil?
            next Result(DeclarationView).failure(Registers.error("starts_on", "declaration.period.invalid"))
          end
          starts_on, ends_on = period
          errors = [] of FieldError
          errors << Registers.error("declared_on", "declaration.before_end") if Registers.day(input.declared_on) <= ends_on
          errors << Registers.error("declared_on", "declaration.future") if Registers.day(input.declared_on) > Partiduo::Config.today
          errors << Registers.error("starts_on", "declaration.already") if Partiduo::Micro::Declaration.filter(starts_on: starts_on).exists?
          errors << Registers.error("reference", "line.too_long", {"max" => "100"}) if input.reference.size > 100
          next Result(DeclarationView).failure(errors) unless errors.empty?
          Partiduo::Micro::Declaration.create!(starts_on: starts_on, ends_on: ends_on, declared_on: Registers.day(input.declared_on),
            reference: input.reference.strip, declared_by_id: actor.user_id)
          Result(DeclarationView).success(Urssaf.declaration(starts_on, ends_on, Partiduo::Config.today))
        end
      end

      # Éléments de « À traiter » : échéances URSSAF, alertes de seuil.
      def self.todo(actor : Actor, today : Time = Partiduo::Config.today) : Array(TodoView)
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        Urssaf.todo(Registers.day(today))
      end

      # --- 2042-C-PRO et seuils ------------------------------------------------------

      def self.tax_return(actor : Actor, year : Int32) : TaxReturnView
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        Urssaf.tax_return(year)
      end

      def self.thresholds(actor : Actor, year : Int32) : ThresholdsView
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        Urssaf.thresholds(year)
      end

      # --- Bascules guidées -----------------------------------------------------------

      # Articles en franchise en base (taux d'exonération `VATEX-FR-FRANCHISE`)
      # et taux proposé pour la bascule vers la TVA.
      def self.vat_switch_plan(actor : Actor) : VatSwitchPlanView
        Guard.authorize!(actor, SETTINGS_WRITE, module_code: MODULE_CODE)
        Partiduo::Micro::Switches.vat_plan
      end

      # Bascule vers la TVA : chaque article en franchise prend le taux
      # `rate_id` (la Facturation cesse d'apposer la mention 293 B) ; la date
      # est notée. Exige aussi `cards.card.write`.
      def self.switch_to_vat(actor : Actor, input : VatSwitchInput) : Result(SettingsView)
        Guard.authorize!(actor, SETTINGS_WRITE, module_code: MODULE_CODE)
        Transaction.run { Partiduo::Micro::Switches.to_vat(actor, input) }
      end

      # Bascule vers le régime réel : active la Comptabilité (exige
      # `core.modules.manage`), note la date et republie les registres pour
      # que la Comptabilité en passe les écritures.
      def self.switch_to_real(actor : Actor, effective_on : Time) : Result(SettingsView)
        Guard.authorize!(actor, SETTINGS_WRITE, module_code: MODULE_CODE)
        Transaction.run { Partiduo::Micro::Switches.to_real(actor, effective_on) }
      end
    end
  end
end
