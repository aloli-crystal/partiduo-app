# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Invoicing
    # Numérotation à l'émission (ADR-006 D5) : table de compteurs, une ligne
    # par série et par année, verrouillée par `SELECT … FOR UPDATE` dans la
    # transaction d'émission. Jamais une séquence PostgreSQL : une émission
    # annulée rend son numéro, sans trou ; deux émissions simultanées
    # attendent l'une l'autre sur le verrou, sans doublon (et l'index unique
    # `(series, number)` le garantit en dernier recours).
    #
    # Format : `<préfixe>-<année>-<numéro sur 4 chiffres au moins>`
    # (`F-2026-0001`). Une série par nature de document.
    module Numbering
      SERIES = {
        "quote"           => "D",
        "order"           => "C",
        "delivery_note"   => "BL",
        "invoice"         => "F",
        "deposit_invoice" => "FA",
        "credit_note"     => "AV",
        "return_note"     => "BR",
      }

      # Chiffre de la série dans la communication structurée belge.
      SERIES_DIGIT = {"F" => 1, "FA" => 2, "AV" => 3, "D" => 4, "C" => 5, "BL" => 6, "BR" => 7}

      record Allocation, series : String, year : Int32, sequence : Int32, number : String

      def self.series_for(kind : String) : String
        SERIES[kind]
      end

      def self.format(series : String, year : Int32, sequence : Int32) : String
        "#{series}-#{year}-#{sequence.to_s.rjust(4, '0')}"
      end

      # Attribue le numéro suivant de la série pour `date`, dans la
      # transaction courante. `nil` si `date` précède la date du dernier
      # document émis dans la série (chronologie), avec cette date.
      def self.allocate!(series : String, date : Time) : Allocation | Time
        year = date.year
        Marten::DB::Connection.default.open do |db|
          db.exec("INSERT INTO invoicing_counter (series, year, last_number) VALUES ($1, $2, 0) " \
                  "ON CONFLICT (series, year) DO NOTHING", series, year)
        end
        counter = Counter.filter(series: series, year: year).lock.first!
        if (last = counter.last_date) && date < last
          return last
        end
        sequence = counter.last_number!.to_i32 + 1
        counter.last_number = sequence
        counter.last_date = date
        counter.save!
        Allocation.new(series, year, sequence, format(series, year, sequence))
      end

      # Communication structurée belge (`+++123/4567/89012+++`) : dix chiffres
      # (année sur deux, chiffre de série, numéro sur sept) suivis du reste de
      # leur division par 97 (97 si le reste est nul).
      def self.structured_reference(series : String, year : Int32, sequence : Int32) : String
        base = "#{(year % 100).to_s.rjust(2, '0')}#{SERIES_DIGIT.fetch(series, 9)}#{sequence.to_s.rjust(7, '0')}"
        check = base.to_i64 % 97
        check = 97 if check.zero?
        digits = "#{base}#{check.to_s.rjust(2, '0')}"
        "+++#{digits[0, 3]}/#{digits[3, 4]}/#{digits[7, 5]}+++"
      end

      # Contrôle d'une communication structurée (modulo 97).
      def self.valid_structured_reference?(text : String) : Bool
        digits = text.gsub(/[^0-9]/, "")
        return false unless digits.size == 12
        check = digits[0, 10].to_i64 % 97
        check = 97 if check.zero?
        check == digits[10, 2].to_i
      end
    end
  end
end
