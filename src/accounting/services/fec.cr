# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Accounting
    # Fichier des écritures comptables (article A47 A-1 du livre des
    # procédures fiscales, arrêté du 29 juillet 2013 ; BOI-CF-IOR-60-40-20),
    # successeur de l'extension `noalyss-export` (`Export_FEC_CSV`) :
    #
    # * 18 zones dans l'ordre réglementaire, première ligne = noms des zones ;
    # * séparateur tabulation ou barre verticale, fin de ligne CRLF ;
    # * encodage ISO 8859-15 (défaut) ou UTF-8 ;
    # * dates `AAAAMMJJ`, montants à la virgule décimale sans séparateur de
    #   milliers, `Debit` et `Credit` en deux zones ;
    # * toutes les écritures validées d'un exercice (extournes comprises),
    #   dans l'ordre chronologique puis d'enregistrement ; `EcritureNum` en
    #   séquence continue ; lignes à zéro omises ;
    # * compte auxiliaire = fiche de tiers de la ligne (hors articles) ;
    #   lettrage et date de lettrage ; montant en devise et code ISO pour
    #   une écriture en devise étrangère ;
    # * nom `<SIREN>FEC<AAAAMMJJ>.txt`, date de clôture de l'exercice.
    module Fec
      alias Api = Partiduo::Api::Accounting

      COLUMNS = %w[JournalCode JournalLib EcritureNum EcritureDate CompteNum CompteLib CompAuxNum CompAuxLib
        PieceRef PieceDate EcritureLib Debit Credit EcritureLet DateLet ValidDate Montantdevise Idevise]

      TRANSLITERATIONS = {'’' => "'", '‘' => "'", '“' => "\"", '”' => "\"", '–' => "-", '—' => "-", '…' => "...",
                          '\u00A0' => " ", '\u202F' => " "}

      record Line,
        entry_id : Int64,
        ledger_code : String,
        ledger_name : String,
        date : Time,
        number : String,
        account_label : String,
        card_id : Int64?,
        receipt : String?,
        internal_code : String,
        label : String,
        entry_label : String,
        debit : Bool,
        amount : BigDecimal,
        matching_id : Int64?,
        matched_at : Time?,
        created_at : Time,
        currency_code : String,
        currency_amount : BigDecimal?

      # Bornes du fichier et date de clôture de l'exercice : l'exercice
      # demandé, ou les dates données (défaut : l'exercice qui contient la
      # date du jour, en entier), qui doivent tenir dans un même exercice.
      def self.range(query : Api::FecQuery) : {Time, Time, Time}?
        if id = query.fiscal_year_id
          year = Partiduo::Api::Core.fiscal_year(Partiduo::Api::Actor.system, id)
          from = year.starts_on || return
          to = year.ends_on || return
          return {from, to, to}
        end
        reference = Posting.day(query.date_to || query.date_from || Partiduo::Config.today)
        start, closing = ReportData.fiscal_bounds(reference) || return
        from = query.date_from.try { |day| Posting.day(day) } || start
        to = query.date_to.try { |day| Posting.day(day) } || closing
        return if from > to || from < start || to > closing
        {from, to, closing}
      end

      def self.build(query : Api::FecQuery, from : Time, to : Time, closing : Time) : {String, Bytes}
        base = Partiduo::Api::Core.base_currency(Partiduo::Api::Actor.system).code
        lines = lines(from, to)
        card_ids = lines.compact_map(&.card_id).uniq!
        cards = card_ids.empty? ? {} of Int64 => Partiduo::Api::Cards::CardView : ReportData.cards(Balances::AUXILIARY_KINDS)
        separator = query.separator.char
        text = String.build do |io|
          io << COLUMNS.join(separator) << "\r\n"
          number = 0
          previous = nil
          lines.each do |line|
            next if line.amount.zero?
            if line.entry_id != previous
              number += 1
              previous = line.entry_id
            end
            card = line.card_id.try { |id| cards[id]? }
            io << fields(line, number, card, line.currency_code != base).map { |field| clean(field) }.join(separator)
            io << "\r\n"
          end
        end
        content = query.encoding.utf8? ? text.to_slice : iso(text)
        {filename(closing), content}
      end

      # Les 18 zones d'une ligne, dans l'ordre de `COLUMNS`.
      private def self.fields(line : Line, number : Int32, card : Partiduo::Api::Cards::CardView?, foreign : Bool) : Array(String)
        zone = Partiduo::Config.time_zone
        date = line.date.to_s("%Y%m%d")
        zero = BigDecimal.new(0)
        currency = foreign ? {line.currency_amount.try { |value| amount(value) } || "", line.currency_code} : {"", ""}
        [
          line.ledger_code, line.ledger_name, number.to_s, date, line.number, line.account_label,
          card.try(&.code) || "", card.try(&.name) || "", line.receipt.presence || line.internal_code, date,
          label(line),
          amount(line.debit ? line.amount : zero), amount(line.debit ? zero : line.amount),
          line.matching_id.try { |id| Matchings.code(id) } || "",
          line.matched_at.try(&.in(zone).to_s("%Y%m%d")) || "",
          line.created_at.in(zone).to_s("%Y%m%d"), currency[0], currency[1],
        ]
      end

      # `EcritureLib` ne reste jamais vide : libellé de la ligne, de
      # l'écriture, sinon du compte.
      private def self.label(line : Line) : String
        line.label.presence || line.entry_label.presence || line.account_label
      end

      def self.amount(value : BigDecimal) : String
        format(value.round(2, mode: :ties_away).to_s)
      end

      # `1234.5` → `1234,50`.
      private def self.format(text : String) : String
        negative = text.starts_with?('-')
        integer, _, fraction = text.lchop('-').partition('.')
        "#{negative ? "-" : ""}#{integer},#{fraction.ljust(2, '0')[0, 2]}"
      end

      private def self.clean(field : String) : String
        field.gsub(/[\r\n\t|]/, " ").strip
      end

      # Caractères propres à ISO 8859-15 (ceux qu'ils remplacent dans
      # ISO 8859-1 ne sont pas représentables).
      ISO_8859_15 = {'€' => 0xA4_u8, 'Š' => 0xA6_u8, 'š' => 0xA8_u8, 'Ž' => 0xB4_u8, 'ž' => 0xB8_u8,
                     'Œ' => 0xBC_u8, 'œ' => 0xBD_u8, 'Ÿ' => 0xBE_u8}
      ISO_8859_1_ONLY = {0xA4, 0xA6, 0xA8, 0xB4, 0xB8, 0xBC, 0xBD, 0xBE}

      # Encodage ISO 8859-15 fait ici, caractère par caractère : un
      # caractère non représentable devient `?` après translittération des
      # ponctuations typographiques. (`String#encode` avec `invalid: :skip`
      # perdait des octets valides, DECISIONS D-ED-008.)
      def self.iso(text : String) : Bytes
        io = IO::Memory.new(text.bytesize)
        text.each_char do |char|
          if replacement = TRANSLITERATIONS[char]?
            io.write(replacement.to_slice)
          elsif byte = ISO_8859_15[char]?
            io.write_byte(byte)
          elsif char.ord < 0x100 && !ISO_8859_1_ONLY.includes?(char.ord)
            io.write_byte(char.ord.to_u8)
          else
            io.write_byte('?'.ord.to_u8)
          end
        end
        io.to_slice
      end

      def self.filename(closing : Time) : String
        siren = begin
          Partiduo::Api::Core.settings(Partiduo::Api::Actor.system).siren.gsub(/\s/, "")
        rescue Partiduo::Api::NotFound
          ""
        end
        "#{siren.presence || "000000000"}FEC#{closing.to_s("%Y%m%d")}.txt"
      end

      private def self.lines(from : Time, to : Time) : Array(Line)
        sql = <<-SQL
          SELECT e.id, l.code, l.name, e.date, a.number, a.label, x.card_id, e.receipt, COALESCE(e.internal_code, ''),
                 x.label, e.label, x.side = 'debit', x.amount, x.matching_id, m.created_at, e.created_at,
                 e.currency_code, x.currency_amount
          FROM accounting_entry_line x
          JOIN accounting_entry e ON e.id = x.entry_id
          JOIN accounting_ledger l ON l.id = e.ledger_id
          JOIN accounting_account a ON a.id = x.account_id
          LEFT JOIN accounting_matching m ON m.id = x.matching_id
          WHERE e.date >= $1::date AND e.date <= $2::date
          ORDER BY e.date, e.id, x.position, x.id
          SQL
        Marten::DB::Connection.default.open do |db|
          db.query_all(sql, args: [from, to] of ::DB::Any) do |result_set|
            Line.new(
              entry_id: result_set.read(Int64), ledger_code: result_set.read(String),
              ledger_name: result_set.read(String), date: result_set.read(Time), number: result_set.read(String),
              account_label: result_set.read(String), card_id: result_set.read(Int64?),
              receipt: result_set.read(String?), internal_code: result_set.read(String),
              label: result_set.read(String), entry_label: result_set.read(String), debit: result_set.read(Bool),
              amount: result_set.read(BigDecimal), matching_id: result_set.read(Int64?),
              matched_at: result_set.read(Time?), created_at: result_set.read(Time),
              currency_code: result_set.read(String), currency_amount: result_set.read(BigDecimal?),
            )
          end
        end
      end
    end
  end
end
