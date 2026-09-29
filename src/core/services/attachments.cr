# SPDX-License-Identifier: AGPL-3.0-or-later

require "compress/zip"
require "digest/sha256"
require "uuid"

module Partiduo
  module Core
    # Règles du stockage des pièces jointes (ADR-006 D1) : types admis,
    # signature du contenu, taille, nom dans le stockage.
    module Attachments
      # Taille maximale d'une pièce (20 Mio).
      MAX_BYTES = 20 * 1024 * 1024

      MAX_FILENAME = 255

      # Types MIME des documents de traitement de texte admis : OpenDocument
      # (ODT) et Office Open XML (DOCX), produits par les modèles de factures
      # (ADR-010, DECISIONS D-HOOK-003).
      ODT  = "application/vnd.oasis.opendocument.text"
      DOCX = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

      # Types admis et extension du fichier stocké. Justificatifs : PDF (dont
      # Factur-X), photos, XML (UBL, CII), texte et CSV (relevés) ; documents
      # ODT et DOCX.
      TYPES = {
        "application/pdf" => ".pdf",
        "image/png"       => ".png",
        "image/jpeg"      => ".jpg",
        "image/webp"      => ".webp",
        "image/heic"      => ".heic",
        "image/tiff"      => ".tiff",
        "application/xml" => ".xml",
        "text/xml"        => ".xml",
        "text/plain"      => ".txt",
        "text/csv"        => ".csv",
        ODT               => ".odt",
        DOCX              => ".docx",
      }

      # En-tête local d'une entrée d'archive ZIP.
      ZIP_SIGNATURE = Bytes[0x50, 0x4B, 0x03, 0x04]

      # Le contenu correspond-il au type annoncé ? Contrôle des signatures
      # (« nombres magiques ») des formats binaires, du début d'un XML et de
      # la structure des archives ODT et DOCX ; un texte ne doit pas contenir
      # d'octet nul.
      def self.signature_matches?(content_type : String, bytes : Bytes) : Bool
        case content_type
        when "application/pdf"
          starts_with?(bytes, "%PDF-".to_slice)
        when .starts_with?("image/")
          image?(content_type, bytes)
        when "application/xml", "text/xml"
          text = String.new(bytes[0, Math.min(bytes.size, 256)]).lchop("﻿").lstrip
          text.starts_with?('<')
        when ODT
          odt?(bytes)
        when DOCX
          docx?(bytes)
        else
          !bytes.includes?(0_u8)
        end
      end

      # Signature d'une image admise.
      def self.image?(content_type : String, bytes : Bytes) : Bool
        case content_type
        when "image/png"
          starts_with?(bytes, Bytes[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        when "image/jpeg"
          starts_with?(bytes, Bytes[0xFF, 0xD8, 0xFF])
        when "image/webp"
          bytes.size >= 12 && starts_with?(bytes, "RIFF".to_slice) && bytes[8, 4] == "WEBP".to_slice
        when "image/tiff"
          starts_with?(bytes, "II*\0".to_slice) || starts_with?(bytes, "MM\0*".to_slice)
        when "image/heic"
          bytes.size >= 12 && bytes[4, 4] == "ftyp".to_slice
        else
          false
        end
      end

      # Archive OpenDocument texte : la première entrée de l'archive ZIP est
      # `mimetype`, stockée sans compression, et contient exactement le type
      # ODT (OpenDocument 1.3, partie 3, § 3.3).
      def self.odt?(bytes : Bytes) : Bool
        return false unless bytes.size >= 30 && starts_with?(bytes, ZIP_SIGNATURE)
        method = little_endian16(bytes, 8)
        size = little_endian32(bytes, 18)
        name_size = little_endian16(bytes, 26)
        extra_size = little_endian16(bytes, 28)
        start = 30 + name_size + extra_size
        return false unless method == 0 && size == ODT.bytesize && bytes.size >= start + size
        String.new(bytes[30, name_size]) == "mimetype" && String.new(bytes[start, size]) == ODT
      end

      # Archive Office Open XML de traitement de texte : archive ZIP lisible
      # qui contient `[Content_Types].xml` et `word/document.xml`.
      def self.docx?(bytes : Bytes) : Bool
        return false unless starts_with?(bytes, ZIP_SIGNATURE)
        names = Compress::Zip::File.open(IO::Memory.new(bytes)) { |zip| zip.entries.map(&.filename) }
        names.includes?("[Content_Types].xml") && names.includes?("word/document.xml")
      rescue Compress::Zip::Error | IO::Error | ArgumentError | IndexError | OverflowError
        # Archive tronquée ou mal formée.
        false
      end

      # Nom de fichier affichable : sans chemin, sans caractère de contrôle.
      def self.clean_filename(filename : String) : String
        name = filename.gsub('\\', '/').split('/').last? || ""
        name.gsub(/[[:cntrl:]]/, "").strip
      end

      # Nom dans le stockage : `attachments/AAAA/MM/<uuid><ext>`. Le nom déposé
      # n'y figure pas (ni collision, ni caractère inattendu dans un chemin).
      def self.storage_name(content_type : String, now : Time = Time.utc) : String
        "attachments/#{now.to_s("%Y/%m")}/#{UUID.random}#{TYPES[content_type]}"
      end

      def self.sha256(bytes : Bytes) : String
        Digest::SHA256.hexdigest(bytes)
      end

      private def self.starts_with?(bytes : Bytes, prefix : Bytes) : Bool
        bytes.size >= prefix.size && bytes[0, prefix.size] == prefix
      end

      private def self.little_endian16(bytes : Bytes, offset : Int32) : Int32
        IO::ByteFormat::LittleEndian.decode(UInt16, bytes[offset, 2]).to_i32
      end

      private def self.little_endian32(bytes : Bytes, offset : Int32) : Int64
        IO::ByteFormat::LittleEndian.decode(UInt32, bytes[offset, 4]).to_i64
      end
    end
  end
end
