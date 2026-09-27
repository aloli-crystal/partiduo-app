# SPDX-License-Identifier: AGPL-3.0-or-later

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

      # Types admis et extension du fichier stocké. Justificatifs : PDF (dont
      # Factur-X), photos, XML (UBL, CII), texte et CSV (relevés).
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
      }

      # Le contenu correspond-il au type annoncé ? Contrôle des signatures
      # (« nombres magiques ») des formats binaires, et du début d'un XML ; un
      # texte ne doit pas contenir d'octet nul.
      def self.signature_matches?(content_type : String, bytes : Bytes) : Bool
        case content_type
        when "application/pdf"
          starts_with?(bytes, "%PDF-".to_slice)
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
        when "application/xml", "text/xml"
          text = String.new(bytes[0, Math.min(bytes.size, 256)]).lchop("﻿").lstrip
          text.starts_with?('<')
        else
          !bytes.includes?(0_u8)
        end
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
    end
  end
end
