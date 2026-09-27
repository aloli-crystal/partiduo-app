# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    # Contrat du module Comptabilité — déclarations de TVA (lot 4, ADR-006
    # D1) : déclaration périodique belge, listing des clients assujettis et
    # relevé intracommunautaire (fichiers Intervat), CA3 et CA12 françaises
    # (TVA sur les débits ou les encaissements, autoliquidation), calculées
    # depuis les écritures par des règles paramétrables ; brouillon corrigé,
    # clôture figée par PostgreSQL, écriture de liquidation. Successeur de
    # l'extension TVA de noalyss-plugins (schéma `tva_belge`). Types dans
    # `vat_return_types.cr`.
    #
    # Toutes les opérations exigent `accounting.vat.declare` ; l'écriture de
    # liquidation exige en outre le droit de saisir dans son journal. Le
    # calcul porte sur *toutes* les écritures, quels que soient les journaux
    # visibles de l'acteur (une déclaration n'est pas partielle).
    module Accounting
      VAT_PERMISSION = "accounting.vat.declare"

      alias VatReturnsService = Partiduo::Accounting::VatReturns

      # --- Catalogue et paramétrage ---------------------------------------------

      # Formulaires du régime du dossier (tous tant qu'il n'est pas
      # provisionné) et leurs cases.
      def self.vat_forms(actor : Actor) : Array(VatFormView)
        Guard.authorize!(actor, VAT_PERMISSION, module_code: MODULE_CODE)
        regime = VatReturnsService.instance_regime
        Partiduo::Vat::Returns::FORMS.compact_map do |form|
          form_regime = Partiduo::Vat::Returns.regime(form)
          next if regime && regime != form_regime
          boxes = Partiduo::Vat::Returns.boxes(form).map do |box|
            VatFormBoxView.new(box.code, "vat.boxes.#{form_regime}.#{box.code}", "vat.sections.#{box.section}",
              box.ruled, box.total)
          end
          VatFormView.new(form: form, regime: form_regime, name_key: "vat.forms.#{form}",
            periodicities: Partiduo::Vat::Returns.periodicities(form), listing: Partiduo::Vat::Returns.listing?(form),
            settles: Partiduo::Vat::Returns.settles?(form), boxes: boxes)
        end
      end

      # Règles de calcul en vigueur d'un régime (`be`, `fr`), par case ;
      # `default` : paramétrage par défaut (rien d'enregistré).
      def self.vat_box_rules(actor : Actor, regime : String) : Array(VatBoxRuleView)
        Guard.authorize!(actor, VAT_PERMISSION, module_code: MODULE_CODE)
        regime = regime.strip.downcase
        return [] of VatBoxRuleView unless regime.in?("be", "fr")
        default = !Partiduo::Vat::BoxRule.filter(regime: regime).exists?
        VatReturnsService.rule_views(regime, VatReturnsService.rules(regime), default)
      end

      # Remplace les règles d'une case (le paramétrage par défaut est
      # d'abord enregistré tel quel) ; une liste vide laisse la case sans
      # calcul.
      def self.set_vat_box_rules(actor : Actor, regime : String, box : String,
                                 rules : Array(VatBoxRuleInput)) : Result(Array(VatBoxRuleView))
        Guard.authorize!(actor, VAT_PERMISSION, module_code: MODULE_CODE)
        Transaction.run do
          regime = regime.strip.downcase
          unless regime.in?("be", "fr")
            next Result(Array(VatBoxRuleView)).failure(
              FieldError.new("regime", "accounting.errors.vat_rule.regime.invalid", {"value" => regime}))
          end
          unless Partiduo::Vat::Returns.rule_boxes(regime).includes?(box)
            next Result(Array(VatBoxRuleView)).failure(
              FieldError.new("box", "accounting.errors.vat_rule.box.invalid", {"value" => box}))
          end
          errors = [] of FieldError
          parsed = rules.each_with_index.compact_map do |(input, index)|
            VatReturnsService.rule_from(regime, box, index + 1, input, "rules[#{index}]", errors)
          end.to_a
          next Result(Array(VatBoxRuleView)).failure(errors) unless errors.empty?

          VatReturnsService.materialize!(regime)
          Partiduo::Vat::BoxRule.filter(regime: regime, box: box).delete
          parsed.each { |rule| VatReturnsService.store!(regime, rule) }
          Result(Array(VatBoxRuleView)).success(VatReturnsService.rule_views(regime, parsed, false))
        end
      end

      # Revient au paramétrage par défaut d'un régime.
      def self.reset_vat_box_rules(actor : Actor, regime : String) : Result(Nil)
        Guard.authorize!(actor, VAT_PERMISSION, module_code: MODULE_CODE)
        Transaction.run do
          regime = regime.strip.downcase
          unless regime.in?("be", "fr")
            next Result(Nil).failure(FieldError.new("regime", "accounting.errors.vat_rule.regime.invalid", {"value" => regime}))
          end
          Partiduo::Vat::BoxRule.filter(regime: regime).delete
          Result(Nil).success(nil)
        end
      end

      def self.vat_settings(actor : Actor) : VatSettingsView
        Guard.authorize!(actor, VAT_PERMISSION, module_code: MODULE_CODE)
        vat_settings_view(Partiduo::Vat::Setting.all.first || Partiduo::Vat::Setting.new)
      end

      # Mandataire des fichiers Intervat : nom, adresse, identifiant (numéro
      # de TVA, NISS…), type d'identifiant et pays émetteur.
      def self.update_vat_settings(actor : Actor, input : VatSettingsInput) : Result(VatSettingsView)
        Guard.authorize!(actor, VAT_PERMISSION, module_code: MODULE_CODE)
        Transaction.run do
          errors = [] of FieldError
          name = input.representative_name.strip
          identifier = input.representative_id.strip
          issued_by = input.representative_issued_by.strip.upcase
          country = input.representative_country_code.strip.upcase
          unless name.empty?
            errors << FieldError.new("representative_id", "accounting.errors.vat_settings.representative_id.required") if identifier.empty?
            errors << FieldError.new("representative_issued_by", "accounting.errors.vat_settings.country.invalid") unless issued_by.matches?(/\A[A-Z]{2}\z/)
          end
          unless country.empty? || country.matches?(/\A[A-Z]{2}\z/)
            errors << FieldError.new("representative_country_code", "accounting.errors.vat_settings.country.invalid")
          end
          next Result(VatSettingsView).failure(errors) unless errors.empty?

          row = Partiduo::Vat::Setting.all.first || Partiduo::Vat::Setting.new
          row.representative_id = identifier
          row.representative_id_type = input.representative_id_type.strip.upcase
          row.representative_issued_by = issued_by
          row.representative_name = name
          row.representative_street = input.representative_street.strip
          row.representative_postcode = input.representative_postcode.strip
          row.representative_city = input.representative_city.strip
          row.representative_country_code = country
          row.representative_email = input.representative_email.strip
          row.representative_phone = input.representative_phone.strip
          row.save!
          Result(VatSettingsView).success(vat_settings_view(row))
        end
      end

      # --- Déclarations -----------------------------------------------------------

      # Requête de contrôle : la déclaration calculée depuis les écritures,
      # sans l'enregistrer.
      def self.preview_vat_return(actor : Actor, input : VatReturnInput) : Result(VatReturnView)
        Guard.authorize!(actor, VAT_PERMISSION, module_code: MODULE_CODE)
        params, errors = VatReturnsService.params(input)
        return Result(VatReturnView).failure(errors) if params.nil?
        Result(VatReturnView).success(VatReturnsService.preview_view(VatReturnsService.compute(params)))
      end

      # Calcule et enregistre une déclaration en brouillon. Refusé si un
      # brouillon du même formulaire existe pour la même période, ou si une
      # déclaration close en chevauche la période (pour une déclaration
      # périodique : une déclaration périodique close du même régime, CA3 ou
      # CA12). Création et clôture sont sérialisées par régime (verrou
      # transactionnel) ; l'index unique des brouillons le garantit aussi en
      # base.
      def self.create_vat_return(actor : Actor, input : VatReturnInput) : Result(VatReturnView)
        Guard.authorize!(actor, VAT_PERMISSION, module_code: MODULE_CODE)
        Transaction.run do
          params, errors = VatReturnsService.params(input)
          next Result(VatReturnView).failure(errors) if params.nil?
          VatReturnsService.lock_regime(params.regime)
          if closed = VatReturnsService.overlapping_closed(params.form, params.date_from, params.date_to)
            next Result(VatReturnView).failure(overlap_error(closed))
          end
          if draft = Partiduo::Vat::Return.filter(form: params.form, status: "draft", date_from: params.date_from,
               date_to: params.date_to).first
            next Result(VatReturnView).failure(
              FieldError.base("accounting.errors.vat_return.draft_exists", {"id" => draft.id.to_s}))
          end

          record = Partiduo::Vat::Return.create!(
            regime: params.regime, form: params.form, year: params.year, periodicity: params.periodicity,
            period_number: params.number, date_from: params.date_from, date_to: params.date_to,
            exigibility: params.exigibility, status: "draft", threshold: params.threshold,
            created_by_id: actor.user_id,
          )
          VatReturnsService.store_computation!(record, VatReturnsService.compute(params))
          Result(VatReturnView).success(VatReturnsService.view(record))
        end
      end

      # Recalcule un brouillon depuis les écritures ; les corrections
      # saisies sont gardées.
      def self.recompute_vat_return(actor : Actor, id : Int64) : Result(VatReturnView)
        Guard.authorize!(actor, VAT_PERMISSION, module_code: MODULE_CODE)
        Transaction.run do
          record = locked_return(id)
          next Result(VatReturnView).failure(closed_error) if record.status == "closed"
          VatReturnsService.store_computation!(record, VatReturnsService.compute(VatReturnsService.stored_params(record)))
          record.save!
          Result(VatReturnView).success(VatReturnsService.view(record))
        end
      end

      # Corrige des cases d'un brouillon (`amount` nil : montant calculé) et
      # ses indicateurs ; les totaux sont recalculés.
      def self.update_vat_return(actor : Actor, id : Int64, input : VatReturnUpdateInput) : Result(VatReturnView)
        Guard.authorize!(actor, VAT_PERMISSION, module_code: MODULE_CODE)
        Transaction.run do
          record = locked_return(id)
          next Result(VatReturnView).failure(closed_error) if record.status == "closed"
          boxes = Partiduo::Vat::Returns.boxes(record.form.to_s).index_by(&.code)
          adjustments = VatReturnsService.stored_adjustments(record)
          decimals = Partiduo::Vat::Returns.decimals(record.form.to_s)
          errors = [] of FieldError
          input.adjustments.each_with_index do |adjustment, index|
            box = boxes[adjustment.code]?
            if box.nil? || !box.editable?
              errors << FieldError.new("adjustments[#{index}].code", "accounting.errors.vat_return.box.not_editable",
                {"code" => adjustment.code})
              next
            end
            if amount = adjustment.amount
              if amount.scale > 2 && amount != amount.round(2)
                errors << FieldError.new("adjustments[#{index}].amount", "accounting.errors.vat_return.box.too_many_decimals")
                next
              end
              # Grilles belges positives (refusées par Intervat).
              if amount < 0 && record.regime == "be"
                errors << FieldError.new("adjustments[#{index}].amount", "accounting.errors.vat_return.box.negative")
                next
              end
              # Déclarations françaises en euros entiers (D-TVA-T01).
              if decimals.zero? && amount != amount.round(0)
                errors << FieldError.new("adjustments[#{index}].amount", "accounting.errors.vat_return.box.whole_euros")
                next
              end
              adjustments[adjustment.code] = amount
            else
              adjustments.delete(adjustment.code)
            end
          end
          next Result(VatReturnView).failure(errors) unless errors.empty?

          input.client_listing_nihil.try { |value| record.client_listing_nihil = value }
          input.ask_restitution.try { |value| record.ask_restitution = value }
          record.save!
          VatReturnsService.write_boxes!(record, VatReturnsService.stored_computed(record), adjustments)
          Result(VatReturnView).success(VatReturnsService.view(record))
        end
      end

      # Supprime un brouillon (une déclaration close ne s'efface pas).
      def self.delete_vat_return(actor : Actor, id : Int64) : Result(Nil)
        Guard.authorize!(actor, VAT_PERMISSION, module_code: MODULE_CODE)
        Transaction.run do
          record = locked_return(id)
          next Result(Nil).failure(closed_error) if record.status == "closed"
          Partiduo::Vat::ReturnBox.filter(vat_return_id: id).delete
          Partiduo::Vat::ReturnLine.filter(vat_return_id: id).delete
          record.delete
          Result(Nil).success(nil)
        end
      end

      # Clôt une déclaration : les écritures ne doivent pas avoir changé
      # depuis son calcul (`stale`, sinon la recalculer), aucune déclaration
      # close du même formulaire n'en chevauche la période. Avec
      # `settlement`, passe l'écriture de liquidation (déclarations
      # périodiques) dans la même transaction.
      def self.close_vat_return(actor : Actor, id : Int64,
                                settlement : VatSettlementInput? = VatSettlementInput.new) : Result(VatReturnView)
        Guard.authorize!(actor, VAT_PERMISSION, module_code: MODULE_CODE)
        Transaction.run do
          record = locked_return(id)
          next Result(VatReturnView).failure(closed_error) if record.status == "closed"
          params = VatReturnsService.stored_params(record)
          VatReturnsService.lock_regime(params.regime)
          if closed = VatReturnsService.overlapping_closed(params.form, params.date_from, params.date_to, id)
            next Result(VatReturnView).failure(overlap_error(closed))
          end
          computation = VatReturnsService.compute(params)
          if VatReturnsService.stale?(record, computation)
            next Result(VatReturnView).failure(FieldError.base("accounting.errors.vat_return.stale"))
          end
          if settlement && Partiduo::Vat::Returns.settles?(params.form)
            entry_id, errors = settle(actor, record, computation, settlement)
            next Result(VatReturnView).failure(errors) unless errors.empty?
            record.settlement_entry_id = entry_id
          end
          record.status = "closed"
          record.closed_at = Time.utc
          record.closed_by_id = actor.user_id
          begin
            record.save!
          rescue ex : Exception
            raise ex unless Partiduo::Core::Db.conflict?(ex)
            next Result(VatReturnView).failure(FieldError.base("accounting.errors.vat_return.overlap",
              {"from" => params.date_from.to_s("%Y-%m-%d"), "to" => params.date_to.to_s("%Y-%m-%d")}))
          end
          Result(VatReturnView).success(VatReturnsService.view(record))
        end
      end

      # Passe l'écriture de liquidation d'une déclaration close qui n'en a
      # pas.
      def self.settle_vat_return(actor : Actor, id : Int64,
                                 settlement : VatSettlementInput = VatSettlementInput.new) : Result(VatReturnView)
        Guard.authorize!(actor, VAT_PERMISSION, module_code: MODULE_CODE)
        Transaction.run do
          record = locked_return(id)
          unless record.status == "closed"
            next Result(VatReturnView).failure(FieldError.base("accounting.errors.vat_return.not_closed"))
          end
          unless Partiduo::Vat::Returns.settles?(record.form.to_s)
            next Result(VatReturnView).failure(FieldError.base("accounting.errors.vat_return.not_settled_form"))
          end
          if record.settlement_entry_id
            next Result(VatReturnView).failure(FieldError.base("accounting.errors.vat_return.already_settled"))
          end
          # Écritures changées depuis la clôture : l'écriture ne reprendrait
          # plus les montants déclarés et figés (D-TVA-T03).
          computation = VatReturnsService.compute(VatReturnsService.stored_params(record))
          if VatReturnsService.stale?(record, computation)
            next Result(VatReturnView).failure(FieldError.base("accounting.errors.vat_return.settle_stale"))
          end
          entry_id, errors = settle(actor, record, computation, settlement)
          next Result(VatReturnView).failure(errors) unless errors.empty?
          if entry_id.nil?
            next Result(VatReturnView).failure(FieldError.base("accounting.errors.vat_return.nothing_to_settle"))
          end
          record.settlement_entry_id = entry_id
          record.save!
          Result(VatReturnView).success(VatReturnsService.view(record))
        end
      end

      def self.vat_return(actor : Actor, id : Int64) : VatReturnView
        Guard.authorize!(actor, VAT_PERMISSION, module_code: MODULE_CODE)
        VatReturnsService.view(Partiduo::Vat::Return.filter(id: id).first || raise NotFound.new("vat_return", id))
      end

      # Déclarations enregistrées, les plus récentes d'abord ; filtres
      # facultatifs : formulaire, année.
      def self.vat_returns(actor : Actor, form : String? = nil, year : Int32? = nil) : Array(VatReturnView)
        Guard.authorize!(actor, VAT_PERMISSION, module_code: MODULE_CODE)
        query = Partiduo::Vat::Return.all
        query = query.filter(form: form) if form
        query = query.filter(year: year) if year
        query.order("-date_from", "-id").to_a.map { |record| VatReturnsService.view(record) }
      end

      # Détail du calcul d'une déclaration (apport de chaque règle), relu
      # dans les écritures.
      def self.vat_return_details(actor : Actor, id : Int64) : Array(VatDetailView)
        Guard.authorize!(actor, VAT_PERMISSION, module_code: MODULE_CODE)
        record = Partiduo::Vat::Return.filter(id: id).first || raise NotFound.new("vat_return", id)
        computation = VatReturnsService.compute(VatReturnsService.stored_params(record))
        VatReturnsService.detail_views(computation.contributions)
      end

      # Fichier d'une déclaration : XML Intervat (formulaires belges), CSV
      # ou PDF dans la langue courante.
      def self.vat_return_file(actor : Actor, id : Int64, format : VatFileFormat) : Result(FileView)
        view = vat_return(actor, id)
        if format.xml?
          unless view.regime == "be"
            return Result(FileView).failure(FieldError.new("format", "accounting.errors.vat_return.format.xml"))
          end
          invalid = VatReturnsService.intervat_errors(view)
          return Result(FileView).failure(invalid) unless invalid.empty?
          name = "#{view.form}-#{view.date_from.to_s("%Y%m%d")}-#{view.date_to.to_s("%Y%m%d")}.xml"
          return Result(FileView).success(FileView.new(name, "application/xml", VatReturnsService.intervat(view).to_slice))
        end
        table = VatReturnsService.table(view)
        export = format.csv? ? ExportFormat::Csv : ExportFormat::Pdf
        Result(FileView).success(Partiduo::Accounting::ReportOutput.file(table, export))
      end

      # --- Outils -------------------------------------------------------------------

      private def self.locked_return(id : Int64) : Partiduo::Vat::Return
        Partiduo::Vat::Return.all.lock.filter(id: id).first || raise NotFound.new("vat_return", id)
      end

      private def self.closed_error : FieldError
        FieldError.base("accounting.errors.vat_return.closed")
      end

      private def self.overlap_error(closed : Partiduo::Vat::Return) : FieldError
        FieldError.base("accounting.errors.vat_return.overlap",
          {"from" => closed.date_from!.to_s("%Y-%m-%d"), "to" => closed.date_to!.to_s("%Y-%m-%d")})
      end

      # Écriture de liquidation ; nil s'il n'y a rien à solder.
      private def self.settle(actor : Actor, record : Partiduo::Vat::Return,
                              computation : Partiduo::Accounting::VatReturns::Computation,
                              settlement : VatSettlementInput) : {Int64?, Array(FieldError)}
        accounts, ledger, errors = settlement_target(record.regime.to_s, settlement)
        return {nil, errors} unless errors.empty? && accounts && ledger

        lines, errors = VatReturnsService.settlement_lines(record.form.to_s, computation,
          VatReturnsService.stored_declared(record), VatReturnsService.stored_adjustments(record).keys, accounts)
        return {nil, errors} if lines.empty?
        label = I18n.t("accounting.vat_returns.settlement_label", {
          "form" => I18n.t("vat.forms.#{record.form}"),
          "from" => record.date_from!.to_s("%Y-%m-%d"),
          "to"   => record.date_to!.to_s("%Y-%m-%d"),
        })
        input = EntryInput.new(ledger_id: ledger.pk!.as(Int64), date: settlement.date || record.date_to!, lines: lines,
          label: label, source: "#{VatReturnsService::SOURCE_PREFIX}#{record.id}")
        result = post_entry(actor, input)
        if result.failure?
          return {nil, result.errors.map { |error| FieldError.new("settlement.#{error.field}", error.key, error.params) }}
        end
        {result.value!.id, errors}
      end

      # Comptes de dette, de créance (et, en France, d'arrondi, d'acomptes et
      # de remboursement), journal de la liquidation.
      private def self.settlement_target(regime : String, settlement : VatSettlementInput) : {VatReturnsService::SettlementAccounts?, Partiduo::Accounting::Ledger?, Array(FieldError)}
        errors = [] of FieldError
        payable = settlement.payable_account.try(&.strip.presence) || default_account(Actor.system, "vat").try(&.number)
        receivable = settlement.receivable_account.try(&.strip.presence) || VatReturnsService::RECEIVABLE_ACCOUNTS[regime]?
        errors << FieldError.new("settlement.payable_account", "accounting.errors.vat_return.settlement.account_missing") if payable.nil?
        errors << FieldError.new("settlement.receivable_account", "accounting.errors.vat_return.settlement.account_missing") if receivable.nil?
        ledger = if ledger_id = settlement.ledger_id
                   Partiduo::Accounting::Ledger.filter(id: ledger_id).first
                 else
                   Partiduo::Accounting::Ledger.filter(kind: "misc", enabled: true).order(:code).first
                 end
        errors << FieldError.new("settlement.ledger_id", "accounting.errors.vat_return.settlement.ledger_missing") if ledger.nil?
        return {nil, ledger, errors} unless payable && receivable
        {settlement_accounts(payable, receivable, settlement), ledger, errors}
      end

      # Comptes français d'arrondi, d'acomptes et de remboursement : ceux
      # donnés, sinon ceux par défaut.
      private def self.settlement_accounts(payable : String, receivable : String,
                                           settlement : VatSettlementInput) : VatReturnsService::SettlementAccounts
        defaults = VatReturnsService::SettlementAccounts.new(payable, receivable)
        given = ->(value : String?) { value.try(&.strip.presence) }
        VatReturnsService::SettlementAccounts.new(payable, receivable,
          rounding_expense: given.call(settlement.rounding_expense_account) || defaults.rounding_expense,
          rounding_income: given.call(settlement.rounding_income_account) || defaults.rounding_income,
          advance: given.call(settlement.advance_account) || defaults.advance,
          refund: given.call(settlement.refund_account) || defaults.refund)
      end

      private def self.vat_settings_view(row : Partiduo::Vat::Setting) : VatSettingsView
        VatSettingsView.new(
          representative_id: row.representative_id.to_s, representative_id_type: row.representative_id_type.to_s,
          representative_issued_by: row.representative_issued_by.to_s, representative_name: row.representative_name.to_s,
          representative_street: row.representative_street.to_s, representative_postcode: row.representative_postcode.to_s,
          representative_city: row.representative_city.to_s,
          representative_country_code: row.representative_country_code.to_s,
          representative_email: row.representative_email.to_s, representative_phone: row.representative_phone.to_s,
        )
      end
    end
  end
end
