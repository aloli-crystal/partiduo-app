# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Invoicing
    # Relances (ADR-006 D5) : jusqu'à trois niveaux (délais après l'échéance
    # dans les paramètres), *proposées* — jamais envoyées sans validation.
    # À partir du niveau `penalty_from_level`, la relance chiffre les
    # pénalités : intérêts = solde × taux annuel × jours de retard / 365
    # (arrondi au centime), et l'indemnité forfaitaire de 40 € pour un client
    # professionnel. Sans taux paramétré (taux légal variable), seuls les
    # jours de retard et l'indemnité sont chiffrés.
    module Reminders
      alias Api = Partiduo::Api::Invoicing

      def self.view(reminder : Reminder, document : Document? = nil) : Api::ReminderView
        document ||= Documents.find(Documents.id_of(reminder.document_id))
        Api::ReminderView.new(
          id: Documents.id_of(reminder.id), document_id: Documents.id_of(document.id),
          document_number: document.number.to_s, customer_name: Documents.customer(document).name,
          level: reminder.level!.to_i32, status: reminder.status!, proposed_on: reminder.proposed_on!,
          due_date: document.due_date, days_late: reminder.days_late!.to_i32, balance: reminder.balance!,
          interest: reminder.interest!, indemnity: reminder.indemnity!, sent_at: reminder.sent_at,
          payment_rejection_id: reminder.payment_rejection_id.try(&.to_i64),
        )
      end

      # Propose, pour chaque facture échue et non soldée, la relance du plus
      # haut niveau atteint qui n'a pas encore été proposée. Idempotent.
      def self.propose!(on : Time) : Array(Api::ReminderView)
        settings = Configuration.settings
        on = Documents.day(on)
        proposed = [] of Api::ReminderView
        Document.filter(kind__in: Payments::PAYABLE_KINDS, status__in: %w[issued sent partially_paid])
          .filter(due_date__lt: on).order(:due_date, :id).each do |document|
          balance = Payments.balance(document)
          next unless balance > 0
          due_date = document.due_date
          next unless due_date
          days = (on - due_date).total_days.to_i32
          level = (1..3).to_a.reverse.find { |candidate| days >= settings.reminder_days(candidate) }
          next unless level
          document_id = Documents.id_of(document.id)
          next if Reminder.filter(document_id: document_id, level__gte: level).exists?
          interest, indemnity = penalties(document, balance, days, level, settings)
          reminder = Reminder.create!(document_id: document_id, level: level, status: "proposed", proposed_on: on,
            days_late: days, balance: balance, interest: interest, indemnity: indemnity)
          proposed << view(reminder, document)
        end
        proposed
      end

      # Relance proposée aussitôt après un rejet de paiement (D-INV3-009) :
      # niveau suivant le plus haut déjà proposé (1 sans relance), même si la
      # facture n'est pas encore échue ; `nil` si les trois niveaux sont
      # pris (l'alerte « À traiter » demeure). Jamais envoyée sans
      # validation.
      def self.propose_after_rejection!(document : Document) : Reminder?
        balance = Payments.balance(document)
        return unless balance > 0
        document_id = Documents.id_of(document.id)
        last = Reminder.filter(document_id: document_id).order("-level").first.try(&.level!.to_i32) || 0
        level = last + 1
        return if level > 3
        on = Documents.today
        days = document.due_date.try { |due| Math.max((on - due).total_days.to_i32, 0) } || 0
        interest, indemnity = penalties(document, balance, days, level, Configuration.settings)
        Reminder.create!(document_id: document_id, level: level, status: "proposed", proposed_on: on,
          days_late: days, balance: balance, interest: interest, indemnity: indemnity)
      end

      def self.penalties(document : Document, balance : BigDecimal, days : Int32, level : Int32,
                         settings : Api::SettingsView) : {BigDecimal, BigDecimal}
        zero = BigDecimal.new(0)
        from = settings.penalty_from_level
        return {zero, zero} if from.zero? || level < from
        interest = if rate = settings.late_penalty_rate
                     Calculator.round(balance * rate * days / (100 * 365))
                   else
                     zero
                   end
        indemnity = Documents.customer(document).professional? ? Mentions::INDEMNITY : zero
        {interest, indemnity}
      end

      # Objet et corps du courriel de relance, dans la langue du document :
      # textes des paramètres s'ils sont renseignés, sinon textes livrés.
      def self.message(reminder : Reminder, document : Document) : {String, String}
        settings = Configuration.settings
        view = view(reminder, document)
        locale = document.locale!
        params = {
          "number"    => view.document_number,
          "customer"  => view.customer_name,
          "due_date"  => Output.format_date(view.due_date, locale),
          "days"      => view.days_late.to_s,
          "balance"   => Output.format_amount(view.balance, locale, document.currency_code!),
          "interest"  => Output.format_amount(view.interest, locale, document.currency_code!),
          "indemnity" => Output.format_amount(view.indemnity, locale, document.currency_code!),
          "total"     => Output.format_amount(view.total_claimed, locale, document.currency_code!),
          "seller"    => Documents.seller(document).name,
        }
        if rejection = reminder.payment_rejection_id.try { |id| PaymentRejection.filter(id: id).first }
          return rejection_message(rejection, document, params, view)
        end
        I18n.with_locale(locale) do
          subject = settings.reminder_subject.presence.try { |text| interpolate(text, params) } ||
                    I18n.t("invoicing.reminders.subject.level#{view.level}", params)
          body = settings.reminder_body.presence.try { |text| interpolate(text, params) } ||
                 I18n.t("invoicing.reminders.body.level#{view.level}", params)
          if view.interest > 0 || view.indemnity > 0
            body = "#{body}\n\n#{I18n.t("invoicing.reminders.penalties", params)}"
          end
          {subject, body}
        end
      end

      # Relance d'un règlement rejeté : le courriel rappelle le règlement, son
      # rejet et son motif (textes livrés, dans la langue du document).
      private def self.rejection_message(rejection : PaymentRejection, document : Document,
                                         params : Hash(String, String), view : Api::ReminderView) : {String, String}
        locale = document.locale!
        payment = Payment.filter(id: rejection.payment_id).first!
        I18n.with_locale(locale) do
          all = params.merge({
            "paid_on" => Output.format_date(payment.paid_on!, locale),
            "amount"  => Output.format_amount(rejection.amount!, locale, document.currency_code!),
            "reason"  => I18n.t("invoicing.rejection_reasons.#{rejection.reason}"),
          })
          subject = I18n.t("invoicing.reminders.rejected.subject", all)
          body = I18n.t("invoicing.reminders.rejected.body", all)
          if view.interest > 0 || view.indemnity > 0
            body = "#{body}\n\n#{I18n.t("invoicing.reminders.penalties", all)}"
          end
          {subject, body}
        end
      end

      # Remplace `%{clé}` par sa valeur (textes saisis dans les paramètres).
      def self.interpolate(text : String, params : Hash(String, String)) : String
        text.gsub(/%\{(\w+)\}/) { |match| params[$1]? || match }
      end
    end
  end
end
