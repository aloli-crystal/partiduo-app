# SPDX-License-Identifier: AGPL-3.0-or-later

require "csv"
require "compress/zip"

module Partiduo
  module Invoicing
    # Transmission au comptable en Facturation seule (ADR-006 D4) :
    #
    # * journal des ventes et des encaissements en CSV (`;`, UTF-8, montants
    #   au point décimal), une ligne par mouvement : client au débit, ventes
    #   et TVA au crédit par groupe de TVA (sens inverse pour un avoir),
    #   banque et client pour un règlement ;
    # * même journal des ventes au format du fichier des écritures comptables
    #   (FEC, art. A47 A-1 du LPF : 18 colonnes, `|`, virgule décimale),
    #   *partiel* : ventes seules ;
    # * archive ZIP des PDF Factur-X (factures, acomptes, avoirs) d'une
    #   période, avec un index CSV (numéro, date, client, TTC, SHA-256).
    #
    # Comptes : ceux des paramètres, sinon ceux du plan du régime
    # (`Configuration::DEFAULT_ACCOUNTS`) ; compte auxiliaire = quick code du
    # client.
    module Exports
      alias Api = Partiduo::Api::Invoicing

      record Movement,
        journal : String,
        date : Time,
        piece : String,
        kind : String,
        customer_code : String,
        customer_name : String,
        account : String,
        account_label : String,
        auxiliary : String,
        label : String,
        debit : BigDecimal,
        credit : BigDecimal,
        currency : String

      def self.fiscal_documents(from : Time, to : Time) : Array(Document)
        Document.filter(kind__in: Api::FISCAL_KINDS, issue_date__gte: Documents.day(from),
          issue_date__lte: Documents.day(to)).exclude(number: nil).order(:issue_date, :kind, :sequence).to_a
      end

      def self.sales_movements(from : Time, to : Time) : Array(Movement)
        journal = Configuration.settings.sales_journal_code
        accounts = Configuration.accounts
        fiscal_documents(from, to).flat_map { |document| document_movements(document, journal, accounts) }
      end

      # Mouvements d'un document fiscal : client, puis ventes et TVA par
      # groupe (sens inverse pour un avoir), puis acomptes extournés.
      private def self.document_movements(document : Document, journal : String, accounts) : Array(Movement)
        zero = BigDecimal.new(0)
        movements = [] of Movement
        customer = Documents.customer(document)
        credit_note = document.kind == "credit_note"
        label = "#{I18n.t("invoicing.kinds.#{document.kind}")} #{document.number} #{customer.name}"
        base = {journal: journal, date: (document.issue_date || raise "document émis sans date"), piece: document.number.to_s,
                kind: document.kind!, customer_code: customer.code, customer_name: customer.name,
                label: label, currency: document.currency_code!}
        # Le client ne porte que le solde : TTC − acomptes déduits
        # (D-INT-004, D-2F-001).
        prepaid = credit_note ? zero : document.prepaid_amount!
        receivable = document.total_gross! - prepaid
        unless receivable.zero?
          movements << Movement.new(**base.merge({account: accounts[:customer], auxiliary: customer.code,
                                                  account_label: I18n.t("invoicing.exports.accounts.customer"),
                                                  debit: credit_note ? zero : receivable, credit: credit_note ? receivable : zero}))
        end
        Documents.totals(document).groups.each do |group|
          {sales: group.base, vat: group.vat}.each do |role, amount|
            next if amount.zero?
            movements << Movement.new(**base.merge({account: accounts[role], auxiliary: "",
                                                    account_label: I18n.t("invoicing.exports.accounts.#{role}"),
                                                    debit: credit_note ? amount : zero, credit: credit_note ? zero : amount}))
          end
        end
        movements.concat(deposit_reversals(document, base)) if prepaid > 0
        movements
      end

      # Acomptes déduits d'une facture finale : leurs ventes et leur TVA,
      # déjà passées à leur émission, sont extournées (au débit), comme
      # l'écriture de la Comptabilité (D-INT-004). Un acompte déduit ne porte
      # jamais d'avoir (D-2F-004) : ses groupes de TVA valent son TTC.
      private def self.deposit_reversals(document : Document, base) : Array(Movement)
        accounts = Configuration.accounts
        zero = BigDecimal.new(0)
        movements = [] of Movement
        Documents.deductions(Documents.id_of(document.id)).each do |deduction|
          deposit = Documents.find(deduction.deposit_id)
          label = "#{I18n.t("invoicing.exports.deposit_deducted")} #{deposit.number} #{base[:customer_name]}"
          Documents.totals(deposit).groups.each do |group|
            unless group.base.zero?
              movements << Movement.new(**base.merge({account: accounts[:sales], auxiliary: "", label: label,
                                                      account_label: I18n.t("invoicing.exports.accounts.sales"),
                                                      debit: group.base, credit: zero}))
            end
            unless group.vat.zero?
              movements << Movement.new(**base.merge({account: accounts[:vat], auxiliary: "", label: label,
                                                      account_label: I18n.t("invoicing.exports.accounts.vat"),
                                                      debit: group.vat, credit: zero}))
            end
          end
        end
        movements
      end

      def self.payment_movements(from : Time, to : Time) : Array(Movement)
        settings = Configuration.settings
        accounts = Configuration.accounts
        zero = BigDecimal.new(0)
        Payment.filter(paid_on__gte: Documents.day(from), paid_on__lte: Documents.day(to)).order(:paid_on, :id)
          .flat_map do |payment|
            document = Documents.find(Documents.id_of(payment.document_id))
            customer = Documents.customer(document)
            label = "#{I18n.t("invoicing.exports.payment")} #{document.number} #{customer.name}"
            base = {journal: settings.bank_journal_code, date: payment.paid_on!, piece: document.number.to_s,
                    kind: "payment", customer_code: customer.code, customer_name: customer.name, label: label,
                    currency: document.currency_code!}
            [
              Movement.new(**base.merge({account: accounts[:bank], auxiliary: "",
                                         account_label: I18n.t("invoicing.exports.accounts.bank"), debit: payment.amount!, credit: zero})),
              Movement.new(**base.merge({account: accounts[:customer], auxiliary: customer.code,
                                         account_label: I18n.t("invoicing.exports.accounts.customer"), debit: zero, credit: payment.amount!})),
            ]
          end
      end

      # Cellule texte d'un CSV : une valeur qui commence par `=`, `+`, `-`,
      # `@` (ou une tabulation, un retour chariot) serait lue comme une
      # formule par un tableur ; elle est préfixée d'une apostrophe (D-2F-009).
      def self.cell(text : String) : String
        text.starts_with?(/[=+\-@\t\r]/) ? "'#{text}" : text
      end

      def self.csv(from : Time, to : Time) : Bytes
        CSV.build(separator: ';') do |csv|
          csv.row %w[journal date piece kind customer_code customer_name account auxiliary label debit credit currency]
          (sales_movements(from, to) + payment_movements(from, to)).each do |movement|
            csv.row [cell(movement.journal), movement.date.to_s("%Y-%m-%d"), cell(movement.piece), movement.kind,
                     cell(movement.customer_code), cell(movement.customer_name), cell(movement.account),
                     cell(movement.auxiliary), cell(movement.label), FacturxXml.format_decimal(movement.debit, 2),
                     FacturxXml.format_decimal(movement.credit, 2), movement.currency]
          end
        end.to_slice
      end

      FEC_COLUMNS = %w[JournalCode JournalLib EcritureNum EcritureDate CompteNum CompteLib CompAuxNum CompAuxLib
        PieceRef PieceDate EcritureLib Debit Credit EcritureLet DateLet ValidDate Montantdevise Idevise]

      # FEC des ventes. `Debit` et `Credit` sont en devise de tenue : un
      # document en devise étrangère est converti au cours du socle à sa
      # date d'émission (montant ÷ cours, au centime ; l'arrondi est porté
      # par la ligne du client pour que la pièce reste équilibrée), et son
      # montant d'origine va dans `Montantdevise`. Sans cours à cette date :
      # erreur `invoicing.errors.export.currency_rate`, aucun fichier.
      def self.fec(from : Time, to : Time) : {Bytes?, Array(Partiduo::Api::FieldError)}
        journal_label = I18n.t("invoicing.exports.sales_journal")
        base_currency = Configuration.base_currency
        errors = [] of Partiduo::Api::FieldError
        amount = ->(value : BigDecimal) { FacturxXml.format_decimal(value, 2).tr(".", ",") }
        content = String.build do |io|
          io << FEC_COLUMNS.join('|') << "\r\n"
          sales_movements(from, to).chunk_while { |a, b| a.piece == b.piece && a.journal == b.journal }.each do |piece|
            foreign = piece.first.currency != base_currency
            converted = foreign ? convert(piece, errors) : piece.map { |movement| {movement.debit, movement.credit} }
            next if converted.nil?
            piece.each_with_index do |movement, index|
              debit, credit = converted[index]
              date = movement.date.to_s("%Y%m%d")
              fields = [movement.journal, journal_label, movement.piece, date, movement.account, movement.account_label,
                        movement.auxiliary, movement.auxiliary.empty? ? "" : movement.customer_name, movement.piece,
                        date, movement.label, amount.call(debit), amount.call(credit), "", "", date,
                        foreign ? amount.call(movement.debit + movement.credit) : "", foreign ? movement.currency : ""]
              io << fields.map(&.gsub(/[|\r\n]/, " ")).join('|') << "\r\n"
            end
          end
        end
        errors.empty? ? {content.to_slice, errors} : {nil, errors}
      end

      # Montants d'une pièce en devise convertis en devise de tenue ; `nil`
      # (et une erreur) sans cours du socle à la date de la pièce.
      private def self.convert(piece : Array(Movement), errors : Array(Partiduo::Api::FieldError)) : Array({BigDecimal, BigDecimal})?
        first = piece.first
        rate = Partiduo::Api::Core.rate_on(Partiduo::Api::Actor.system, first.currency, first.date)
        if rate.nil? || rate <= 0
          errors << Documents.error(Partiduo::Api::FieldError::BASE, "export.currency_rate",
            {"code" => first.currency, "date" => first.date.to_s("%Y-%m-%d"), "number" => first.piece})
          return
        end
        zero = BigDecimal.new(0)
        values = piece.map do |movement|
          {(movement.debit / rate).round(2, mode: :ties_away), (movement.credit / rate).round(2, mode: :ties_away)}
        end
        gap = values.sum(zero, &.[0]) - values.sum(zero, &.[1])
        unless gap.zero?
          index = piece.index { |movement| !movement.auxiliary.empty? } || 0
          debit, credit = values[index]
          values[index] = debit > 0 ? {debit - gap, credit} : {debit, credit + gap}
        end
        values
      end

      def self.fec_filename(to : Time) : String
        siren = Configuration.company.siren.gsub(/\s/, "")
        "#{siren.presence || "000000000"}FEC#{to.to_s("%Y%m%d")}.txt"
      end

      def self.archive(from : Time, to : Time) : Bytes
        files = [] of {String, Bytes}
        index = CSV.build(separator: ';') do |csv|
          csv.row %w[number kind issue_date customer total_gross currency file sha256]
          fiscal_documents(from, to).each do |document|
            pdf_id = document.pdf_id
            next unless pdf_id
            content = Partiduo::Api::Core.attachment_content(Partiduo::Api::Actor.system, Documents.id_of(pdf_id))
            name = "#{document.number}.pdf"
            files << {name, content}
            csv.row [document.number.to_s, document.kind.to_s, (document.issue_date || raise "document émis sans date").to_s("%Y-%m-%d"),
                     cell(Documents.customer(document).name), FacturxXml.format_decimal(document.total_gross!, 2),
                     document.currency_code.to_s, name, Digest::SHA256.hexdigest(content)]
          end
        end
        io = IO::Memory.new
        Compress::Zip::Writer.open(io) do |zip|
          files.each { |(name, content)| zip.add(name, content) }
          zip.add("index.csv", index)
        end
        io.to_slice
      end
    end
  end
end
