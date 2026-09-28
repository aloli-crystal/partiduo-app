# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    # Contrat du module Facturation (ADR-006 D4, D5, D6) : entrées et vues.
    # Les commandes et requêtes sont dans `invoicing.cr` ; référence :
    # link:../../../doc/api/invoicing.adoc[].
    module Invoicing
      # Natures de document, dans l'ordre de la chaîne documentaire.
      KINDS = %w[quote order delivery_note invoice deposit_invoice credit_note]
      # Documents fiscaux : PDF/A-3 Factur-X, série sans trou, intangibles.
      FISCAL_KINDS         = %w[invoice deposit_invoice credit_note]
      LINE_KINDS           = %w[item free note title subtotal]
      DISCOUNT_KINDS       = %w[none percent amount]
      OPERATION_CATEGORIES = %w[goods services mixed]
      PAYMENT_METHODS      = %w[transfer card cheque cash direct_debit other]
      QUOTE_DECISIONS      = %w[accepted refused]
      # Transformations admises : nature source → natures produites.
      TRANSFORMATIONS = {
        "quote"           => %w[order delivery_note invoice deposit_invoice],
        "order"           => %w[delivery_note invoice deposit_invoice],
        "delivery_note"   => %w[invoice],
        "invoice"         => %w[credit_note],
        "deposit_invoice" => %w[credit_note],
      }
      # Canaux d'émission d'un document fiscal (ADR-004 D9) : plateforme agréée
      # (transmise par une extension, `partiduo-einvoicing`), courriel, papier,
      # portail public de facturation (`public_portal`, Chorus Pro) pour un
      # client public (ADR-004 D9 révisé : proposé quand l'extension
      # `partiduo-choruspro` est active ; choisi à la main sinon, dépôt hors
      # Partiduo puis « envoyé »). DECISIONS D-CPY-003.
      ISSUE_CHANNELS = %w[platform email paper public_portal]
      # Actions de l'historique d'un document (`DocumentEventView#action`),
      # liste fermée : l'interface a un libellé pour chacune (D-CPY-007).
      DOCUMENT_EVENT_ACTIONS = %w[created updated transformed issued accepted refused credited payment
        payment_removed reminder emailed email_failed channel_changed marked_sent platform_deposited
        platform_deposit_ignored pdf_copy_sent pdf_copy_failed]
      # Code UNTDID 1001 du document Factur-X (BT-3).
      TYPE_CODES = {"invoice" => "380", "credit_note" => "381", "deposit_invoice" => "386"}

      # --- Entrées ---------------------------------------------------------------

      # Ligne d'un document.
      #
      # * `kind` : `item` (article du socle, fiche de nature `item`), `free`
      #   (désignation libre chiffrée), `note` (texte seul), `title`
      #   (intertitre), `subtotal` (sous-total des lignes depuis le titre ou le
      #   sous-total précédent, calculé) ;
      # * article : `description`, `unit_code`, `unit_price` et `vat_rate_id`
      #   à `nil` reprennent la fiche (désignation, unité, prix de vente, taux
      #   par défaut) ;
      # * `unit_code` : code UN/ECE (recommandation n° 20), `C62` par défaut ;
      # * `discount_kind` : `none`, `percent` (0 à 100) ou `amount` (montant HT
      #   retranché du brut de la ligne, deux décimales au plus).
      record LineInput,
        kind : String = "item",
        item_card_id : Int64? = nil,
        description : String? = nil,
        quantity : BigDecimal = BigDecimal.new(1),
        unit_code : String? = nil,
        unit_price : BigDecimal? = nil,
        discount_kind : String = "none",
        discount_value : BigDecimal = BigDecimal.new(0),
        vat_rate_id : Int64? = nil

      # Saisie d'un document (brouillon) ; décrit le document entier, lignes
      # comprises (remplacées à chaque enregistrement).
      #
      # * `issue_date` : date prévue (l'émission la fixe, par défaut au jour) ;
      # * `delivery_date` : date de livraison ou de fin de prestation (BT-72),
      #   par défaut la date d'émission ;
      # * `due_date` : échéance, par défaut émission + délai de paiement des
      #   paramètres ; `validity_date` : fin de validité d'un devis ;
      # * `operation_category` : `goods`, `services` ou `mixed` (mention
      #   obligatoire), par défaut celle des paramètres ;
      # * `delivery_address` : `nil` reprend l'adresse de livraison par défaut
      #   du client ;
      # * `global_discount_kind`, `global_discount_value` : remise globale
      #   (BT-107), en pourcentage ou en montant HT ;
      # * `deposit_ids` : factures d'acompte émises à déduire (facture) ;
      # * `credited_document_id` : facture corrigée (avoir, obligatoire) ;
      # * `issue_channel` : canal d'émission d'un document fiscal
      #   (`ISSUE_CHANNELS`) ; `nil` garde celui du brouillon pour le même
      #   client, sinon reprend la proposition (`propose_channel`) ; refusé
      #   pour un devis, une commande ou un bon de livraison ;
      # * `b2c` : marquage B2C pour l'e-reporting ; `nil` : même règle.
      record DocumentInput,
        kind : String,
        customer_card_id : Int64,
        lines : Array(LineInput) = [] of LineInput,
        issue_date : Time? = nil,
        delivery_date : Time? = nil,
        due_date : Time? = nil,
        validity_date : Time? = nil,
        currency_code : String? = nil,
        operation_category : String? = nil,
        delivery_address : Api::Cards::AddressInput? = nil,
        buyer_reference : String? = nil,
        order_reference : String? = nil,
        notes : String? = nil,
        global_discount_kind : String = "none",
        global_discount_value : BigDecimal = BigDecimal.new(0),
        locale : String? = nil,
        layout_id : Int64? = nil,
        deposit_ids : Array(Int64) = [] of Int64,
        credited_document_id : Int64? = nil,
        issue_channel : String? = nil,
        b2c : Bool? = nil

      # Transformation d'un document émis en document suivant (lignes
      # recopiées, lien conservé). `deposit_percent` : pourcentage de la
      # facture d'acompte (obligatoire pour `deposit_invoice`).
      record TransformInput, kind : String, deposit_percent : BigDecimal? = nil

      # Changement du canal d'émission (ADR-004 D9), jusqu'à l'envoi ;
      # `b2c` à `nil` garde le marquage en place.
      record ChannelInput, channel : String, b2c : Bool? = nil

      # Émission : `issue_date` remplace la date prévue du brouillon.
      record IssueInput, issue_date : Time? = nil

      # Règlement saisi (Comptabilité inactive seulement, ADR-006 D3).
      record PaymentInput,
        document_id : Int64,
        amount : BigDecimal,
        paid_on : Time,
        method : String = "transfer",
        reference : String? = nil

      # Envoi par courriel ; `subject` et `body` à `nil` : textes par défaut
      # dans la langue du document.
      record SendInput,
        to : Array(String),
        cc : Array(String) = [] of String,
        subject : String? = nil,
        body : String? = nil

      # `issue_channel` : canal d'émission (`ISSUE_CHANNELS`), filtré par
      # PostgreSQL (extensions de canal, D-CPP-004).
      record DocumentQuery,
        kind : String? = nil,
        status : String? = nil,
        customer_card_id : Int64? = nil,
        from : Time? = nil,
        to : Time? = nil,
        search : String? = nil,
        limit : Int32 = 100,
        offset : Int32 = 0,
        issue_channel : String? = nil

      # Paramètres (ligne entière). Taux en pourcentage.
      record SettingsInput,
        payment_terms_days : Int32 = 30,
        quote_validity_days : Int32 = 30,
        late_penalty_rate : BigDecimal? = nil,
        early_discount_rate : BigDecimal? = nil,
        early_discount_days : Int32? = nil,
        vat_on_debits : Bool = false,
        default_operation_category : String = "services",
        iban : String = "",
        bic : String = "",
        sender_email : String = "",
        sender_name : String = "",
        reminder1_days : Int32 = 7,
        reminder2_days : Int32 = 30,
        reminder3_days : Int32 = 60,
        penalty_from_level : Int32 = 2,
        reminder_subject : String = "",
        reminder_body : String = "",
        sales_journal_code : String = "VT",
        bank_journal_code : String = "BQ",
        customer_account : String = "",
        sales_account : String = "",
        vat_account : String = "",
        bank_account : String = "",
        pdf_copy_enabled : Bool = true,
        pdf_copy_from : Time? = nil,
        pdf_copy_until : Time? = nil

      # Modèle de mise en page : ni mention, ni montant, seulement l'aspect.
      record LayoutInput,
        name : String,
        logo_attachment_id : Int64? = nil,
        primary_color : String = "#1f5f73",
        text_color : String = "#1a1a1a",
        header_text : String = "",
        footer_text : String = "",
        is_default : Bool = false

      # --- Vues ------------------------------------------------------------------

      record LineView,
        position : Int32,
        kind : String,
        item_card_id : Int64?,
        description : String,
        quantity : BigDecimal,
        unit_code : String,
        unit_price : BigDecimal,
        discount_kind : String,
        discount_value : BigDecimal,
        discount_amount : BigDecimal,
        gross_amount : BigDecimal,
        vat_rate_id : Int64?,
        vat_percent : BigDecimal,
        vat_category : String,
        net_amount : BigDecimal do
        def priced? : Bool
          kind.in?("item", "free")
        end
      end

      # Récapitulatif de TVA (BG-23), par catégorie, taux et motif.
      record VatBreakdownView,
        category : String,
        percent : BigDecimal,
        exemption_code : String,
        exemption_reason : String,
        lines_total : BigDecimal,
        allowance : BigDecimal,
        base : BigDecimal,
        vat : BigDecimal

      # Totaux : `amount_due` = TTC − acomptes déduits − règlements − avoirs.
      record TotalsView,
        lines_total : BigDecimal,
        discount_total : BigDecimal,
        total_net : BigDecimal,
        total_vat : BigDecimal,
        total_gross : BigDecimal,
        prepaid : BigDecimal,
        paid : BigDecimal,
        credited : BigDecimal do
        def amount_due : BigDecimal
          total_gross - prepaid - paid - credited
        end

        # Montant à payer imprimé sur le document (BT-115).
        def payable : BigDecimal
          total_gross - prepaid
        end
      end

      # Partie (vendeur ou client) telle qu'imprimée.
      record PartyView,
        name : String,
        code : String,
        legal_form : String,
        share_capital : BigDecimal?,
        rcs : String,
        siren : String,
        siret : String,
        vat_number : String,
        line1 : String,
        line2 : String,
        postcode : String,
        city : String,
        country_code : String,
        email : String,
        phone : String,
        routing_id : String,
        nature : String = "" do
        # Client professionnel ou public (ADR-004 D9 : nature du client) ;
        # sans nature (identités figées avant la nature explicite) : SIREN ou
        # numéro de TVA.
        def professional? : Bool
          return nature.in?("business", "public") unless nature.empty?
          !siren.empty? || !vat_number.empty?
        end

        def address_lines : Array(String)
          [line1, line2, "#{postcode} #{city}".strip].reject(&.empty?)
        end
      end

      record AddressView,
        line1 : String,
        line2 : String,
        postcode : String,
        city : String,
        country_code : String do
        def lines : Array(String)
          [line1, line2, "#{postcode} #{city}".strip].reject(&.empty?)
        end
      end

      # Mention obligatoire générée : `code` stable, message traduit par
      # `key` et `params` dans la langue voulue (`message`).
      record MentionView, code : String, key : String, params : Hash(String, String) = {} of String => String do
        def message : String
          I18n.t(key, params)
        end
      end

      record LinkView, id : Int64, kind : String, number : String?, status : String do
        def kind_key : String
          "invoicing.kinds.#{kind}"
        end
      end

      record DeductionView, deposit_id : Int64, deposit_number : String, amount : BigDecimal

      record DocumentView,
        id : Int64,
        kind : String,
        status : String,
        effective_status : String,
        series : String,
        number : String?,
        customer_card_id : Int64,
        customer : PartyView,
        seller : PartyView,
        source : LinkView?,
        derived : Array(LinkView),
        credited : LinkView?,
        credit_notes : Array(LinkView),
        locale : String,
        currency_code : String,
        issue_date : Time?,
        delivery_date : Time?,
        due_date : Time?,
        validity_date : Time?,
        operation_category : String,
        vat_on_debits : Bool,
        buyer_reference : String,
        order_reference : String,
        notes : String,
        global_discount_kind : String,
        global_discount_value : BigDecimal,
        delivery_address : AddressView?,
        structured_reference : String,
        lines : Array(LineView),
        vat_breakdown : Array(VatBreakdownView),
        totals : TotalsView,
        deductions : Array(DeductionView),
        mentions : Array(MentionView),
        layout_id : Int64?,
        issued_at : Time?,
        issued_by_id : Int64?,
        fingerprint : String,
        pdf_attachment_id : Int64?,
        sent_at : Time?,
        created_at : Time,
        updated_at : Time,
        issue_channel : String = "",
        b2c : Bool = false do
        def draft? : Bool
          number.nil?
        end

        # Canal d'émission et marquage B2C modifiables : document fiscal pas
        # encore envoyé (ADR-004 D9).
        def channel_editable? : Bool
          fiscal? && sent_at.nil?
        end

        def channel_key : String
          "invoicing.channels.#{issue_channel.presence || "none"}"
        end

        def fiscal? : Bool
          FISCAL_KINDS.includes?(kind)
        end

        # Code Factur-X (380, 381, 386) ; `nil` hors documents fiscaux.
        def type_code : String?
          TYPE_CODES[kind]?
        end

        def kind_key : String
          "invoicing.kinds.#{kind}"
        end

        def status_key : String
          "invoicing.statuses.#{effective_status}"
        end

        # « issu du devis D-2026-0031 » : clé et paramètres du lien d'origine.
        def origin_mention : MentionView?
          source.try do |link|
            MentionView.new("origin", "invoicing.links.from_#{link.kind}", {"number" => link.number.to_s})
          end
        end
      end

      record PaymentView,
        id : Int64,
        document_id : Int64,
        document_number : String,
        paid_on : Time,
        amount : BigDecimal,
        method : String,
        reference : String,
        source : String,
        matching_id : String,
        recorded_by_id : Int64?,
        created_at : Time

      record ReminderView,
        id : Int64,
        document_id : Int64,
        document_number : String,
        customer_name : String,
        level : Int32,
        status : String,
        proposed_on : Time,
        due_date : Time?,
        days_late : Int32,
        balance : BigDecimal,
        interest : BigDecimal,
        indemnity : BigDecimal,
        sent_at : Time? do
        def total_claimed : BigDecimal
          balance + interest + indemnity
        end
      end

      record EmailLogView,
        id : Int64,
        document_id : Int64,
        reminder_id : Int64?,
        recipients : Array(String),
        subject : String,
        attachment_name : String,
        attachment_sha256 : String,
        message_id : String,
        status : String,
        error : String,
        sent_by_id : Int64?,
        created_at : Time

      # Opération tracée sur un document (qui, quand, empreinte).
      record EventView,
        action : String,
        user_id : Int64?,
        fingerprint : String,
        details : Hash(String, String),
        created_at : Time

      record SettingsView,
        payment_terms_days : Int32,
        quote_validity_days : Int32,
        late_penalty_rate : BigDecimal?,
        early_discount_rate : BigDecimal?,
        early_discount_days : Int32?,
        vat_on_debits : Bool,
        default_operation_category : String,
        iban : String,
        bic : String,
        sender_email : String,
        sender_name : String,
        reminder1_days : Int32,
        reminder2_days : Int32,
        reminder3_days : Int32,
        penalty_from_level : Int32,
        reminder_subject : String,
        reminder_body : String,
        sales_journal_code : String,
        bank_journal_code : String,
        customer_account : String,
        sales_account : String,
        vat_account : String,
        bank_account : String,
        pdf_copy_enabled : Bool = true,
        pdf_copy_from : Time? = nil,
        pdf_copy_until : Time? = nil do
        # Copie PDF due à la date `on` (ADR-004 D9) : option active et date
        # dans la période ; une période vide sera posée au premier envoi par
        # la plateforme (un an).
        def pdf_copy_active?(on : Time) : Bool
          return false unless pdf_copy_enabled
          from = pdf_copy_from
          upto = pdf_copy_until
          return true if from.nil? && upto.nil?
          (from.nil? || from <= on) && (upto.nil? || on <= upto)
        end

        def reminder_days(level : Int32) : Int32
          case level
          when 1 then reminder1_days
          when 2 then reminder2_days
          else        reminder3_days
          end
        end

        def to_input : SettingsInput
          SettingsInput.new(
            payment_terms_days: payment_terms_days, quote_validity_days: quote_validity_days,
            late_penalty_rate: late_penalty_rate, early_discount_rate: early_discount_rate,
            early_discount_days: early_discount_days, vat_on_debits: vat_on_debits,
            default_operation_category: default_operation_category, iban: iban, bic: bic,
            sender_email: sender_email, sender_name: sender_name, reminder1_days: reminder1_days,
            reminder2_days: reminder2_days, reminder3_days: reminder3_days, penalty_from_level: penalty_from_level,
            reminder_subject: reminder_subject, reminder_body: reminder_body,
            sales_journal_code: sales_journal_code, bank_journal_code: bank_journal_code,
            customer_account: customer_account, sales_account: sales_account, vat_account: vat_account,
            bank_account: bank_account, pdf_copy_enabled: pdf_copy_enabled, pdf_copy_from: pdf_copy_from,
            pdf_copy_until: pdf_copy_until,
          )
        end
      end

      record LayoutView,
        id : Int64,
        name : String,
        logo_attachment_id : Int64?,
        primary_color : String,
        text_color : String,
        header_text : String,
        footer_text : String,
        is_default : Bool

      # Document en une ligne, lu dans les totaux enregistrés (sans relire
      # ses lignes) : listes courtes du tableau de bord.
      record DocumentSummaryView,
        id : Int64,
        kind : String,
        number : String?,
        status : String,
        effective_status : String,
        customer_name : String,
        currency_code : String,
        total_net : BigDecimal,
        total_gross : BigDecimal,
        amount_due : BigDecimal,
        issue_date : Time?,
        due_date : Time?,
        created_at : Time do
        def draft? : Bool
          number.nil?
        end
      end

      # Synthèse de la facturation au jour `on`, agrégée par PostgreSQL à
      # partir des totaux enregistrés (D-2F-005) :
      #
      # * `open_*` : factures et acomptes émis, non annulés, au solde positif ;
      #   `overdue_*` : ceux dont l'échéance est passée ; `overdue_customers` :
      #   trois clients au plus, de l'échéance la plus ancienne ;
      # * `billed_*` : HT facturé dans le mois de `on` (factures moins avoirs,
      #   hors acomptes), nombre de factures et d'avoirs ;
      # * `quotes_waiting_*` : devis envoyés encore valides (HT) ;
      #   `quotes_expired` : devis envoyés périmés ;
      # * `drafts` : brouillons, toutes natures ;
      # * `recent_invoices` : les cinq dernières factures.
      record SummaryView,
        on : Time,
        open_count : Int32,
        open_amount : BigDecimal,
        overdue_count : Int32,
        overdue_amount : BigDecimal,
        overdue_customers : Array(String),
        billed_net : BigDecimal,
        billed_invoices : Int32,
        billed_credit_notes : Int32,
        quotes_waiting_count : Int32,
        quotes_waiting_net : BigDecimal,
        quotes_expired : Int32,
        drafts : Int32,
        recent_invoices : Array(DocumentSummaryView)

      # État de la copie PDF d'une facture au canal `platform` (ADR-004 D9
      # révisé, D-CPY-001) : `eligible` (document émis au canal plateforme),
      # `due` (option du dossier active à la date du jour, client qui
      # l'accepte et a une adresse électronique), `deposited_at` (dépôt
      # réussi sur la plateforme), dernière copie envoyée (`sent_at`,
      # `sent_to`, `sent_count` envois en tout), dernier échec postérieur
      # (`failed_at` ; `error` : clé(s) de traduction séparées par « , »,
      # `invoicing.errors.…` ; `error_detail` : détail technique, message du
      # serveur de courrier ou de la conformité, qui renseigne le paramètre
      # `%{error}` / `%{detail}` de la clé ; D-CPY-006, D-CPY-007).
      record PdfCopyStatusView,
        eligible : Bool,
        due : Bool,
        deposited_at : Time?,
        sent_at : Time?,
        sent_to : Array(String),
        sent_count : Int32,
        failed_at : Time?,
        error : String,
        error_detail : String = ""

      # Canal proposé pour un client (ADR-004 D9) : `platform` pour un
      # professionnel établi dans le pays du dossier (SIREN ou numéro de TVA),
      # sinon `email` si la fiche a une adresse électronique, `paper` à
      # défaut ; `b2c` pour un client sans SIREN ni numéro de TVA. `reason` :
      # `domestic_business`, `foreign_business`, `private_customer` ou
      # `public_customer` (Chorus Pro, canal `public_portal`, extension
      # `CHORUSPRO` active) ou `public_customer_manual` (client public sans
      # l'extension : courriel ou papier proposé, dépôt à la main sur le
      # portail) (libellé `invoicing.channel_reasons.<reason>`) ; `international` :
      # client établi hors du pays du dossier (e-reporting des ventes
      # internationales).
      record ChannelProposalView, channel : String, b2c : Bool, reason : String, international : Bool do
        def reason_key : String
          "invoicing.channel_reasons.#{reason}"
        end
      end

      # Fichier produit (PDF, XML, CSV, FEC, ZIP).
      record FileView, filename : String, content_type : String, content : Bytes
    end
  end
end
