# SPDX-License-Identifier: AGPL-3.0-or-later

require "csv"

module Partiduo
  module Followup
    # Préfixes des types d'action de NOALYSS (`document_type`) ; libellés
    # sous `followup.default_types.<préfixe en minuscules>`.
    DEFAULT_TYPES = %w[DI BCL BFO FAC RAP CO PRP EL DS NFR RFO RCL RMG]

    # Export CSV d'une liste d'actions (`export_follow_up_csv.php`) :
    # séparateur `;`, UTF-8, dates `AAAA-MM-JJ`, cellules de texte protégées
    # contre les formules (D-2F-009), en-têtes dans la langue courante.
    # Service interne.
    module Exports
      alias Api = Partiduo::Api::Followup

      COLUMNS = %w[reference date hour type title card state priority remind_on tags]

      def self.actions(views : Array(Api::ActionSummaryView)) : Api::FileView
        text = CSV.build(separator: ';') do |csv|
          csv.row(COLUMNS.map { |key| I18n.t("followup.columns.#{key}") })
          views.each do |view|
            csv.row([
              protect(view.reference), view.date.to_s("%Y-%m-%d"), view.hour, protect(view.action_type_label),
              protect(view.title), protect(view.card.try { |card| "#{card.code} #{card.name}" } || ""),
              I18n.t(view.state_key), I18n.t("followup.priorities.p#{view.priority}"),
              view.remind_on.try(&.to_s("%Y-%m-%d")) || "", protect(view.tags.join(", ")),
            ])
          end
        end
        Api::FileView.new("followup.csv", "text/csv; charset=utf-8", text.to_slice)
      end

      # Cellule de texte commençant par `=`, `+`, `-`, `@`, une tabulation ou
      # un retour chariot : préfixée d'une apostrophe (D-2F-009).
      def self.protect(text : String) : String
        text.starts_with?(/[=+\-@\t\r]/) ? "'#{text}" : text
      end
    end
  end
end
