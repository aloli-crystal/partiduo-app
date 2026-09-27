# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Cards
    # Quick code d'une fiche (`Card#code`), successeur des fonctions
    # `comptaproc.format_quickcode`, `insert_quick_code` et
    # `update_quick_code`, et de leurs tests (`ficheTest`).
    module QuickCode
      MAX_SIZE = 64
      # Code de repli quand ni la saisie ni le nom ne fournissent de caractère.
      FALLBACK = "CRD"
      # Longueur de la base tirée du nom (`substr(tName, 1, 6)`).
      NAME_BASE = 6
      # Nombre maximal de suffixes essayés (`nDuplicate > 99999`).
      MAX_DUPLICATES = 99_999

      REMOVED = " $€µ£%+/\\!(){}(),;&|\"#'^<>*"
      ACCENTS = {'é' => 'e', 'è' => 'e', 'ê' => 'e', 'ë' => 'e', 'à' => 'a', 'â' => 'a', 'ä' => 'a',
                 'ï' => 'i', 'î' => 'i', 'ü' => 'u', 'û' => 'u', 'ù' => 'u', 'ö' => 'o', 'ô' => 'o',
                 'ç' => 'c'}

      # `format_quickcode` : minuscules, sans blanc ni caractère réservé,
      # accents français ôtés, puis majuscules. `"a+z+1-5"` → `"AZ1-5"`,
      # `"ÀÉ@Ê"` → `"AE@E"`, `"####"` → `""`.
      def self.format(value : String) : String
        text = value.strip.downcase
        String.build do |io|
          text.each_char do |char|
            next if char.whitespace? || REMOVED.includes?(char)
            io << ACCENTS.fetch(char, char)
          end
        end.upcase
      end

      # Base d'un code généré : les six premiers caractères du nom formaté, ou
      # `CRD` (`insert_quick_code`).
      def self.base_from_name(name : String) : String
        format(name)[0, NAME_BASE].presence || FALLBACK
      end

      # Premier code libre : `base`, puis `base1`, `base2`… (`insert_quick_code`).
      # `except_id` : la fiche elle-même, lors d'une modification.
      def self.available(base : String, except_id : Int64 | Int32? = nil) : String
        base = base[0, MAX_SIZE]
        return base unless taken?(base, except_id)
        (1..MAX_DUPLICATES).each do |counter|
          suffix = counter.to_s
          candidate = base[0, MAX_SIZE - suffix.size] + suffix
          return candidate unless taken?(candidate, except_id)
        end
        raise ArgumentError.new("trop de fiches de code #{base}")
      end

      def self.taken?(code : String, except_id : Int64 | Int32? = nil) : Bool
        query = Card.filter(code: code)
        query = query.exclude(id: except_id) if except_id
        query.exists?
      end
    end
  end
end
