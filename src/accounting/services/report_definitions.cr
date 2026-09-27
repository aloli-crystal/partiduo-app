# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Accounting
    # Rapports personnalisés (`Acc_Report`, `formulaire`,
    # `form_definition`) : contrôle, enregistrement et calcul. Service
    # interne.
    module ReportDefinitions
      alias Api = Partiduo::Api::Accounting
      alias FieldError = Partiduo::Api::FieldError

      MAX_NAME  = 100
      MAX_LABEL = 255
      MAX_LINES = 500

      def self.errors(input : Api::ReportDefinitionInput, id : Int64? = nil) : Array(FieldError)
        errors = [] of FieldError
        name = input.name.strip
        if name.empty?
          errors << FieldError.new("name", "accounting.errors.report.name.blank")
        elsif name.size > MAX_NAME
          errors << FieldError.new("name", "accounting.errors.report.name.too_long", {"max" => MAX_NAME.to_s})
        else
          taken = Report.filter(name: name)
          taken = taken.exclude(id: id) if id
          errors << FieldError.new("name", "accounting.errors.report.name.taken") if taken.exists?
        end
        errors << FieldError.new("lines", "accounting.errors.report.lines.blank") if input.lines.empty?
        if input.lines.size > MAX_LINES
          errors << FieldError.new("lines", "accounting.errors.report.lines.too_many", {"max" => MAX_LINES.to_s})
        end
        input.lines.each_with_index do |line, index|
          label = line.label.strip
          if label.empty?
            errors << FieldError.new("lines[#{index}].label", "accounting.errors.report.label.blank")
          elsif label.size > MAX_LABEL
            errors << FieldError.new("lines[#{index}].label", "accounting.errors.report.label.too_long",
              {"max" => MAX_LABEL.to_s})
          end
          if line.formula.size > Formula::MAX_LENGTH
            errors << FieldError.new("lines[#{index}].formula", "accounting.errors.report.formula.too_long",
              {"max" => Formula::MAX_LENGTH.to_s})
          elsif error = Formula.check(line.formula)
            errors << error.field_error("lines[#{index}].formula")
          end
        end
        errors
      end

      def self.save!(report : Report, input : Api::ReportDefinitionInput, actor : Partiduo::Api::Actor) : Report
        report.name = input.name.strip
        report.created_by_id ||= actor.user_id
        report.save!
        ReportLine.filter(report_id: report.pk).delete
        input.lines.each_with_index do |line, index|
          ReportLine.create!(report: report, position: index + 1, label: line.label.strip, formula: line.formula.strip)
        end
        report
      end

      def self.view(report : Report) : Api::ReportDefinitionView
        Api::ReportDefinitionView.new(
          id: report.pk!.as(Int64), name: report.name.to_s,
          lines: ReportLine.filter(report_id: report.pk).order(:position, :id).map do |line|
            Api::ReportLineView.new(line.position!.to_i32, line.label.to_s, line.formula.to_s)
          end,
        )
      end

      ACCOUNT_LABEL = /\[([0-9]+)-([Tt])\]/

      # `[606-T]` et `[606-t]` dans un libellé : intitulé du premier compte
      # dont le numéro commence par `606`, en majuscules ou en minuscules
      # (`Impress::parse_formula`) ; vide si aucun compte ne correspond.
      def self.account_labels(label : String) : String
        return label unless label.includes?('[')
        label.gsub(ACCOUNT_LABEL) do |_, match|
          name = Account.filter(number__startswith: match[1]).order(:number).first.try(&.label.to_s) || ""
          match[2] == "T" ? name.upcase : name.downcase
        end
      end

      # Calcule chaque ligne sur la période ; une ligne `FROM=MM.AAAA` part
      # du premier jour de ce mois.
      def self.run(definition : Api::ReportDefinitionView, from : Time, to : Time, ledger_ids : Array(Int64)) : Api::ReportResultView
        cache = {} of Time => Statements::BalanceContext
        context_for = ->(start : Time) do
          cache[start] ||= Statements::BalanceContext.new(ReportData.sums(ledger_ids, start, to, by_card: true, opening: false))
        end
        lines = definition.lines.map do |line|
          amount = begin
            parsed = Formula.parse(line.formula)
            Statements.round(parsed.evaluate(context_for.call(parsed.from || from)))
          rescue Formula::Error
            BigDecimal.new(0)
          end
          Api::ReportResultLineView.new(line.position, account_labels(line.label), line.formula, amount)
        end
        Api::ReportResultView.new(definition.id, definition.name, from, to, lines)
      end
    end
  end
end
