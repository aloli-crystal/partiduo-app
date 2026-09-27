# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Accounting
    # Factures d'achat reçues (ADR-004 D9) : numéro, date et montant de la
    # facture du fournisseur, origine (hors plateforme ou plateforme agréée),
    # contrôle de doublon commun à la saisie manuelle et aux extensions de
    # réception. Service interne, appelé par `Partiduo::Api::Accounting`.
    module ReceivedInvoices
      alias Api = Partiduo::Api::Accounting
      alias FieldError = Partiduo::Api::FieldError

      MAX_NUMBER    = 100
      MAX_REFERENCE = 100

      # Numéro normalisé : majuscules, sans espace ni séparateur usuel
      # (`FB-2026 0918/4471` = `FB20260918 4471` = `fb20260918-4471`).
      def self.number_key(number : String) : String
        number.upcase.gsub(/[\s\-_.\/]/, "")
      end

      # Montant comparé au centime (deux décimales, arrondi commercial — la
      # demie s'éloigne de zéro — et non l'arrondi bancaire, mode par défaut
      # de `BigDecimal#round` : 119,985 vaut 119,99).
      def self.amount_key(amount : BigDecimal) : BigDecimal
        amount.round(2, mode: :ties_away)
      end

      # Factures reçues du même fournisseur, de même numéro normalisé et de
      # même montant toutes taxes comprises (dans la même devise si elle est
      # donnée), dont l'écriture n'est pas annulée par extourne.
      def self.duplicates(supplier_card_id : Int64, number : String, amount : BigDecimal,
                          currency_code : String? = nil) : Array(ReceivedInvoice)
        key = number_key(number)
        return [] of ReceivedInvoice if key.empty?
        rows = ReceivedInvoice.filter(supplier_card_id: supplier_card_id, number_key: key).order(:id).to_a
        rows = rows.select do |row|
          amount_key(row.total_amount!) == amount_key(amount) && (currency_code.nil? || row.currency_code == currency_code)
        end
        return rows if rows.empty?
        # Écritures lues en une requête (pas une par facture).
        reversed = Entry.filter(id__in: rows.map(&.entry_id)).to_a.to_h { |entry| {entry.id, entry.reversed!} }
        rows.reject { |row| reversed[row.entry_id]? != false }
      end

      # Contrôles propres à la facture reçue, l'écriture étant déjà
      # contrôlée (`draft`) : numéro, pièce jointe, doublon.
      def self.errors(input : Api::ReceivedInvoiceInput, supplier_card_id : Int64?,
                      draft : Posting::Draft?) : Array(FieldError)
        errors = [] of FieldError
        number = input.number.strip
        if number.empty?
          errors << FieldError.new("number", "accounting.errors.received_invoice.number.blank")
        elsif number.size > MAX_NUMBER
          errors << FieldError.new("number", "accounting.errors.received_invoice.number.too_long",
            {"max" => MAX_NUMBER.to_s})
        end
        if input.platform_reference.size > MAX_REFERENCE
          errors << FieldError.new("platform_reference", "accounting.errors.received_invoice.platform_reference.too_long",
            {"max" => MAX_REFERENCE.to_s})
        end
        if input.document.attachment_id.nil?
          errors << FieldError.new("attachment_id", "accounting.errors.received_invoice.attachment.required")
        end
        # Doublon cherché dès que le numéro, le fournisseur et le montant sont
        # connus, même si la pièce jointe manque encore (retour instantané).
        total = draft.try(&.document_total)
        if errors.none?(&.field.==("number")) && supplier_card_id && total && draft
          duplicate = duplicates(supplier_card_id, number, total, draft.header.currency_code).first?
          if duplicate
            entry = Entry.filter(id: duplicate.entry_id).first!
            errors << FieldError.new("number", "accounting.errors.received_invoice.duplicate", {
              "number"  => duplicate.number.to_s,
              "receipt" => entry.receipt.presence || entry.internal_code.to_s,
              "date"    => duplicate.invoice_date!.to_s("%Y-%m-%d"),
            })
          end
        end
        errors
      end

      # Fiche du fournisseur (quick code de l'écriture).
      def self.supplier_id(code : String) : Int64?
        Partiduo::Api::Cards.card_by_code(Partiduo::Api::Actor.system, code.strip).try(&.id)
      end

      # Sérialise les saisies d'un même fournisseur jusqu'à la fin de la
      # transaction : deux saisies simultanées de la même facture ne passent
      # pas toutes deux le contrôle de doublon.
      def self.lock_supplier!(supplier_card_id : Int64) : Nil
        Marten::DB::Connection.default.open(&.exec("SELECT pg_advisory_xact_lock(hashtext($1))",
          "received_invoice:#{supplier_card_id}"))
      end

      def self.create!(entry : Entry, input : Api::ReceivedInvoiceInput, supplier_card_id : Int64,
                       draft : Posting::Draft, actor : Partiduo::Api::Actor) : ReceivedInvoice
        number = input.number.strip
        ReceivedInvoice.create!(
          entry_id: entry.id, supplier_card_id: supplier_card_id, number: number, number_key: number_key(number),
          invoice_date: Posting.day(input.invoice_date || input.document.date),
          total_amount: draft.document_total || BigDecimal.new(0), currency_code: draft.header.currency_code,
          origin: input.origin.code, platform_reference: input.platform_reference.strip,
          created_by_id: actor.user_id,
        )
      end

      def self.view(row : ReceivedInvoice) : Api::ReceivedInvoiceView
        entry = Entry.filter(id: row.entry_id).first!
        ledger = Ledger.filter(id: entry.ledger_id).first!
        supplier_id = row.supplier_card_id!.to_i64
        supplier = begin
          Partiduo::Api::Cards.card(Partiduo::Api::Actor.system, supplier_id)
        rescue Partiduo::Api::NotFound
          nil
        end
        Api::ReceivedInvoiceView.new(
          id: row.id!.to_i64, entry_id: entry.id!.to_i64, ledger_id: ledger.id!.to_i64, ledger_code: ledger.code.to_s,
          receipt: entry.receipt, entry_date: entry.date!, supplier_card_id: supplier_id,
          supplier_code: supplier.try(&.code) || "", supplier_name: supplier.try(&.name) || "",
          number: row.number.to_s, invoice_date: row.invoice_date!, total_amount: row.total_amount!,
          currency_code: row.currency_code.to_s, origin: Api::ReceptionOrigin.from_code(row.origin.to_s),
          platform_reference: row.platform_reference.to_s, attachment_id: entry.attachment_id.try(&.to_i64),
          cancelled: entry.reversed!, created_by_id: row.created_by_id.try(&.to_i64), created_at: row.created_at!,
        )
      end
    end
  end
end
