# SPDX-License-Identifier: AGPL-3.0-or-later

require "json"

module Partiduo
  module Invoicing
    module Commands
      # `manage invoicing_month_end` : fin de mois de la facturation des bons
      # de livraison (DECISIONS D-INV2-008), à lancer *chaque jour* par le
      # planificateur de l'instance. Idempotente : le dernier jour du mois, prépare
      # (ou émet et envoie, selon les paramètres de la Facturation) la facture
      # récapitulative de chaque client au rythme mensuel ; rattrape le mois
      # précédent tant qu'il n'est pas clos ; jamais deux factures pour un
      # client, un mois et une devise. Réponse JSON sur la sortie standard ;
      # module Facturation inactif : rien n'est fait (code 0).
      #
      # ```
      # partiduo-manage invoicing_month_end
      # partiduo-manage invoicing_month_end --date 2026-09-30
      # partiduo-manage invoicing_month_end --month 2026-09 --customer CLIENT01
      # ```
      class MonthEnd < Marten::CLI::Manage::Command::Base
        command_name :invoicing_month_end
        help "Fin de mois de la facturation des bons de livraison (factures récapitulatives, idempotent)."

        @date : String? = nil
        @month : String? = nil
        @customer : String? = nil

        def setup
          on_option_with_arg("date", "AAAA-MM-JJ", "jour du passage planifié (défaut : date du jour)") { |value| @date = value }
          on_option_with_arg("month", "AAAA-MM", "mois à facturer à la demande (sans planification)") { |value| @month = value }
          on_option_with_arg("customer", "code", "un seul client (avec --month), quel que soit son rythme") do |value|
            @customer = value
          end
        end

        def run
          unless Partiduo::Modules.active?("INVOICING")
            return print({"status" => "skipped", "reason" => "module_inactive"}.to_json)
          end
          actor = Partiduo::Api::Actor.system
          run = if month = @month
                  day = Time.parse_utc("#{month}-01", "%Y-%m-%d")
                  customer = @customer.try { |code| Partiduo::Api::Cards.card_by_code(actor, code).try(&.id) || raise ArgumentError.new("client inconnu : #{code}") }
                  Partiduo::Api::Invoicing.prepare_monthly_invoices(actor,
                    Partiduo::Api::Invoicing::MonthlyInput.new(month: day, customer_card_id: customer))
                else
                  today = @date.try { |text| Time.parse_utc(text, "%Y-%m-%d") }
                  Partiduo::Api::Invoicing.month_end(actor, today)
                end
          print(report(run).to_json)
        rescue ex : Time::Format::Error | ArgumentError
          print_error_and_exit(ex.message.to_s)
        end

        private def report(run : Partiduo::Api::Invoicing::MonthlyRunView)
          {
            "status"   => "ok",
            "months"   => run.months.map(&.to_s("%Y-%m")),
            "skipped"  => run.skipped,
            "prepared" => run.prepared.map do |row|
              {"customer" => row.customer_name, "currency" => row.currency_code, "invoice_id" => row.invoice_id,
               "number" => row.invoice_number, "status" => row.status, "error" => row.error}
            end,
          }
        end
      end
    end
  end
end
