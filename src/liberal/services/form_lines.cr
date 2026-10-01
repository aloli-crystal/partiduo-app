# SPDX-License-Identifier: AGPL-3.0-or-later

require "yaml"

module Partiduo
  module Liberal
    # Table de correspondance poste → ligne des formulaires, datée par
    # millésime (ADR-007 D6 : paramétrable, jamais en dur), et jeu de données
    # initial (`data/defaults.yml`). La ligne d'un poste pour un millésime est
    # celle du même poste dont le millésime est le plus récent au plus tard
    # égal à celui demandé. Service interne.
    module FormLines
      alias Api = Partiduo::Api::Liberal

      DATA = {{ read_file("#{__DIR__}/../data/defaults.yml") }}

      def self.view(row : FormLine) : Api::FormLineView
        Api::FormLineView.new(row.pk!.as(Int64), (row.millesime || 0).to_i32, row.item.to_s, row.form.to_s, row.line.to_s,
          row.box.to_s)
      end

      # Lignes en vigueur pour le millésime `year`, par poste.
      def self.for_year(year : Int32) : Hash(String, FormLine)
        result = {} of String => FormLine
        FormLine.filter(millesime__lte: year).order(:millesime).each { |row| result[row.item.to_s] = row }
        result
      end

      def self.errors(input : Api::FormLineInput) : Array(Partiduo::Api::FieldError)
        errors = [] of Partiduo::Api::FieldError
        errors << Registers.error("item", "form_line.item.unknown") unless Api::ITEMS.includes?(input.item)
        errors << Registers.error("form", "form_line.form.unknown") unless Api::FORMS.includes?(input.form)
        unless 2000 <= input.millesime <= 2999
          errors << Registers.error("millesime", "form_line.millesime.invalid")
        end
        {"line" => input.line, "box" => input.box}.each do |field, value|
          errors << Registers.error(field, "line.too_long", {"max" => "10"}) if value.strip.size > 10
        end
        errors << Registers.error("millesime", "form_line.year.closed") if closed?(input.millesime)
        if (taken = box_taken_by(input)) && errors.none?(&.field.==("box"))
          errors << Registers.error("box", "form_line.box.taken", {"item" => I18n.t(item_key(taken))})
        end
        errors
      end

      private def self.item_key(item : String) : String
        Api::HEADINGS.includes?(item) ? "liberal.headings.#{item}" : "liberal.items.#{item}"
      end

      # Dernière année couverte par une période close du socle, ou clôturée
      # ou verrouillée par le module (DECISIONS D-LIB2-005, D-LIB5-001),
      # `nil` si aucune.
      def self.closed_through : Int32?
        closed = Partiduo::Api::Core.periods(Partiduo::Api::Actor.system).select(&.closed?).max_of?(&.ends_on.year)
        [closed, Years.held.keys.max?].compact.max?
      end

      # Un millésime au plus égal à une année close est figé : le changer
      # changerait les cases de 2035 déjà déposées (DECISIONS D-LIB-010).
      def self.closed?(millesime : Int32) : Bool
        closed_through.try { |year| millesime <= year } || false
      end

      # Autre poste reporté à la même case du même formulaire pour l'un des
      # millésimes où la ligne saisie sera en vigueur (le sien et les
      # suivants de la table, tant que le poste n'y est pas redéfini).
      def self.box_taken_by(input : Api::FormLineInput) : String?
        box = input.box.strip.upcase
        return if box.empty?
        later = FormLine.filter(millesime__gt: input.millesime).order(:millesime).to_a
        redefined = later.find(&.item.==(input.item)).try(&.millesime)
        years = [input.millesime] + later.map { |row| (row.millesime || 0).to_i32 }
        years = years.select { |year| redefined.nil? || year < redefined }.uniq!
        years.each do |year|
          for_year(year).each do |item, row|
            next if item == input.item
            return item if row.form == input.form && row.box.to_s.strip.upcase == box
          end
        end
        nil
      end

      # Charge natures et lignes par défaut absentes (même code ; même poste
      # et même millésime) ; renvoie le nombre de lignes créées. Libellés des
      # natures dans la langue `locale`.
      def self.load_defaults(locale : String) : Int32
        yaml = YAML.parse(DATA)
        created = 0
        I18n.with_locale(Partiduo::LOCALES.includes?(locale) ? locale : "fr") do
          yaml["natures"].as_a.each do |row|
            heading = row["heading"].as_s
            code = heading.upcase
            next if Nature.filter(code: code).exists?
            Nature.create!(code: code, label: I18n.t("liberal.headings.#{heading}"), kind: row["kind"].as_s,
              heading: heading, enabled: true)
            created += 1
          end
        end
        yaml["form_lines"].as_a.each do |row|
          millesime, item = row["millesime"].as_i, row["item"].as_s
          next if FormLine.filter(millesime: millesime, item: item).exists?
          FormLine.create!(millesime: millesime, item: item, form: row["form"].as_s, line: row["line"]?.try(&.as_s) || "",
            box: row["box"]?.try(&.as_s) || "")
          created += 1
        end
        settings = Registers.settings!
        if settings.default_nature_id.nil?
          settings.default_nature_id = Nature.filter(code: "RECEIPTS", kind: "receipt").first.try(&.pk)
          settings.save!
        end
        created
      end
    end
  end
end
