# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Micro
    # Livre des recettes et registre des achats (ADR-007 D1) : contrôle,
    # numérotation chronologique par année sous verrou, inscription,
    # contre-passation, vues, publication de `micro.receipt.recorded` et
    # `micro.purchase.recorded` (ADR-007 D2). Service interne : le contrat
    # `Partiduo::Api::Micro` l'appelle.
    #
    # Période d'une ligne : la période de déclaration URSSAF (mois ou
    # trimestre) qui contient sa date. Tant qu'elle n'est ni déclarée
    # (`micro_declaration`) ni close au socle, une ligne saisie se modifie
    # et se supprime (`micro.*.updated`, `micro.*.deleted`) ; ensuite, elle
    # est intangible et une erreur se corrige par une contre-passation
    # datée dans une période ouverte (déclencheur `micro_register_guard`,
    # D-MIC2-001).
    module Registers
      alias FieldError = Partiduo::Api::FieldError
      alias Api = Partiduo::Api::Micro

      PREFIXES = {"receipt" => "R", "purchase" => "A"}

      def self.system : Partiduo::Api::Actor
        Partiduo::Api::Actor.system
      end

      def self.error(field : String, code : String, params : Hash(String, String) = {} of String => String) : FieldError
        FieldError.new(field, "micro.errors.#{code}", params)
      end

      def self.day(time : Time) : Time
        Time.utc(time.year, time.month, time.day)
      end

      # --- Paramètres ---------------------------------------------------------------

      def self.settings : Settings
        Settings.all.order(:id).first || Settings.create!(periodicity: "quarterly", flat_tax: false)
      end

      def self.settings_view(row : Settings = settings) : Api::SettingsView
        Api::SettingsView.new(row.periodicity.to_s, row.flat_tax || false, row.activity_started_on, row.default_nature_id.try(&.to_i64),
          row.vat_liable_since, row.real_regime_since)
      end

      def self.nature_view(nature : Nature) : Api::NatureView
        Api::NatureView.new(nature.pk!.as(Int64), nature.code.to_s, nature.label.to_s, nature.kind.to_s,
          nature.category.to_s, nature.enabled || false)
      end

      # --- Contrôle -------------------------------------------------------------------

      # Règles communes d'une saisie : date (hors période close, pas dans le
      # futur pour une saisie directe), nature active du bon sens, montant
      # positif au centime, mode de règlement, fiche existante, pièce jointe
      # visible de l'acteur (voir `attachment_errors`), longueurs.
      def self.line_errors(register : String, date : Time, nature_id : Int64, amount : BigDecimal, method : String,
                           card_id : Int64?, party_name : String, label : String, reference : String,
                           attachment_id : Int64?, manual : Bool = true,
                           actor : Partiduo::Api::Actor = system) : Array(FieldError)
        errors = [] of FieldError
        date_errors(date, manual).each { |error| errors << error }
        nature = Nature.filter(id: nature_id).first
        if nature.nil? || nature.kind != register
          errors << error("nature_id", "line.nature.unknown")
        elsif !nature.enabled
          errors << error("nature_id", "line.nature.disabled")
        end
        errors.concat(amount_errors("amount", amount))
        errors << error("method", "line.method.invalid") unless Api::METHODS.includes?(method)
        if id = card_id
          begin
            Partiduo::Api::Cards.card(system, id)
          rescue Partiduo::Api::NotFound
            errors << error("card_id", "line.card.unknown")
          end
        end
        errors << error("party_name", "line.too_long", {"max" => "255"}) if party_name.size > 255
        errors << error("label", "line.too_long", {"max" => "255"}) if label.size > 255
        errors << error("reference", "line.too_long", {"max" => "100"}) if reference.size > 100
        attachment_id.try { |attachment| errors.concat(attachment_errors(attachment, actor)) }
        errors
      end

      # Pièce jointe rattachable par l'acteur : il peut lire les pièces
      # jointes du dossier (`core.attachment.read`), ou il l'a déposée
      # lui-même (photo du justificatif prise à la saisie). Sinon, elle est
      # dite inconnue, sans dévoiler qu'elle existe.
      def self.attachment_errors(id : Int64, actor : Partiduo::Api::Actor) : Array(FieldError)
        view = Partiduo::Api::Core.attachment(system, id)
        allowed = actor.can?("core.attachment.read") || (!actor.user_id.nil? && view.uploaded_by_id == actor.user_id)
        allowed ? [] of FieldError : [error("attachment_id", "line.attachment.unknown")]
      rescue Partiduo::Api::NotFound
        [error("attachment_id", "line.attachment.unknown")]
      end

      # TVA comprise : positive ou nulle, au centime, inférieure au montant.
      def self.vat_errors(amount : BigDecimal, vat_amount : BigDecimal) : Array(FieldError)
        if vat_amount < 0 || vat_amount.round(2) != vat_amount
          [error("vat_amount", "line.vat_amount.invalid")]
        elsif amount > 0 && vat_amount >= amount
          [error("vat_amount", "line.vat_amount.exceeds")]
        else
          [] of FieldError
        end
      end

      def self.amount_errors(field : String, amount : BigDecimal) : Array(FieldError)
        return [error(field, "line.amount.not_positive")] if amount <= 0
        return [error(field, "line.amount.scale")] if amount.round(2) != amount
        [] of FieldError
      end

      # Date dans une période close du socle ou dans une période URSSAF
      # déclarée : refusée ; dans le futur : refusée pour une saisie directe
      # (on n'inscrit qu'un encaissement ou un paiement fait).
      def self.date_errors(date : Time, manual : Bool = true) : Array(FieldError)
        errors = [] of FieldError
        if manual && day(date) > Partiduo::Config.today
          errors << error("date", "line.date.future")
        end
        if closed?(date)
          errors << error("date", "line.date.closed_period")
        elsif declared?(date)
          errors << error("date", "line.date.declared_period")
        end
        errors
      end

      # Date dans une période close du socle.
      def self.closed?(date : Time) : Bool
        Partiduo::Api::Core.period_for(system, day(date)).try(&.closed?) || false
      end

      # Déclaration URSSAF notée dont la période contient `date`.
      def self.declaration_for(date : Time) : Declaration?
        on = day(date)
        Declaration.filter(starts_on__lte: on, ends_on__gte: on).first
      end

      def self.declared?(date : Time) : Bool
        !declaration_for(date).nil?
      end

      def self.receipt_errors(input : Api::ReceiptInput, manual : Bool = true,
                              actor : Partiduo::Api::Actor = system) : Array(FieldError)
        errors = line_errors("receipt", input.date, input.nature_id, input.amount, input.method, input.card_id,
          input.party_name, input.label, input.reference, input.attachment_id, manual, actor)
        errors.concat(vat_errors(input.amount, input.vat_amount))
      end

      def self.purchase_errors(input : Api::PurchaseInput, actor : Partiduo::Api::Actor = system) : Array(FieldError)
        errors = line_errors("purchase", input.date, input.nature_id, input.amount, input.method, input.card_id,
          input.party_name, input.label, input.reference, input.attachment_id, actor: actor)
        errors.concat(vat_errors(input.amount, input.vat_amount))
      end

      # --- Inscription ----------------------------------------------------------------

      # Numéro suivant du registre pour l'année de `date` (`R2026-00001`),
      # sous verrou de la ligne de compteur.
      def self.next_number(register : String, date : Time) : String
        year = date.year
        Marten::DB::Connection.default.open do |db|
          db.exec("INSERT INTO micro_counter (register, year, next_number) VALUES ($1, $2, 1) " \
                  "ON CONFLICT (register, year) DO NOTHING", register, year)
        end
        counter = Counter.filter(register: register, year: year).lock.first || raise "compteur absent"
        number = counter.next_number || 1
        counter.next_number = number + 1
        counter.save!
        "#{PREFIXES[register]}#{year}-#{number.to_s.rjust(5, '0')}"
      end

      def self.nature!(id : Int64) : Nature
        Nature.filter(id: id).first || raise Partiduo::Api::NotFound.new("micro_nature", id)
      end

      # Inscrit une recette contrôlée et publie `micro.receipt.recorded`.
      def self.create_receipt!(input : Api::ReceiptInput, actor_user_id : Int64?, origin : String = "manual",
                               source : String = "", reversal_of_id : Int64? = nil) : Receipt
        nature = nature!(input.nature_id)
        receipt = Receipt.create!(
          number: next_number("receipt", input.date), date: day(input.date), nature_id: input.nature_id,
          category: nature.category, amount: input.amount, vat_amount: input.vat_amount, method: input.method,
          card_id: input.card_id, party_name: party_name(input.card_id, input.party_name), label: input.label.strip,
          reference: input.reference.strip, attachment_id: input.attachment_id, origin: origin, source: source,
          reversal_of_id: reversal_of_id, recorded_by_id: actor_user_id, recorded_at: Time.utc)
        publish_receipt(receipt, nature, actor_user_id)
        receipt
      end

      # Inscrit un achat contrôlé et publie `micro.purchase.recorded`.
      def self.create_purchase!(input : Api::PurchaseInput, actor_user_id : Int64?,
                                reversal_of_id : Int64? = nil) : Purchase
        nature = nature!(input.nature_id)
        purchase = Purchase.create!(
          number: next_number("purchase", input.date), date: day(input.date), nature_id: input.nature_id,
          category: nature.category, amount: input.amount, vat_amount: input.vat_amount, method: input.method,
          card_id: input.card_id,
          party_name: party_name(input.card_id, input.party_name), label: input.label.strip,
          reference: input.reference.strip, attachment_id: input.attachment_id, reversal_of_id: reversal_of_id,
          recorded_by_id: actor_user_id, recorded_at: Time.utc)
        publish_purchase(purchase, nature, actor_user_id)
        purchase
      end

      # Nom du tiers : celui saisi, sinon celui de la fiche.
      def self.party_name(card_id : Int64?, name : String) : String
        text = name.strip
        return text unless text.empty?
        card_id.try { |id| Partiduo::Api::Cards.card(system, id).name } || ""
      rescue Partiduo::Api::NotFound
        ""
      end

      # --- Modification et suppression (période ouverte, D-MIC2-001) ----------------

      # Ligne qui ne se modifie ni ne se supprime : issue de la Facturation
      # (la corriger là, ou la contre-passer), déjà contre-passée (supprimer
      # d'abord sa contre-passation), ou d'une période close ou déclarée
      # (la contre-passer). Une contre-passation se supprime mais ne se
      # modifie pas (`update` vrai : modification).
      def self.change_errors(row : Receipt | Purchase, update : Bool) : Array(FieldError)
        errors = [] of FieldError
        errors << error("id", "line.change.from_invoicing") if row.is_a?(Receipt) && row.origin != "manual"
        errors << error("id", "line.change.is_reversal") if update && row.reversal_of_id
        errors << error("id", "line.change.reversed") if reversed?(row)
        if closed?(row.date!)
          errors << error("id", "line.change.closed_period")
        elsif declared?(row.date!)
          errors << error("id", "line.change.declared_period")
        end
        errors
      end

      # Modifie une recette d'une période ouverte (contrôles faits par le
      # contrat) et publie `micro.receipt.updated` : la Comptabilité remplace
      # son écriture, ou refuse (`Partiduo::Events::Refused`). Changer
      # d'année renumérote la ligne dans la nouvelle année.
      def self.update_receipt!(row : Receipt, input : Api::ReceiptInput, actor_user_id : Int64?) : Receipt
        nature = nature!(input.nature_id)
        row.number = next_number("receipt", input.date) if day(input.date).year != row.date!.year
        row.date = day(input.date)
        row.nature_id = input.nature_id
        row.category = nature.category
        row.amount = input.amount
        row.vat_amount = input.vat_amount
        row.method = input.method
        row.card_id = input.card_id
        row.party_name = party_name(input.card_id, input.party_name)
        row.label = input.label.strip
        row.reference = input.reference.strip
        row.attachment_id = input.attachment_id
        row.modified_at = Time.utc
        row.modified_by_id = actor_user_id
        row.save!
        publish_receipt(row, nature, actor_user_id, "micro.receipt.updated")
        row
      end

      def self.update_purchase!(row : Purchase, input : Api::PurchaseInput, actor_user_id : Int64?) : Purchase
        nature = nature!(input.nature_id)
        row.number = next_number("purchase", input.date) if day(input.date).year != row.date!.year
        row.date = day(input.date)
        row.nature_id = input.nature_id
        row.category = nature.category
        row.amount = input.amount
        row.vat_amount = input.vat_amount
        row.method = input.method
        row.card_id = input.card_id
        row.party_name = party_name(input.card_id, input.party_name)
        row.label = input.label.strip
        row.reference = input.reference.strip
        row.attachment_id = input.attachment_id
        row.modified_at = Time.utc
        row.modified_by_id = actor_user_id
        row.save!
        publish_purchase(row, nature, actor_user_id, "micro.purchase.updated")
        row
      end

      # Supprime une ligne d'une période ouverte et publie
      # `micro.receipt.deleted` ou `micro.purchase.deleted` : la Comptabilité
      # extourne l'écriture passée, ou refuse. Le numéro n'est pas repris.
      def self.delete!(row : Receipt | Purchase, actor_user_id : Int64?) : Nil
        receipt = row.is_a?(Receipt)
        payload = {
          "number" => row.number.to_s,
          "date"   => row.date!.to_s("%Y-%m-%d"),
          "origin" => row.is_a?(Receipt) ? row.origin.to_s : "manual",
        }
        payload[receipt ? "receipt_id" : "purchase_id"] = row.pk!.to_s
        row.delete
        Partiduo::Events.publish(receipt ? "micro.receipt.deleted" : "micro.purchase.deleted", payload,
          actor_user_id: actor_user_id)
      end

      # --- Contre-passation -----------------------------------------------------------

      # Erreurs d'une contre-passation : ligne existante, ni elle-même une
      # contre-passation, ni déjà contre-passée ; date au plus tôt celle de
      # la ligne, hors période close et, pour une contre-passation saisie
      # (`manual`), pas à venir (D-TST-G-001).
      def self.reverse_errors(row : Receipt | Purchase, input : Api::ReverseInput,
                              manual : Bool = true) : Array(FieldError)
        errors = [] of FieldError
        errors << error("id", "line.reversal.is_reversal") if row.reversal_of_id
        errors << error("id", "line.reversal.already") if reversed?(row)
        errors << error("date", "line.reversal.before_line") if day(input.date) < row.date!
        errors.concat(date_errors(input.date, manual: manual))
        errors << error("label", "line.too_long", {"max" => "255"}) if input.label.size > 255
        errors
      end

      # Contre-passation d'une recette. Saisie par le contrat (`manual`) :
      # origine `manual` même pour une recette issue de la Facturation (sa
      # source est gardée pour la traçabilité), pour que la Comptabilité en
      # passe l'écriture inverse — un remboursement sort de la banque
      # (D-MIC-011). Celle du délettrage (`manual` faux) garde l'origine
      # `invoicing` : le délettrage a déjà défait l'encaissement en
      # Comptabilité.
      def self.reverse_receipt!(row : Receipt, input : Api::ReverseInput, actor_user_id : Int64?,
                                manual : Bool = true) : Receipt
        label = input.label.strip.presence || default_reversal_label(row.number.to_s)
        reversal = Api::ReceiptInput.new(date: input.date, nature_id: row.nature_id!.to_i64, amount: -row.amount!,
          method: row.method.to_s, card_id: row.card_id.try(&.to_i64), party_name: row.party_name.to_s, label: label,
          reference: row.number.to_s, attachment_id: nil, vat_amount: -row.vat_amount!)
        create_receipt!(reversal, actor_user_id, manual ? "manual" : row.origin.to_s, row.source.to_s, row.pk!.as(Int64))
      end

      def self.reverse_purchase!(row : Purchase, input : Api::ReverseInput, actor_user_id : Int64?) : Purchase
        label = input.label.strip.presence || default_reversal_label(row.number.to_s)
        reversal = Api::PurchaseInput.new(date: input.date, nature_id: row.nature_id!.to_i64, amount: -row.amount!,
          method: row.method.to_s, card_id: row.card_id.try(&.to_i64), party_name: row.party_name.to_s, label: label,
          reference: row.number.to_s, vat_amount: -row.vat_amount!)
        create_purchase!(reversal, actor_user_id, row.pk!.as(Int64))
      end

      # Libellé par défaut, dans la langue de l'instance au moment de
      # l'inscription (le registre garde un texte, pas une clé).
      def self.default_reversal_label(number : String) : String
        I18n.t("micro.reversal_label", {"number" => number})
      end

      # --- Événements -------------------------------------------------------------------

      # Charge utile de quoi passer l'écriture sans relire le module
      # (ADR-006 D3, D-MIC-002).
      def self.publish_receipt(row : Receipt, nature : Nature, actor_user_id : Int64?,
                               name : String = "micro.receipt.recorded") : Nil
        Partiduo::Events.publish(name, common_payload(row, nature).merge({
          "receipt_id" => row.pk!.to_s,
          "vat_amount" => row.vat_amount!.to_s,
          "origin"     => row.origin.to_s,
          "source"     => row.source.to_s,
        }), actor_user_id: actor_user_id)
      end

      def self.publish_purchase(row : Purchase, nature : Nature, actor_user_id : Int64?,
                                name : String = "micro.purchase.recorded") : Nil
        Partiduo::Events.publish(name, common_payload(row, nature).merge({
          "purchase_id" => row.pk!.to_s,
          "vat_amount"  => row.vat_amount!.to_s,
          "origin"      => "manual",
        }), actor_user_id: actor_user_id)
      end

      private def self.common_payload(row : Receipt | Purchase, nature : Nature) : Hash(String, String)
        {
          "number"         => row.number.to_s,
          "date"           => row.date!.to_s("%Y-%m-%d"),
          "amount"         => row.amount!.to_s,
          "nature_code"    => nature.code.to_s,
          "category"       => row.category.to_s,
          "method"         => row.method.to_s,
          "card_id"        => row.card_id.to_s,
          "party_name"     => row.party_name.to_s,
          "label"          => row.label.to_s.presence || nature.label.to_s,
          "reference"      => row.reference.to_s,
          "attachment_id"  => row.attachment_id.to_s,
          "reversal_of_id" => row.reversal_of_id.to_s,
        }
      end

      # Republie les événements de toutes les lignes, dans l'ordre (la
      # Comptabilité activée plus tard les comptabilise ; elle ignore une
      # ligne déjà passée). Renvoie le nombre de lignes publiées.
      def self.republish(actor_user_id : Int64?) : Int32
        natures = Nature.all.to_a.index_by(&.pk!.as(Int64))
        count = 0
        Receipt.all.order(:id).each do |row|
          publish_receipt(row, natures[row.nature_id!.to_i64], actor_user_id)
          count += 1
        end
        Purchase.all.order(:id).each do |row|
          publish_purchase(row, natures[row.nature_id!.to_i64], actor_user_id)
          count += 1
        end
        count
      end

      # --- Vues -------------------------------------------------------------------------

      def self.reversed?(row : Receipt) : Bool
        Receipt.filter(reversal_of_id: row.pk).exists?
      end

      def self.reversed?(row : Purchase) : Bool
        Purchase.filter(reversal_of_id: row.pk).exists?
      end

      def self.receipt_query(query : Api::RegisterQuery)
        rows = Receipt.all
        if from = query.from
          rows = rows.filter(date__gte: day(from))
        end
        if to = query.to
          rows = rows.filter(date__lte: day(to))
        end
        rows = rows.filter(nature_id: query.nature_id) if query.nature_id
        rows = rows.filter(category: query.category) if query.category
        rows.order(:date, :number)
      end

      def self.purchase_query(query : Api::RegisterQuery)
        rows = Purchase.all
        if from = query.from
          rows = rows.filter(date__gte: day(from))
        end
        if to = query.to
          rows = rows.filter(date__lte: day(to))
        end
        rows = rows.filter(nature_id: query.nature_id) if query.nature_id
        rows = rows.filter(category: query.category) if query.category
        rows.order(:date, :number)
      end

      # --- Totaux (agrégats, sans charger les lignes) --------------------------------

      TABLES = {"receipt" => "micro_receipt", "purchase" => "micro_purchase"}

      # Clause `WHERE` et arguments d'une requête de registre.
      private def self.where(query : Api::RegisterQuery, alias_name : String = "") : {String, Array(DB::Any)}
        prefix = alias_name.empty? ? "" : "#{alias_name}."
        clauses = ["TRUE"]
        args = [] of DB::Any
        if from = query.from
          args << day(from).to_s("%Y-%m-%d")
          clauses << "#{prefix}date >= $#{args.size}::date"
        end
        if to = query.to
          args << day(to).to_s("%Y-%m-%d")
          clauses << "#{prefix}date <= $#{args.size}::date"
        end
        if nature_id = query.nature_id
          args << nature_id
          clauses << "#{prefix}nature_id = $#{args.size}"
        end
        if category = query.category
          args << category
          clauses << "#{prefix}category = $#{args.size}"
        end
        {clauses.join(" AND "), args}
      end

      # Totaux d'un registre (`receipt`, `purchase`) sur toute la requête.
      def self.totals(register : String, query : Api::RegisterQuery) : Api::TotalsView
        condition, args = where(query)
        result = Api::TotalsView.new(0, BigDecimal.new(0), BigDecimal.new(0))
        Marten::DB::Connection.default.open do |db|
          db.query("SELECT count(*), coalesce(sum(amount), 0), coalesce(sum(vat_amount), 0) FROM #{TABLES[register]} " \
                   "WHERE #{condition}", args: args) do |result_set|
            result_set.each do
              result = Api::TotalsView.new(result_set.read(Int64).to_i32, result_set.read(BigDecimal), result_set.read(BigDecimal))
            end
          end
        end
        result
      end

      # Totaux par nature (récapitulatif annuel), triés par code de nature.
      def self.nature_totals(register : String, query : Api::RegisterQuery) : Array(Api::NatureTotalView)
        condition, args = where(query, "r")
        rows = [] of Api::NatureTotalView
        Marten::DB::Connection.default.open do |db|
          db.query("SELECT n.id, n.code, n.label, n.category, count(*), sum(r.amount), sum(r.vat_amount) " \
                   "FROM #{TABLES[register]} r JOIN micro_nature n ON n.id = r.nature_id WHERE #{condition} " \
                   "GROUP BY n.id, n.code, n.label, n.category ORDER BY n.code", args: args) do |result_set|
            result_set.each do
              nature_id, code, label = result_set.read(Int64), result_set.read(String), result_set.read(String)
              category, count = result_set.read(String), result_set.read(Int64)
              amount, vat = result_set.read(BigDecimal), result_set.read(BigDecimal)
              rows << Api::NatureTotalView.new(nature_id, code, label, category, amount, vat, count.to_i32)
            end
          end
        end
        rows
      end

      def self.views(rows : Array(Receipt)) : Array(Api::LineView)
        return [] of Api::LineView if rows.empty?
        ids = rows.map(&.pk!.as(Int64))
        reversals = {} of Int64 => Int64
        ids.each_slice(Api::MAX_LIMIT) do |slice|
          Receipt.filter(reversal_of_id__in: slice).each { |row| reversals[row.reversal_of_id!.to_i64] = row.pk!.as(Int64) }
        end
        build(rows, reversals)
      end

      def self.views(rows : Array(Purchase)) : Array(Api::LineView)
        return [] of Api::LineView if rows.empty?
        ids = rows.map(&.pk!.as(Int64))
        reversals = {} of Int64 => Int64
        ids.each_slice(Api::MAX_LIMIT) do |slice|
          Purchase.filter(reversal_of_id__in: slice).each { |row| reversals[row.reversal_of_id!.to_i64] = row.pk!.as(Int64) }
        end
        build(rows, reversals)
      end

      def self.view(row : Receipt) : Api::LineView
        views([row]).first
      end

      def self.view(row : Purchase) : Api::LineView
        views([row]).first
      end

      private def self.build(rows : Array(T), reversals : Hash(Int64, Int64)) : Array(Api::LineView) forall T
        natures = Nature.all.to_a.index_by(&.pk!.as(Int64))
        closed = closed_periods
        declared = Declaration.all.map { |item| {item.starts_on!, item.ends_on!, item.declared_on!} }
        rows.map { |row| view(row, natures[row.nature_id!.to_i64], reversals[row.pk!.as(Int64)]?, closed, declared) }
      end

      private def self.view(row : Receipt | Purchase, nature : Nature, reversed_by_id : Int64?,
                            closed : Array({Time, Time}), declared : Array({Time, Time, Time})) : Api::LineView
        date = row.date!
        declared_on = declared.find { |(from, to, _)| from <= date <= to }.try(&.[2])
        origin, source = row.is_a?(Receipt) ? {row.origin.to_s, row.source.to_s} : {"manual", ""}
        vat = row.vat_amount!
        Api::LineView.new(
          id: row.pk!.as(Int64), register: row.is_a?(Receipt) ? "receipt" : "purchase", number: row.number.to_s,
          date: date, nature_id: nature.pk!.as(Int64), nature_code: nature.code.to_s, nature_label: nature.label.to_s,
          category: row.category.to_s, amount: row.amount!, vat_amount: vat, method: row.method.to_s,
          card_id: row.card_id.try(&.to_i64), party_name: row.party_name.to_s, label: row.label.to_s,
          reference: row.reference.to_s, attachment_id: row.attachment_id.try(&.to_i64), origin: origin, source: source,
          reversal_of_id: row.reversal_of_id.try(&.to_i64), reversed_by_id: reversed_by_id,
          locked: !declared_on.nil? || closed.any? { |(from, to)| from <= date <= to }, recorded_at: row.recorded_at || Time.utc,
          declared_on: declared_on, modified_at: row.modified_at)
      end

      private def self.closed_periods : Array({Time, Time})
        Partiduo::Api::Core.periods(system).select(&.closed?).map { |period| {period.starts_on, period.ends_on} }
      end
    end
  end
end
