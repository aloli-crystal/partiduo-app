# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    # Contrat du module liberal (ADR-007 D6) : livre-journal des recettes et
    # des dépenses professionnelles (saisie, contre-passation, éditions),
    # registre des immobilisations et amortissements linéaires, réintégrations
    # et déductions, table de correspondance des lignes de la 2035 par
    # millésime, 2035 préparée (2035-A, 2035-B, contrôles, édition de
    # contrôle), lue aussi par `partiduo-teledec` pour la transmettre. Types
    # dans `types.cr` ; référence : `doc/api/liberal.adoc`.
    #
    # Toute commande et toute requête lèvent `ModuleDisabled` si le module
    # est inactif. Le module ne cite aucun autre module : la Facturation
    # l'alimente par ses événements, la Comptabilité passe les écritures à
    # `liberal.receipt.recorded`, `liberal.expense.recorded` et
    # `liberal.asset.recorded`, les remplace ou les extourne à
    # `liberal.*.updated` et `liberal.*.deleted` (ADR-006 D3).
    #
    # Exercice (année civile de la 2035, DECISIONS D-LIB2-001) : ouvert, ses
    # lignes se modifient et se suppriment ; figé — clôturé au socle, ou sa
    # 2035 transmise (`tax_return.transmitted`) —, elles sont intangibles et
    # se corrigent par contre-passation datée dans un exercice ouvert.
    module Liberal
      MODULE_CODE    = "LIBERAL"
      READ           = "liberal.register.read"
      WRITE          = "liberal.register.write"
      SETTINGS_WRITE = "liberal.settings.write"

      alias Registers = Partiduo::Liberal::Registers
      alias Assets = Partiduo::Liberal::Assets
      alias FormLines = Partiduo::Liberal::FormLines

      # --- Paramètres -----------------------------------------------------------------

      def self.settings(actor : Actor) : SettingsView
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        Registers.settings_view
      end

      def self.update_settings(actor : Actor, input : SettingsInput) : Result(SettingsView)
        Guard.authorize!(actor, SETTINGS_WRITE, module_code: MODULE_CODE)
        Transaction.run do
          errors = [] of FieldError
          errors << Registers.error("profession", "line.too_long", {"max" => "100"}) if input.profession.size > 100
          if id = input.default_nature_id
            unless Partiduo::Liberal::Nature.filter(id: id, kind: "receipt", enabled: true).exists?
              errors << Registers.error("default_nature_id", "line.nature.unknown")
            end
          end
          next Result(SettingsView).failure(errors) unless errors.empty?
          row = Registers.settings!
          row.profession = input.profession.strip
          row.activity_started_on = input.activity_started_on.try { |date| Registers.day(date) }
          row.default_nature_id = input.default_nature_id
          row.save!
          Result(SettingsView).success(Registers.settings_view(row))
        end
      end

      # Natures et table de correspondance par défaut
      # (`src/liberal/data/defaults.yml`), libellés dans la langue `locale` ;
      # ce qui existe est conservé. Renvoie le nombre de lignes créées.
      def self.load_defaults(actor : Actor, locale : String = "fr") : Int32
        Guard.authorize!(actor, SETTINGS_WRITE, module_code: MODULE_CODE)
        count = 0
        Transaction.run do
          count = FormLines.load_defaults(locale)
          Result(Nil).success(nil)
        end
        count
      end

      # --- Natures ----------------------------------------------------------------------

      def self.natures(actor : Actor, kind : String? = nil, enabled_only : Bool = false) : Array(NatureView)
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        rows = Partiduo::Liberal::Nature.all
        rows = rows.filter(kind: kind) if kind
        rows = rows.filter(enabled: true) if enabled_only
        rows.order(:kind, :code).to_a.map { |row| Registers.nature_view(row) }
      end

      def self.create_nature(actor : Actor, input : NatureInput) : Result(NatureView)
        Guard.authorize!(actor, SETTINGS_WRITE, module_code: MODULE_CODE)
        Transaction.run do
          errors = nature_errors(input, nil)
          next Result(NatureView).failure(errors) unless errors.empty?
          row = Partiduo::Liberal::Nature.create!(code: input.code.strip.upcase, label: input.label.strip,
            kind: input.kind, heading: input.heading, enabled: input.enabled)
          Result(NatureView).success(Registers.nature_view(row))
        end
      end

      # Libellé et activation seulement une fois la nature employée : son
      # code, son sens et sa rubrique sont figés par le livre-journal.
      def self.update_nature(actor : Actor, id : Int64, input : NatureInput) : Result(NatureView)
        Guard.authorize!(actor, SETTINGS_WRITE, module_code: MODULE_CODE)
        Transaction.run do
          row = Partiduo::Liberal::Nature.filter(id: id).lock.first || raise NotFound.new("liberal_nature", id)
          errors = nature_errors(input, id)
          used = Partiduo::Liberal::Line.filter(nature_id: id).exists?
          if used && (input.code.strip.upcase != row.code || input.kind != row.kind || input.heading != row.heading)
            errors << Registers.error("code", "nature.in_use")
          end
          next Result(NatureView).failure(errors) unless errors.empty?
          row.code = input.code.strip.upcase
          row.label = input.label.strip
          row.kind = input.kind
          row.heading = input.heading
          row.enabled = input.enabled
          row.save!
          Result(NatureView).success(Registers.nature_view(row))
        end
      end

      private def self.nature_errors(input : NatureInput, id : Int64?) : Array(FieldError)
        errors = [] of FieldError
        code = input.code.strip.upcase
        errors << Registers.error("code", "nature.code.invalid") unless code.matches?(/\A[A-Z][A-Z0-9_]{0,31}\z/)
        duplicate = Partiduo::Liberal::Nature.filter(code: code)
        duplicate = duplicate.exclude(id: id) if id
        errors << Registers.error("code", "nature.code.taken") if duplicate.exists?
        errors << Registers.error("label", "nature.label.blank") if input.label.strip.empty?
        errors << Registers.error("label", "line.too_long", {"max" => "100"}) if input.label.size > 100
        if !KINDS.includes?(input.kind)
          errors << Registers.error("kind", "nature.kind.invalid")
        elsif !(input.kind == "receipt" ? RECEIPT_HEADINGS : EXPENSE_HEADINGS).includes?(input.heading)
          errors << Registers.error("heading", "nature.heading.invalid")
        end
        errors
      end

      # --- Table de correspondance ------------------------------------------------------

      # Lignes de la table ; `millesime` donné : celles en vigueur pour ce
      # millésime (une par poste).
      def self.form_lines(actor : Actor, millesime : Int32? = nil) : Array(FormLineView)
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        if year = millesime
          FormLines.for_year(year).values.sort_by! { |row| ITEMS.index(row.item.to_s) || ITEMS.size }.map { |row| FormLines.view(row) }
        else
          Partiduo::Liberal::FormLine.all.order(:millesime, :item).to_a.map { |row| FormLines.view(row) }
        end
      end

      # Crée ou remplace la ligne du poste `item` à partir du millésime
      # `millesime`. Refus : millésime au plus égal à une année close
      # (`form_line.year.closed`, corriger par une ligne au millésime
      # suivant), case déjà prise par un autre poste du même formulaire
      # (`form_line.box.taken`).
      def self.set_form_line(actor : Actor, input : FormLineInput) : Result(FormLineView)
        Guard.authorize!(actor, SETTINGS_WRITE, module_code: MODULE_CODE)
        Transaction.run do
          errors = FormLines.errors(input)
          next Result(FormLineView).failure(errors) unless errors.empty?
          row = Partiduo::Liberal::FormLine.filter(millesime: input.millesime, item: input.item).first ||
                Partiduo::Liberal::FormLine.new(millesime: input.millesime, item: input.item)
          row.form = input.form
          row.line = input.line.strip
          row.box = input.box.strip.upcase
          row.save!
          Result(FormLineView).success(FormLines.view(row))
        end
      end

      # Supprime une ligne d'un millésime postérieur à toute année close.
      def self.delete_form_line(actor : Actor, id : Int64) : Result(Nil)
        Guard.authorize!(actor, SETTINGS_WRITE, module_code: MODULE_CODE)
        Transaction.run do
          row = Partiduo::Liberal::FormLine.filter(id: id).first || raise NotFound.new("liberal_form_line", id)
          if FormLines.closed?((row.millesime || 0).to_i32)
            next Result(Nil).failure(Registers.error("millesime", "form_line.year.closed"))
          end
          row.delete
          Result(Nil).success(nil)
        end
      end

      # --- Livre-journal ----------------------------------------------------------------

      def self.lines(actor : Actor, query : JournalQuery = JournalQuery.new) : Array(LineView)
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        Registers.views(Registers.query(query).offset(query.offset).limit(query.bounded_limit).to_a)
      end

      def self.line(actor : Actor, id : Int64) : LineView
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        Registers.view(Partiduo::Liberal::Line.filter(id: id).first || raise NotFound.new("liberal_line", id))
      end

      # Requête de contrôle de `record_receipt`.
      def self.check_receipt(actor : Actor, input : LineInput) : Result(Nil)
        Guard.authorize!(actor, WRITE, module_code: MODULE_CODE)
        errors = Registers.line_errors("receipt", input, actor: actor)
        errors.empty? ? Result(Nil).success(nil) : Result(Nil).failure(errors)
      end

      # Inscrit une recette encaissée et publie `liberal.receipt.recorded`.
      def self.record_receipt(actor : Actor, input : LineInput) : Result(LineView)
        record_line(actor, "receipt", input)
      end

      # Requête de contrôle de `record_expense`.
      def self.check_expense(actor : Actor, input : LineInput) : Result(Nil)
        Guard.authorize!(actor, WRITE, module_code: MODULE_CODE)
        errors = Registers.line_errors("expense", input, actor: actor)
        errors.empty? ? Result(Nil).success(nil) : Result(Nil).failure(errors)
      end

      # Inscrit une dépense payée et publie `liberal.expense.recorded`.
      def self.record_expense(actor : Actor, input : LineInput) : Result(LineView)
        record_line(actor, "expense", input)
      end

      private def self.record_line(actor : Actor, kind : String, input : LineInput) : Result(LineView)
        Guard.authorize!(actor, WRITE, module_code: MODULE_CODE)
        Transaction.run do
          errors = Registers.line_errors(kind, input, actor: actor)
          next Result(LineView).failure(errors) unless errors.empty?
          Result(LineView).success(Registers.view(Registers.create_line!(kind, input, actor.user_id)))
        end
      end

      # Modifie une ligne d'un exercice ouvert — ni clôturé, ni 2035
      # transmise, hors période close —, saisie directement, ni contre-passée
      # ni contre-passation (DECISIONS D-LIB2-001) ; mêmes contrôles que la
      # saisie, même sens, la nouvelle date aussi dans un exercice ouvert.
      # Publie `liberal.receipt.updated` ou `liberal.expense.updated` : la
      # Comptabilité remplace son écriture ou refuse, et rien n'est alors
      # modifié (DECISIONS D-LIB2-002).
      def self.update_line(actor : Actor, id : Int64, input : LineInput) : Result(LineView)
        Guard.authorize!(actor, WRITE, module_code: MODULE_CODE)
        Transaction.run do
          row = Partiduo::Liberal::Line.filter(id: id).lock.first || raise NotFound.new("liberal_line", id)
          errors = Registers.change_errors(row, update: true)
          errors.concat(Registers.line_errors(row.kind.to_s, input, actor: actor)) if errors.empty?
          next Result(LineView).failure(errors) unless errors.empty?
          refused(Result(LineView)) { Result(LineView).success(Registers.view(Registers.update_line!(row, input, actor.user_id))) }
        end
      end

      # Supprime une ligne d'un exercice ouvert (mêmes conditions que la
      # modification ; une contre-passation se supprime) ; publie
      # `liberal.receipt.deleted` ou `liberal.expense.deleted`.
      def self.delete_line(actor : Actor, id : Int64) : Result(Nil)
        Guard.authorize!(actor, WRITE, module_code: MODULE_CODE)
        Transaction.run do
          row = Partiduo::Liberal::Line.filter(id: id).lock.first || raise NotFound.new("liberal_line", id)
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

      # Contre-passation datée d'une ligne (montants opposés, même nature,
      # même tiers), dans un exercice ouvert : seule correction d'une ligne
      # d'un exercice figé ; publie l'événement de son sens.
      def self.reverse_line(actor : Actor, input : ReverseInput) : Result(LineView)
        Guard.authorize!(actor, WRITE, module_code: MODULE_CODE)
        Transaction.run do
          row = Partiduo::Liberal::Line.filter(id: input.id).lock.first || raise NotFound.new("liberal_line", input.id)
          errors = Registers.reverse_errors(row, input)
          next Result(LineView).failure(errors) unless errors.empty?
          Result(LineView).success(Registers.view(Registers.reverse!(row, input, actor.user_id)))
        end
      end

      # Totaux sur toute la requête (sans pagination).
      def self.journal_totals(actor : Actor, query : JournalQuery = JournalQuery.new) : TotalsView
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        Registers.totals(query)
      end

      # Ventilation de l'année civile par rubrique.
      def self.heading_totals(actor : Actor, year : Int32) : Array(HeadingTotalView)
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        Registers.heading_totals(year)
      end

      def self.export_journal(actor : Actor, query : JournalQuery, format : ExportFormat) : FileView
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        Partiduo::Liberal::Output.journal(Registers.views(Registers.query(query).to_a), query, format)
      end

      # --- Immobilisations --------------------------------------------------------------

      # Registre des immobilisations ; `year` donné : celles qui comptent
      # dans la 2035-B de l'année (vivantes, non cédées avant elle).
      def self.assets(actor : Actor, year : Int32? = nil) : Array(AssetView)
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        return Assets.live(year) if year
        Assets.views(Partiduo::Liberal::Asset.all.order(:acquired_on, :number).to_a)
      end

      def self.asset(actor : Actor, id : Int64) : AssetView
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        Assets.view(Partiduo::Liberal::Asset.filter(id: id).first || raise NotFound.new("liberal_asset", id))
      end

      def self.check_asset(actor : Actor, input : AssetInput) : Result(Nil)
        Guard.authorize!(actor, WRITE, module_code: MODULE_CODE)
        errors = Assets.errors(input, actor)
        errors.empty? ? Result(Nil).success(nil) : Result(Nil).failure(errors)
      end

      # Inscrit une immobilisation et publie `liberal.asset.recorded`
      # (`operation` `acquisition`).
      def self.record_asset(actor : Actor, input : AssetInput) : Result(AssetView)
        Guard.authorize!(actor, WRITE, module_code: MODULE_CODE)
        Transaction.run do
          errors = Assets.errors(input, actor)
          next Result(AssetView).failure(errors) unless errors.empty?
          Result(AssetView).success(Assets.view(Assets.create!(input, actor.user_id)))
        end
      end

      # Modifie une immobilisation acquise dans un exercice ouvert, sans
      # contre-passation ni cession, qu'aucune année figée postérieure ne
      # compte (DECISIONS D-LIB2-004) ; mêmes contrôles que l'inscription.
      # Publie `liberal.asset.updated` : la Comptabilité remplace son
      # écriture ou refuse.
      def self.update_asset(actor : Actor, id : Int64, input : AssetInput) : Result(AssetView)
        Guard.authorize!(actor, WRITE, module_code: MODULE_CODE)
        Transaction.run do
          row = Partiduo::Liberal::Asset.filter(id: id).lock.first || raise NotFound.new("liberal_asset", id)
          errors = Assets.change_errors(row, update: true)
          errors.concat(Assets.errors(input, actor)) if errors.empty?
          next Result(AssetView).failure(errors) unless errors.empty?
          refused(Result(AssetView)) { Result(AssetView).success(Assets.view(Assets.update!(row, input, actor.user_id))) }
        end
      end

      # Supprime une immobilisation (ou une contre-passation d'immobilisation)
      # aux mêmes conditions ; publie `liberal.asset.deleted`.
      def self.delete_asset(actor : Actor, id : Int64) : Result(Nil)
        Guard.authorize!(actor, WRITE, module_code: MODULE_CODE)
        Transaction.run do
          row = Partiduo::Liberal::Asset.filter(id: id).lock.first || raise NotFound.new("liberal_asset", id)
          errors = Assets.change_errors(row, update: false)
          next Result(Nil).failure(errors) unless errors.empty?
          refused(Result(Nil)) do
            Assets.delete!(row, actor.user_id)
            Result(Nil).success(nil)
          end
        end
      end

      # Supprime la cession d'une immobilisation, datée dans un exercice
      # ouvert qu'aucune année figée postérieure ne suit ; publie
      # `liberal.asset.deleted` (`operation` `disposal`). L'immobilisation
      # redevient modifiable ou cessible.
      def self.delete_disposal(actor : Actor, asset_id : Int64) : Result(AssetView)
        Guard.authorize!(actor, WRITE, module_code: MODULE_CODE)
        Transaction.run do
          Partiduo::Liberal::Asset.filter(id: asset_id).lock.first || raise NotFound.new("liberal_asset", asset_id)
          disposal = Partiduo::Liberal::Disposal.filter(asset_id: asset_id).first
          next Result(AssetView).failure(Registers.error("asset_id", "disposal.none")) unless disposal
          errors = Assets.disposal_change_errors(disposal)
          next Result(AssetView).failure(errors) unless errors.empty?
          refused(Result(AssetView)) do
            Assets.delete_disposal!(disposal, actor.user_id)
            Result(AssetView).success(Assets.view(Partiduo::Liberal::Asset.get!(id: asset_id)))
          end
        end
      end

      # Contre-passation d'une immobilisation la même année que son
      # acquisition (`operation` `reversal`).
      def self.reverse_asset(actor : Actor, input : ReverseInput) : Result(AssetView)
        Guard.authorize!(actor, WRITE, module_code: MODULE_CODE)
        Transaction.run do
          row = Partiduo::Liberal::Asset.filter(id: input.id).lock.first || raise NotFound.new("liberal_asset", input.id)
          errors = Assets.reverse_errors(row, input)
          next Result(AssetView).failure(errors) unless errors.empty?
          Result(AssetView).success(Assets.view(Assets.reverse!(row, input, actor.user_id)))
        end
      end

      # Cession d'une immobilisation (`operation` `disposal`) : prix encaissé,
      # plus ou moins-value à la 2035-A et à la 2035-B de l'année.
      def self.dispose_asset(actor : Actor, input : DisposalInput) : Result(AssetView)
        Guard.authorize!(actor, WRITE, module_code: MODULE_CODE)
        Transaction.run do
          Partiduo::Liberal::Asset.filter(id: input.asset_id).lock.first
          errors = Assets.disposal_errors(input)
          next Result(AssetView).failure(errors) unless errors.empty?
          disposal = Assets.dispose!(input, actor.user_id)
          Result(AssetView).success(Assets.view(Partiduo::Liberal::Asset.get!(id: disposal.asset_id)))
        end
      end

      # Plus ou moins-value (court et long terme) de la cession d'une
      # immobilisation, `nil` si elle n'est pas cédée.
      def self.disposal_result(actor : Actor, asset_id : Int64) : DisposalResultView?
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        Assets.disposal_result(asset(actor, asset_id))
      end

      # Tableau des immobilisations et amortissements de l'année (2035-B).
      def self.depreciation(actor : Actor, year : Int32) : Array(DepreciationRowView)
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        Assets.depreciation(year)
      end

      # Plan d'amortissement d'une immobilisation : annuité par année.
      def self.schedule(actor : Actor, id : Int64) : Array({Int32, BigDecimal})
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        Assets.schedule(asset(actor, id))
      end

      # --- Réintégrations et déductions -------------------------------------------------

      def self.adjustments(actor : Actor, year : Int32) : Array(AdjustmentView)
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        Partiduo::Liberal::Adjustments.views(Partiduo::Liberal::Adjustment.filter(year: year).order(:id).to_a)
      end

      def self.add_adjustment(actor : Actor, input : AdjustmentInput) : Result(AdjustmentView)
        Guard.authorize!(actor, WRITE, module_code: MODULE_CODE)
        Transaction.run do
          errors = Partiduo::Liberal::Adjustments.errors(input)
          next Result(AdjustmentView).failure(errors) unless errors.empty?
          row = Partiduo::Liberal::Adjustment.create!(year: input.year, kind: input.kind, label: input.label.strip,
            amount: input.amount, recorded_by_id: actor.user_id, recorded_at: Time.utc)
          Result(AdjustmentView).success(Partiduo::Liberal::Adjustments.views([row]).first)
        end
      end

      # Retire une réintégration ou une déduction d'une année encore ouverte.
      def self.delete_adjustment(actor : Actor, id : Int64) : Result(Nil)
        Guard.authorize!(actor, WRITE, module_code: MODULE_CODE)
        Transaction.run do
          row = Partiduo::Liberal::Adjustment.filter(id: id).first || raise NotFound.new("liberal_adjustment", id)
          if Partiduo::Liberal::Adjustments.closed?((row.year || 0).to_i32)
            next Result(Nil).failure(Registers.error("year", "adjustment.year.closed"))
          end
          row.delete
          Result(Nil).success(nil)
        end
      end

      # --- Exercices ----------------------------------------------------------------------

      # État de l'exercice `year` : ouvert, clôturé au socle (date), 2035
      # transmise (date, référence du dépôt). Plusieurs exercices peuvent
      # être ouverts à la fois.
      def self.year(actor : Actor, year : Int32) : YearView
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        Partiduo::Liberal::Years.view(year)
      end

      # --- 2035 -------------------------------------------------------------------------

      # 2035, 2035-A et 2035-B préparées pour l'année civile `year`, avec les
      # contrôles de cohérence (`ready?`), l'empreinte et l'état de
      # l'exercice : recalculées à chaque lecture tant qu'il est ouvert,
      # inchangées une fois figé (DECISIONS D-LIB2-005). C'est la requête que
      # lit `partiduo-teledec` pour transmettre la déclaration ; la
      # transmission, publiée par `tax_return.transmitted`, fige l'exercice.
      def self.tax_return(actor : Actor, year : Int32) : TaxReturnView
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        Partiduo::Liberal::TaxReturn.prepare(year)
      end

      # Édition de contrôle de la 2035 préparée (PDF/A-2b).
      def self.export_tax_return(actor : Actor, year : Int32) : FileView
        Guard.authorize!(actor, READ, module_code: MODULE_CODE)
        Partiduo::Liberal::Output.tax_return(Partiduo::Liberal::TaxReturn.prepare(year))
      end

      # Republie les événements du livre-journal et des immobilisations
      # (Comptabilité activée plus tard) ; renvoie le nombre d'événements.
      def self.republish(actor : Actor) : Int32
        Guard.authorize!(actor, SETTINGS_WRITE, module_code: MODULE_CODE)
        count = 0
        Transaction.run do
          count = Registers.republish(actor.user_id) + Assets.republish(actor.user_id)
          Result(Nil).success(nil)
        end
        count
      end
    end
  end
end
