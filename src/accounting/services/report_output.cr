# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Accounting
    # Sortie des éditions en CSV et en PDF (ADR-005 : « export CSV et PDF
    # depuis chaque liste »), à partir d'un tableau neutre (`Table`) que
    # construit `ReportTables` pour chaque édition. Le rendu est celui du
    # socle (`Partiduo::Core::TableOutput`, B-CRIT-001) ; ce module garde les
    # noms des éditions et la période traduite.
    module ReportOutput
      alias Cell = Partiduo::Core::TableOutput::Cell
      alias Column = Partiduo::Core::TableOutput::Column
      alias Row = Partiduo::Core::TableOutput::Row
      alias Table = Partiduo::Core::TableOutput::Table

      def self.plain(value : BigDecimal) : String
        Partiduo::Core::TableOutput.plain(value)
      end

      def self.format_amount(value : BigDecimal, locale : String = I18n.locale) : String
        Partiduo::Core::TableOutput.format_amount(value, locale)
      end

      def self.format_date(value : Time, locale : String = I18n.locale) : String
        Partiduo::Core::TableOutput.format_date(value, locale)
      end

      def self.period(from : Time, to : Time) : String
        I18n.t("accounting.reports.period", {"from" => format_date(from), "to" => format_date(to)})
      end

      def self.csv_text(text : String) : String
        Partiduo::Core::TableOutput.csv_text(text)
      end

      def self.csv(table : Table) : Bytes
        Partiduo::Core::TableOutput.csv(table)
      end

      def self.pdf(table : Table) : Bytes
        Partiduo::Core::TableOutput.pdf(table)
      end

      def self.file(table : Table, format : Partiduo::Api::Accounting::ExportFormat) : Partiduo::Api::Accounting::FileView
        if format.csv?
          Partiduo::Api::Accounting::FileView.new("#{table.name}.csv", "text/csv", csv(table))
        else
          Partiduo::Api::Accounting::FileView.new("#{table.name}.pdf", "application/pdf", pdf(table))
        end
      end

      def self.company_name : String
        Partiduo::Core::TableOutput.company_name
      end
    end
  end
end
