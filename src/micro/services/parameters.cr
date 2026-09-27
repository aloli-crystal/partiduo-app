# SPDX-License-Identifier: AGPL-3.0-or-later

require "yaml"

module Partiduo
  module Micro
    # Paramètres datés (taux URSSAF, seuils, cases de la 2042-C-PRO) et jeu de
    # données initial (natures par défaut, paramètres du fichier
    # `data/parameters.yml`). Un paramètre en vigueur à une date est celui du
    # même code dont `valid_from` est la plus récente au plus tard à cette
    # date. Aucune valeur n'est écrite dans le code (ADR-007 D1). Service
    # interne.
    module Parameters
      alias Api = Partiduo::Api::Micro

      DATA = {{ read_file("#{__DIR__}/../data/parameters.yml") }}

      # Valeur numérique en vigueur à `on`, ou `nil`.
      def self.value(code : String, on : Time) : BigDecimal?
        row(code, on).try(&.value)
      end

      # Texte en vigueur à `on`, ou `nil`.
      def self.text(code : String, on : Time) : String?
        row(code, on).try(&.text.to_s.presence)
      end

      def self.row(code : String, on : Time) : Parameter?
        Parameter.filter(code: code, valid_from__lte: Registers.day(on)).order("-valid_from").first
      end

      # Tous les paramètres lus une fois, le temps d'un calcul (déclarations
      # d'une année, seuils) : évite une lecture par code et par période.
      class Snapshot
        @rows : Hash(String, Array(Parameter))

        def initialize
          @rows = Parameter.all.order("-valid_from").to_a.group_by(&.code.to_s)
        end

        def row(code : String, on : Time) : Parameter?
          day = Registers.day(on)
          @rows[code]?.try(&.find { |row| row.valid_from! <= day })
        end

        def value(code : String, on : Time) : BigDecimal?
          row(code, on).try(&.value)
        end

        def text(code : String, on : Time) : String?
          row(code, on).try(&.text.to_s.presence)
        end
      end

      def self.view(row : Parameter) : Api::ParameterView
        Api::ParameterView.new(row.pk!.as(Int64), row.code.to_s, row.valid_from!, row.value, row.text.to_s)
      end

      def self.errors(input : Api::ParameterInput) : Array(Partiduo::Api::FieldError)
        errors = [] of Partiduo::Api::FieldError
        errors << Registers.error("code", "parameter.code.unknown") unless Api::PARAMETER_CODES.includes?(input.code)
        if input.code.starts_with?("box.")
          errors << Registers.error("text", "parameter.text.required") if input.text.strip.empty?
          errors << Registers.error("text", "line.too_long", {"max" => "60"}) if input.text.size > 60
        elsif (value = input.value).nil? || value < 0
          errors << Registers.error("value", "parameter.value.invalid")
        elsif value.round(6) != value
          errors << Registers.error("value", "parameter.value.invalid")
        end
        errors
      end

      # Charge les natures et paramètres par défaut absents (même code, ou
      # même code et même date d'effet) ; renvoie le nombre de lignes créées.
      # Libellés des natures dans la langue `locale`.
      def self.load_defaults(locale : String) : Int32
        yaml = YAML.parse(DATA)
        created = 0
        I18n.with_locale(Partiduo::LOCALES.includes?(locale) ? locale : "fr") do
          yaml["natures"].as_a.each do |row|
            code = row["code"].as_s
            next if Nature.filter(code: code).exists?
            Nature.create!(code: code, label: I18n.t("micro.default_natures.#{code.downcase}"), kind: row["kind"].as_s,
              category: row["category"].as_s, enabled: true)
            created += 1
          end
        end
        yaml["parameters"].as_a.each do |row|
          code = row["code"].as_s
          valid_from = Time.parse_utc(row["valid_from"].as_s, "%Y-%m-%d")
          next if Parameter.filter(code: code, valid_from: valid_from).exists?
          Parameter.create!(code: code, valid_from: valid_from, value: row["value"]?.try { |value| BigDecimal.new(value.as_s) },
            text: row["text"]?.try(&.as_s) || "")
          created += 1
        end
        settings = Registers.settings
        if settings.default_nature_id.nil?
          settings.default_nature_id = Nature.filter(kind: "receipt", enabled: true).order(:id).first.try(&.pk)
          settings.save!
        end
        created
      end
    end
  end
end
