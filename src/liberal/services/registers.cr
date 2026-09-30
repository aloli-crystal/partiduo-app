# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Liberal
    # Livre-journal des recettes et des dépenses professionnelles (ADR-007
    # D6) : contrôle, numérotation chronologique par année sous verrou,
    # inscription, contre-passation, vues, totaux par rubrique, publication de
    # `liberal.receipt.recorded` et `liberal.expense.recorded`. Service
    # interne : le contrat `Partiduo::Api::Liberal` l'appelle.
    #
    # Tant que son exercice (l'année civile de sa date) est ouvert, une
    # ligne saisie se modifie et se supprime (`liberal.*.updated`,
    # `liberal.*.deleted`) ; une fois l'exercice figé — clôturé au socle, ou
    # sa 2035 transmise — ou sa période du socle close, elle est intangible
    # et une erreur se corrige par une contre-passation datée dans un
    # exercice ouvert (déclencheur `liberal_register_guard`, DECISIONS
    # D-LIB2-001).
    module Registers
      alias FieldError = Partiduo::Api::FieldError
      alias Api = Partiduo::Api::Liberal

      PREFIXES = {"journal" => "J", "asset" => "I"}

      # Module dont dépend l'interface « comptabilité » du dossier.
      ACCOUNTING_MODULE = "ACCOUNTING"

      def self.system : Partiduo::Api::Actor
        Partiduo::Api::Actor.system
      end

      def self.error(field : String, code : String, params : Hash(String, String) = {} of String => String) : FieldError
        FieldError.new(field, "liberal.errors.#{code}", params)
      end

      def self.day(time : Time) : Time
        Time.utc(time.year, time.month, time.day)
      end

      def self.zero : BigDecimal
        BigDecimal.new(0)
      end

      # --- Paramètres ---------------------------------------------------------------

      # Ligne de paramètres, `nil` tant qu'aucune écriture ne l'a créée : une
      # lecture ne crée jamais rien.
      def self.settings? : Settings?
        Settings.all.order(:id).first
      end

      # Ligne de paramètres pour une écriture : créée au besoin sous verrou
      # consultatif de transaction (deux premiers appels concurrents ne
      # créent qu'une ligne). À appeler dans une transaction.
      def self.settings! : Settings
        if found = settings?
          return found
        end
        Marten::DB::Connection.default.open(&.exec("SELECT pg_advisory_xact_lock(hashtext($1))", "liberal_settings"))
        settings? || Settings.create!(profession: "")
      end

      def self.settings_view(row : Settings? = settings?) : Api::SettingsView
        return Api::SettingsView.new("", nil, nil) unless row
        Api::SettingsView.new(row.profession.to_s, row.activity_started_on, row.default_nature_id.try(&.to_i64),
          effective_interface(row.interface.to_s))
      end

      # Interfaces offertes au dossier : la comptabilité suppose le module
      # Comptabilité actif, lu au registre du socle (aucun appel au module,
      # ADR-006 D3 ; D-LIB3-001).
      def self.interfaces : Array(String)
        accounting_active? ? Api::INTERFACES.dup : [Api::INTERFACE_SIMPLE]
      end

      # Interface en vigueur : celle qui est enregistrée si elle est encore
      # offerte, sinon `simple` (Comptabilité désactivée depuis).
      def self.effective_interface(stored : String) : String
        interfaces.includes?(stored) ? stored : Api::INTERFACE_SIMPLE
      end

      # Refus d'une interface inconnue, ou de la comptabilité sans le module
      # Comptabilité actif ; `nil` : inchangée, rien à contrôler.
      def self.interface_errors(interface : String?) : Array(FieldError)
        return [] of FieldError if interface.nil?
        return [error("interface", "settings.interface.unknown")] unless Api::INTERFACES.includes?(interface)
        return [error("interface", "settings.interface.accounting_inactive")] unless interfaces.includes?(interface)
        [] of FieldError
      end

      def self.accounting_active? : Bool
        Partiduo::Modules.active?(ACCOUNTING_MODULE)
      end

      def self.nature_view(nature : Nature) : Api::NatureView
        Api::NatureView.new(nature.pk!.as(Int64), nature.code.to_s, nature.label.to_s, nature.kind.to_s,
          nature.heading.to_s, nature.enabled || false)
      end

      def self.nature!(id : Int64) : Nature
        Nature.filter(id: id).first || raise Partiduo::Api::NotFound.new("liberal_nature", id)
      end

      # --- Contrôle -------------------------------------------------------------------

      # Règles d'une saisie : date (hors période close, pas dans le futur pour
      # une saisie directe), nature active du bon sens, montant positif au
      # centime, part non déductible (dépense seulement, au plus le montant),
      # mode de règlement, fiche existante, pièce jointe visible de l'acteur,
      # longueurs.
      def self.line_errors(kind : String, input : Api::LineInput, manual : Bool = true,
                           actor : Partiduo::Api::Actor = system) : Array(FieldError)
        errors = [] of FieldError
        errors.concat(date_errors(input.date, manual))
        nature = Nature.filter(id: input.nature_id).first
        if nature.nil? || nature.kind != kind
          errors << error("nature_id", "line.nature.unknown")
        elsif !nature.enabled
          errors << error("nature_id", "line.nature.disabled")
        end
        errors.concat(amount_errors("amount", input.amount))
        nondeductible = input.nondeductible_amount
        if !nondeductible.zero?
          if kind != "expense"
            errors << error("nondeductible_amount", "line.nondeductible.receipt")
          elsif nondeductible < 0 || nondeductible.round(2) != nondeductible
            errors << error("nondeductible_amount", "line.nondeductible.invalid")
          elsif nondeductible > input.amount
            errors << error("nondeductible_amount", "line.nondeductible.exceeds")
          elsif nature && Api::EXCLUDED_HEADINGS.includes?(nature.heading)
            # Prélèvement, remboursement d'emprunt : jamais déduits, donc
            # rien à réintégrer (DECISIONS D-TST-L-001).
            errors << error("nondeductible_amount", "line.nondeductible.excluded")
          end
        end
        errors << error("method", "line.method.invalid") unless Api::METHODS.includes?(input.method)
        errors.concat(party_errors(input.card_id, input.party_name, input.label, input.reference, input.attachment_id, actor))
        errors
      end

      # Fiche, textes et pièce jointe (communs au livre-journal et aux
      # immobilisations).
      def self.party_errors(card_id : Int64?, party_name : String, label : String, reference : String,
                            attachment_id : Int64?, actor : Partiduo::Api::Actor) : Array(FieldError)
        errors = [] of FieldError
        # Fiche lue avec l'acteur de la commande : sans `cards.card.read`,
        # « inconnue », sans dévoiler qu'elle existe (les inscriptions issues
        # des événements passent `system`).
        if id = card_id
          begin
            Partiduo::Api::Cards.card(actor, id)
          rescue Partiduo::Api::NotFound | Partiduo::Api::AccessDenied
            errors << error("card_id", "line.card.unknown")
          end
        end
        errors << error("party_name", "line.too_long", {"max" => "255"}) if party_name.size > 255
        errors << error("label", "line.too_long", {"max" => "255"}) if label.size > 255
        errors << error("reference", "line.too_long", {"max" => "100"}) if reference.size > 100
        attachment_id.try { |attachment| errors.concat(attachment_errors(attachment, actor)) }
        errors
      end

      # Pièce jointe rattachable par l'acteur : il lit les pièces jointes du
      # dossier ou l'a déposée lui-même ; sinon « inconnue », sans dévoiler
      # qu'elle existe (comme D-MIC-015).
      def self.attachment_errors(id : Int64, actor : Partiduo::Api::Actor) : Array(FieldError)
        view = Partiduo::Api::Core.attachment(system, id)
        allowed = actor.can?("core.attachment.read") || (!actor.user_id.nil? && view.uploaded_by_id == actor.user_id)
        allowed ? [] of FieldError : [error("attachment_id", "line.attachment.unknown")]
      rescue Partiduo::Api::NotFound
        [error("attachment_id", "line.attachment.unknown")]
      end

      def self.amount_errors(field : String, amount : BigDecimal) : Array(FieldError)
        return [error(field, "line.amount.not_positive")] if amount <= 0
        return [error(field, "line.amount.scale")] if amount.round(2) != amount
        [] of FieldError
      end

      # Date dans une période close du socle ou dans une année dont la 2035
      # est transmise : refusée ; dans le futur : refusée pour une saisie
      # directe (on n'inscrit qu'un mouvement fait).
      def self.date_errors(date : Time, manual : Bool = true, field : String = "date") : Array(FieldError)
        errors = [] of FieldError
        errors << error(field, "line.date.future") if manual && day(date) > Partiduo::Config.today
        if closed?(date)
          errors << error(field, "line.date.closed_period")
        elsif Years.transmitted?(date.year)
          errors << error(field, "line.date.transmitted", {"year" => date.year.to_s})
        end
        errors
      end

      # Date dans une période close du socle.
      def self.closed?(date : Time) : Bool
        Partiduo::Api::Core.period_for(system, day(date)).try(&.closed?) || false
      end

      # Date intangible : période close ou année transmise.
      def self.locked_on?(date : Time) : Bool
        closed?(date) || Years.transmitted?(date.year)
      end

      # --- Inscription ----------------------------------------------------------------

      # Numéro suivant du registre (`journal`, `asset`) pour l'année de
      # `date`, sous verrou de la ligne de compteur.
      def self.next_number(register : String, date : Time) : String
        year = date.year
        Marten::DB::Connection.default.open do |db|
          db.exec("INSERT INTO liberal_counter (register, year, next_number) VALUES ($1, $2, 1) " \
                  "ON CONFLICT (register, year) DO NOTHING", register, year)
        end
        counter = Counter.filter(register: register, year: year).lock.first || raise "compteur absent"
        number = counter.next_number || 1
        counter.next_number = number + 1
        counter.save!
        "#{PREFIXES[register]}#{year}-#{number.to_s.rjust(5, '0')}"
      end

      # Inscrit une ligne contrôlée et publie son événement.
      def self.create_line!(kind : String, input : Api::LineInput, actor_user_id : Int64?, origin : String = "manual",
                            source : String = "", reversal_of_id : Int64? = nil) : Line
        nature = nature!(input.nature_id)
        line = Line.create!(
          number: next_number("journal", input.date), kind: kind, date: day(input.date), nature_id: input.nature_id,
          heading: nature.heading, amount: input.amount, nondeductible_amount: input.nondeductible_amount,
          method: input.method, card_id: input.card_id, party_name: party_name(input.card_id, input.party_name),
          label: input.label.strip, reference: input.reference.strip, attachment_id: input.attachment_id,
          origin: origin, source: source, reversal_of_id: reversal_of_id, recorded_by_id: actor_user_id,
          recorded_at: Time.utc)
        publish(line, nature, actor_user_id)
        line
      end

      # Nom du tiers : celui saisi, sinon celui de la fiche (lue par `system`
      # après le contrôle de `party_errors` avec l'acteur de la commande).
      def self.party_name(card_id : Int64?, name : String) : String
        text = name.strip
        return text unless text.empty?
        card_id.try { |id| Partiduo::Api::Cards.card(system, id).name } || ""
      rescue Partiduo::Api::NotFound
        ""
      end

      # --- Modification et suppression (exercice ouvert, D-LIB2-001) ------------------

      # Ligne qui ne se modifie ni ne se supprime : issue de la Facturation
      # (la corriger là, ou la contre-passer), déjà contre-passée (supprimer
      # d'abord sa contre-passation), ou d'un exercice figé ou d'une période
      # close (la contre-passer). Une contre-passation se supprime mais ne se
      # modifie pas (`update` vrai : modification).
      def self.change_errors(row : Line, update : Bool) : Array(FieldError)
        errors = [] of FieldError
        errors << error("id", "line.change.from_invoicing") if row.origin != "manual"
        errors << error("id", "line.change.is_reversal") if update && row.reversal_of_id
        errors << error("id", "line.change.reversed") if Line.filter(reversal_of_id: row.pk).exists?
        errors.concat(frozen_errors(row.date!))
        errors
      end

      # Exercice figé ou période close à la date d'une ligne existante.
      def self.frozen_errors(date : Time) : Array(FieldError)
        return [error("id", "line.change.closed_period")] if closed?(date)
        return [error("id", "line.change.transmitted", {"year" => date.year.to_s})] if Years.transmitted?(date.year)
        [] of FieldError
      end

      # Modifie une ligne d'un exercice ouvert (contrôles faits par le
      # contrat : même sens, mêmes règles que la saisie) et publie
      # `liberal.receipt.updated` ou `liberal.expense.updated` : la
      # Comptabilité remplace son écriture, ou refuse
      # (`Partiduo::Events::Refused`). Changer d'année renumérote la ligne
      # dans la nouvelle année.
      def self.update_line!(row : Line, input : Api::LineInput, actor_user_id : Int64?) : Line
        nature = nature!(input.nature_id)
        row.number = next_number("journal", input.date) if day(input.date).year != row.date!.year
        row.date = day(input.date)
        row.nature_id = input.nature_id
        row.heading = nature.heading
        row.amount = input.amount
        row.nondeductible_amount = input.nondeductible_amount
        row.method = input.method
        row.card_id = input.card_id
        row.party_name = party_name(input.card_id, input.party_name)
        row.label = input.label.strip
        row.reference = input.reference.strip
        row.attachment_id = input.attachment_id
        row.modified_at = Time.utc
        row.modified_by_id = actor_user_id
        row.save!
        publish(row, nature, actor_user_id, UPDATED[row.kind.to_s])
        row
      end

      # Supprime une ligne d'un exercice ouvert et publie
      # `liberal.receipt.deleted` ou `liberal.expense.deleted` : la
      # Comptabilité extourne l'écriture passée, ou refuse. Le numéro n'est
      # pas repris.
      def self.delete!(row : Line, actor_user_id : Int64?) : Nil
        kind = row.kind.to_s
        payload = {
          "#{kind}_id"     => row.pk!.to_s,
          "number"         => row.number.to_s,
          "date"           => row.date!.to_s("%Y-%m-%d"),
          "origin"         => row.origin.to_s,
          "reversal_of_id" => row.reversal_of_id.to_s,
        }
        row.delete
        Partiduo::Events.publish(DELETED[kind], payload, actor_user_id: actor_user_id)
      end

      # --- Contre-passation -----------------------------------------------------------

      # Ligne existante, ni elle-même une contre-passation, ni déjà
      # contre-passée ; date au plus tôt celle de la ligne, hors période
      # close et, saisie (`manual`), pas à venir.
      def self.reverse_errors(row : Line, input : Api::ReverseInput, manual : Bool = true) : Array(FieldError)
        errors = [] of FieldError
        errors << error("id", "line.reversal.is_reversal") if row.reversal_of_id
        errors << error("id", "line.reversal.already") if Line.filter(reversal_of_id: row.pk).exists?
        errors << error("date", "line.reversal.before_line") if day(input.date) < row.date!
        errors.concat(date_errors(input.date, manual: manual))
        errors << error("label", "line.too_long", {"max" => "255"}) if input.label.size > 255
        errors
      end

      # Contre-passation d'une ligne. Saisie par le contrat (`manual`) :
      # origine `manual`, même pour une recette issue de la Facturation (la
      # Comptabilité passe l'écriture inverse, comme D-MIC-011) ; celle du
      # délettrage garde l'origine `invoicing`.
      def self.reverse!(row : Line, input : Api::ReverseInput, actor_user_id : Int64?, manual : Bool = true) : Line
        label = input.label.strip.presence || I18n.t("liberal.reversal_label", {"number" => row.number.to_s})
        reversal = Api::LineInput.new(date: input.date, nature_id: row.nature_id!.to_i64, amount: -row.amount!,
          method: row.method.to_s, card_id: row.card_id.try(&.to_i64), party_name: row.party_name.to_s, label: label,
          reference: row.number.to_s, nondeductible_amount: -row.nondeductible_amount!)
        create_line!(row.kind.to_s, reversal, actor_user_id, manual ? "manual" : row.origin.to_s, row.source.to_s,
          row.pk!.as(Int64))
      end

      # --- Événements -------------------------------------------------------------------

      EVENTS  = {"receipt" => "liberal.receipt.recorded", "expense" => "liberal.expense.recorded"}
      UPDATED = {"receipt" => "liberal.receipt.updated", "expense" => "liberal.expense.updated"}
      DELETED = {"receipt" => "liberal.receipt.deleted", "expense" => "liberal.expense.deleted"}

      # Charge utile de quoi passer l'écriture sans relire le module (ADR-006
      # D3) : la Comptabilité y trouve la nature, la rubrique et son libellé
      # (compte créé au besoin). Même charge utile à la modification.
      def self.publish(row : Line, nature : Nature, actor_user_id : Int64?, name : String? = nil) : Nil
        kind = row.kind.to_s
        Partiduo::Events.publish(name || EVENTS[kind], {
          "#{kind}_id"           => row.pk!.to_s,
          "number"               => row.number.to_s,
          "date"                 => row.date!.to_s("%Y-%m-%d"),
          "amount"               => row.amount!.to_s,
          "nondeductible_amount" => row.nondeductible_amount!.to_s,
          "nature_code"          => nature.code.to_s,
          "heading"              => row.heading.to_s,
          "heading_label"        => I18n.t("liberal.headings.#{row.heading}"),
          "method"               => row.method.to_s,
          "card_id"              => row.card_id.to_s,
          "party_name"           => row.party_name.to_s,
          "label"                => row.label.to_s.presence || nature.label.to_s,
          "reference"            => row.reference.to_s,
          "attachment_id"        => row.attachment_id.to_s,
          "origin"               => row.origin.to_s,
          "source"               => row.source.to_s,
          "reversal_of_id"       => row.reversal_of_id.to_s,
        }, actor_user_id: actor_user_id)
      end

      # Republie les événements de toutes les lignes, dans l'ordre (la
      # Comptabilité activée plus tard les comptabilise ; elle ignore une
      # ligne déjà passée). Renvoie le nombre de lignes publiées.
      def self.republish(actor_user_id : Int64?) : Int32
        natures = Nature.all.to_a.index_by(&.pk!.as(Int64))
        count = 0
        Line.all.order(:id).each do |row|
          publish(row, natures[row.nature_id!.to_i64], actor_user_id)
          count += 1
        end
        count
      end

      # --- Vues -------------------------------------------------------------------------

      def self.query(query : Api::JournalQuery)
        rows = Line.all
        if from = query.from
          rows = rows.filter(date__gte: day(from))
        end
        if to = query.to
          rows = rows.filter(date__lte: day(to))
        end
        rows = rows.filter(kind: query.kind) if query.kind
        rows = rows.filter(nature_id: query.nature_id) if query.nature_id
        rows = rows.filter(heading: query.heading) if query.heading
        rows.order(:date, :number)
      end

      # Clause `WHERE` et arguments d'une requête.
      private def self.where(query : Api::JournalQuery) : {String, Array(DB::Any)}
        clauses = ["TRUE"]
        args = [] of DB::Any
        if from = query.from
          args << day(from).to_s("%Y-%m-%d")
          clauses << "date >= $#{args.size}::date"
        end
        if to = query.to
          args << day(to).to_s("%Y-%m-%d")
          clauses << "date <= $#{args.size}::date"
        end
        {"kind" => query.kind, "heading" => query.heading}.each do |column, value|
          next unless value
          args << value
          clauses << "#{column} = $#{args.size}"
        end
        if nature_id = query.nature_id
          args << nature_id
          clauses << "nature_id = $#{args.size}"
        end
        {clauses.join(" AND "), args}
      end

      # Totaux sur toute la requête (agrégat, sans charger les lignes).
      def self.totals(query : Api::JournalQuery) : Api::TotalsView
        condition, args = where(query)
        result = Api::TotalsView.new(0, zero, zero)
        Marten::DB::Connection.default.open do |db|
          db.query("SELECT count(*), coalesce(sum(amount) FILTER (WHERE kind = 'receipt'), 0), " \
                   "coalesce(sum(amount) FILTER (WHERE kind = 'expense'), 0) FROM liberal_line WHERE #{condition}",
            args: args) do |result_set|
            result_set.each do
              result = Api::TotalsView.new(result_set.read(Int64).to_i32, result_set.read(BigDecimal),
                result_set.read(BigDecimal))
            end
          end
        end
        result
      end

      # Totaux par rubrique d'une année civile (contre-passations comprises à
      # leur date), dans l'ordre des rubriques.
      def self.heading_totals(year : Int32) : Array(Api::HeadingTotalView)
        found = {} of String => Api::HeadingTotalView
        Marten::DB::Connection.default.open do |db|
          db.query("SELECT heading, kind, sum(amount), sum(nondeductible_amount), count(*) FROM liberal_line " \
                   "WHERE date BETWEEN make_date($1, 1, 1) AND make_date($1, 12, 31) GROUP BY heading, kind",
            year) do |result_set|
            result_set.each do
              heading, kind = result_set.read(String), result_set.read(String)
              amount, nondeductible, count = result_set.read(BigDecimal), result_set.read(BigDecimal), result_set.read(Int64)
              found[heading] = Api::HeadingTotalView.new(heading, kind, amount, nondeductible, count.to_i32)
            end
          end
        end
        Api::HEADINGS.compact_map { |heading| found[heading]? }
      end

      def self.views(rows : Array(Line)) : Array(Api::LineView)
        return [] of Api::LineView if rows.empty?
        reversals = {} of Int64 => Int64
        rows.map(&.pk!.as(Int64)).each_slice(Api::MAX_LIMIT) do |slice|
          Line.filter(reversal_of_id__in: slice).each { |row| reversals[row.reversal_of_id!.to_i64] = row.pk!.as(Int64) }
        end
        natures = Nature.all.to_a.index_by(&.pk!.as(Int64))
        closed = closed_periods
        transmitted = Years.transmitted
        rows.map { |row| view(row, natures[row.nature_id!.to_i64], reversals[row.pk!.as(Int64)]?, closed, transmitted) }
      end

      def self.view(row : Line) : Api::LineView
        views([row]).first
      end

      private def self.view(row : Line, nature : Nature, reversed_by_id : Int64?,
                            closed : Array({Time, Time}), transmitted : Hash(Int32, Time)) : Api::LineView
        date = row.date!
        transmitted_at = transmitted[date.year]?
        Api::LineView.new(
          id: row.pk!.as(Int64), number: row.number.to_s, kind: row.kind.to_s, date: date,
          nature_id: nature.pk!.as(Int64), nature_code: nature.code.to_s, nature_label: nature.label.to_s,
          heading: row.heading.to_s, amount: row.amount!, nondeductible_amount: row.nondeductible_amount!,
          method: row.method.to_s, card_id: row.card_id.try(&.to_i64), party_name: row.party_name.to_s,
          label: row.label.to_s, reference: row.reference.to_s, attachment_id: row.attachment_id.try(&.to_i64),
          origin: row.origin.to_s, source: row.source.to_s, reversal_of_id: row.reversal_of_id.try(&.to_i64),
          reversed_by_id: reversed_by_id, locked: !transmitted_at.nil? || locked?(date, closed),
          recorded_at: row.recorded_at || Time.utc, transmitted_at: transmitted_at, modified_at: row.modified_at)
      end

      # Date dans une période close du socle (liste `closed_periods`).
      def self.locked?(date : Time, closed : Array({Time, Time})) : Bool
        closed.any? { |(from, to)| from <= date <= to }
      end

      def self.closed_periods : Array({Time, Time})
        Partiduo::Api::Core.periods(system).select(&.closed?).map { |period| {period.starts_on, period.ends_on} }
      end
    end
  end
end
