# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    # Contrat du module Comptabilité — factures d'achat reçues (ADR-004 D9).
    # Une facture d'achat non électronique (papier, PDF simple) se saisit à
    # la main dans le journal d'achats avec sa pièce jointe ; elle est marquée
    # « reçue hors plateforme » et passe par le même contrôle de doublon que
    # les factures reçues par la plateforme agréée, que l'extension de
    # facturation électronique enregistre par la même commande (origine
    # `Platform`). Rien ici ne dépend d'une extension. Documentation :
    # `doc/api/accounting-received-invoices.adoc`.
    module Accounting
      # Origine d'une facture reçue ; libellé :
      # `accounting.received_invoice.origins.<code>`.
      enum ReceptionOrigin
        # Papier ou PDF simple, saisi à la main (« reçue hors plateforme »).
        OffPlatform
        # Reçue par la plateforme agréée (extension de facturation électronique).
        Platform

        def code : String
          to_s.underscore
        end

        def self.from_code(code : String) : self
          parse(code)
        end
      end

      # Facture d'achat reçue : l'écriture d'achat (`document`, pièce jointe
      # *obligatoire* dans `document.attachment_id`), le numéro de la facture
      # du fournisseur, sa date (`nil` = date de l'écriture), son origine et,
      # pour une facture de la plateforme, l'identifiant qu'elle lui donne.
      record ReceivedInvoiceInput,
        document : DocumentInput,
        number : String,
        invoice_date : Time? = nil,
        origin : ReceptionOrigin = ReceptionOrigin::OffPlatform,
        platform_reference : String = ""

      # Critères du contrôle de doublon : même fournisseur (fiche), même
      # numéro (sans casse, espaces ni séparateurs), même montant toutes taxes
      # comprises (au centime, négatif pour un avoir), dans la devise donnée
      # (`nil` : toutes devises).
      record DuplicateQuery,
        supplier_card_id : Int64,
        number : String,
        amount : BigDecimal,
        currency_code : String? = nil

      record ReceivedInvoiceView,
        id : Int64,
        entry_id : Int64,
        ledger_id : Int64,
        ledger_code : String,
        receipt : String?,
        entry_date : Time,
        supplier_card_id : Int64,
        supplier_code : String,
        supplier_name : String,
        number : String,
        invoice_date : Time,
        total_amount : BigDecimal,
        currency_code : String,
        origin : ReceptionOrigin,
        platform_reference : String,
        attachment_id : Int64?,
        cancelled : Bool,
        created_by_id : Int64?,
        created_at : Time,
        restricted : Bool = false do
        # « Reçue hors plateforme » (ADR-004 D9).
        def off_platform? : Bool
          origin.off_platform?
        end

        def origin_key : String
          "accounting.received_invoice.origins.#{origin.code}"
        end
      end

      # Factures reçues déjà enregistrées qui feraient doublon (écritures
      # annulées par extourne exclues). Même règle que
      # `post_received_invoice` ; pour la saisie et pour une extension de
      # réception avant de pré-comptabiliser. Une facture dont l'écriture est
      # dans un journal que l'acteur ne lit pas ne garde que le signal de
      # doublon (`restricted`, DECISIONS D-ACC-020) : numéro et date de la
      # facture, pas d'écriture, de journal, de fournisseur ni de montant.
      def self.received_invoice_duplicates(actor : Actor, query : DuplicateQuery) : Array(ReceivedInvoiceView)
        Guard.authorize!(actor, "accounting.entry.post", module_code: MODULE_CODE)
        rows = Partiduo::Accounting::ReceivedInvoices.duplicates(query.supplier_card_id, query.number, query.amount,
          query.currency_code)
        return [] of ReceivedInvoiceView if rows.empty?
        readable = actor.system ? nil : readable_ledger_ids(actor)
        rows.map do |row|
          view = Partiduo::Accounting::ReceivedInvoices.view(row)
          next view if readable.nil? || readable.includes?(view.ledger_id)
          view.copy_with(entry_id: 0_i64, ledger_id: 0_i64, ledger_code: "", receipt: nil, entry_date: view.invoice_date,
            supplier_code: "", supplier_name: "", total_amount: BigDecimal.new(0), platform_reference: "",
            attachment_id: nil, created_by_id: nil, restricted: true)
        end
      end

      # Règles complètes de `post_received_invoice`, sans écrire : écriture
      # calculée, ou refus (numéro, pièce jointe, doublon sous `number`).
      def self.check_received_invoice(actor : Actor, input : ReceivedInvoiceInput) : Result(EntryDraftView)
        Guard.authorize!(actor, "accounting.entry.post", module_code: MODULE_CODE)
        ledger = Partiduo::Accounting::Posting.writable_ledger(actor, input.document.ledger_id)
        draft, errors = received_draft(input, ledger)
        draft ? Result(EntryDraftView).success(draft_view(draft)) : Result(EntryDraftView).failure(errors)
      end

      # Enregistre une facture d'achat reçue : écriture du journal d'achats
      # (`post_purchase`, qui publie `entry.posted`) et facture rattachée.
      # Refusée si elle fait doublon (`accounting.errors.received_invoice.duplicate`).
      def self.post_received_invoice(actor : Actor, input : ReceivedInvoiceInput) : Result(ReceivedInvoiceView)
        Guard.authorize!(actor, "accounting.entry.post", module_code: MODULE_CODE)
        Transaction.run do
          ledger = Partiduo::Accounting::Posting.writable_ledger(actor, input.document.ledger_id)
          supplier_id = Partiduo::Accounting::ReceivedInvoices.supplier_id(input.document.third_party)
          supplier_id.try { |id| Partiduo::Accounting::ReceivedInvoices.lock_supplier!(id) }
          draft, errors = received_draft(input, ledger)
          next Result(ReceivedInvoiceView).failure(errors) if draft.nil? || supplier_id.nil?
          entry = Partiduo::Accounting::Posting.create!(actor, draft)
          row = Partiduo::Accounting::ReceivedInvoices.create!(entry, input, supplier_id, draft, actor)
          Result(ReceivedInvoiceView).success(Partiduo::Accounting::ReceivedInvoices.view(row))
        end
      end

      def self.received_invoice(actor : Actor, id : Int64) : ReceivedInvoiceView
        Guard.authorize!(actor, "accounting.entry.read", module_code: MODULE_CODE)
        row = Partiduo::Accounting::ReceivedInvoice.filter(id: id).first || raise NotFound.new("received_invoice", id)
        view = Partiduo::Accounting::ReceivedInvoices.view(row)
        raise NotFound.new("received_invoice", id) unless readable_ledger_ids(actor).includes?(view.ledger_id)
        view
      end

      # Facture reçue derrière une écriture, `nil` s'il n'y en a pas.
      def self.received_invoice_for_entry(actor : Actor, entry_id : Int64) : ReceivedInvoiceView?
        Guard.authorize!(actor, "accounting.entry.read", module_code: MODULE_CODE)
        row = Partiduo::Accounting::ReceivedInvoice.filter(entry_id: entry_id).first
        return unless row
        view = Partiduo::Accounting::ReceivedInvoices.view(row)
        readable_ledger_ids(actor).includes?(view.ledger_id) ? view : nil
      end

      # Écriture d'achat contrôlée, puis règles de la facture reçue.
      private def self.received_draft(input : ReceivedInvoiceInput,
                                      ledger : Partiduo::Accounting::Ledger) : {Partiduo::Accounting::Posting::Draft?, Array(FieldError)}
        errors = [] of FieldError
        unless ledger.kind == LedgerKind::Purchase.code
          errors << FieldError.new("ledger_id", "accounting.errors.entry.ledger.not_purchase", {"code" => ledger.code.to_s})
          return {nil, errors}
        end
        draft, document_errors = Partiduo::Accounting::Documents.build(input.document, ledger)
        errors.concat(document_errors)
        supplier_id = draft ? Partiduo::Accounting::ReceivedInvoices.supplier_id(input.document.third_party) : nil
        # Écriture valable mais tiers sans fiche lisible par le compte système
        # (quick code d'un compte sans fiche) : la facture reçue n'a pas de
        # fournisseur, refus sous `third_party`.
        if draft && supplier_id.nil?
          errors << FieldError.new("third_party", "accounting.errors.received_invoice.supplier.unknown",
            {"value" => input.document.third_party.strip})
        end
        errors.concat(Partiduo::Accounting::ReceivedInvoices.errors(input, supplier_id, draft))
        errors.empty? && draft ? {draft, errors} : {nil, errors}
      end
    end
  end
end
