# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    # Contrat du socle — stockage des pièces jointes (ADR-006 D1). Le module
    # qui rattache une pièce (écriture, facture, fiche) garde son identifiant
    # et une clé étrangère vers `core_attachment` ; la boîte « Justificatifs à
    # traiter » relève de l'extension `partiduo-document` (ADR-005 D8).
    module Core
      # Fichier déposé : nom d'origine, type MIME annoncé, contenu.
      record AttachmentInput, filename : String, content_type : String, content : IO

      record AttachmentView,
        id : Int64,
        filename : String,
        content_type : String,
        byte_size : Int64,
        sha256 : String,
        uploaded_by_id : Int64?,
        created_at : Time

      # Enregistre une pièce jointe. Le type doit être admis et correspondre
      # au contenu ; la taille est limitée à `Attachments::MAX_BYTES`.
      def self.store_attachment(actor : Actor, input : AttachmentInput) : Result(AttachmentView)
        Guard.authorize!(actor, "core.attachment.write")
        rules = Partiduo::Core::Attachments
        content_type = input.content_type.split(';').first.strip.downcase
        filename = rules.clean_filename(input.filename)
        bytes = read_limited(input.content, Partiduo::Core::Attachments::MAX_BYTES + 1)

        errors = [] of FieldError
        if filename.empty?
          errors << FieldError.new("filename", "core.errors.attachment.filename.blank")
        elsif filename.size > Partiduo::Core::Attachments::MAX_FILENAME
          errors << FieldError.new("filename", "core.errors.attachment.filename.too_long",
            {"max" => Partiduo::Core::Attachments::MAX_FILENAME.to_s})
        end
        if bytes.empty?
          errors << FieldError.new("content", "core.errors.attachment.content.empty")
        elsif bytes.size > Partiduo::Core::Attachments::MAX_BYTES
          errors << FieldError.new("content", "core.errors.attachment.content.too_large",
            {"max" => (Partiduo::Core::Attachments::MAX_BYTES // (1024 * 1024)).to_s})
        end
        if !Partiduo::Core::Attachments::TYPES.has_key?(content_type)
          errors << FieldError.new("content_type", "core.errors.attachment.content_type.unsupported",
            {"value" => content_type})
        elsif !bytes.empty? && !rules.signature_matches?(content_type, bytes)
          errors << FieldError.new("content_type", "core.errors.attachment.content_type.mismatch",
            {"value" => content_type})
        end
        return Result(AttachmentView).failure(errors) unless errors.empty?

        Transaction.run do
          storage = Marten.media_files_storage
          name = storage.save(rules.storage_name(content_type), IO::Memory.new(bytes))
          # Transaction annulée : le fichier écrit ne doit pas rester orphelin.
          Marten::DB::Connection.default.observe_transaction_rollback(-> { storage.delete(name) rescue nil; nil })
          attachment = Partiduo::Core::Attachment.create!(
            storage_name: name,
            filename: filename,
            content_type: content_type,
            byte_size: bytes.size.to_i64,
            sha256: rules.sha256(bytes),
            uploaded_by_id: actor.user_id,
          )
          Result(AttachmentView).success(attachment_view(attachment))
        end
      end

      def self.attachment(actor : Actor, id : Int64) : AttachmentView
        Guard.authorize!(actor, "core.attachment.read")
        attachment_view(find_attachment(id))
      end

      # Contenu d'une pièce jointe. Lève `Partiduo::Api::AttachmentCorrupted`
      # si l'empreinte ne correspond plus au fichier stocké.
      def self.attachment_content(actor : Actor, id : Int64) : Bytes
        Guard.authorize!(actor, "core.attachment.read")
        attachment = find_attachment(id)
        io = Marten.media_files_storage.open(attachment.storage_name!)
        bytes = begin
          io.getb_to_end
        ensure
          io.close
        end
        if Partiduo::Core::Attachments.sha256(bytes) != attachment.sha256
          raise AttachmentCorrupted.new(id)
        end
        bytes
      end

      # Supprime une pièce jointe que plus rien ne cite ; le fichier est
      # effacé du stockage après la validation de la transaction.
      def self.delete_attachment(actor : Actor, id : Int64) : Result(Nil)
        Guard.authorize!(actor, "core.attachment.write")
        Transaction.run do
          attachment = Partiduo::Core::Attachment.all.lock.filter(id: id).first || raise NotFound.new("attachment", id)
          deleted = Partiduo::Core::Db.delete_unless_referenced([
            {"DELETE FROM core_attachment WHERE id = $1", [id] of ::DB::Any},
          ])
          next Result(Nil).failure(FieldError.base("core.errors.attachment.in_use")) unless deleted
          name = attachment.storage_name!
          Partiduo::Events.after_commit { Marten.media_files_storage.delete(name) rescue nil }
          Result(Nil).success(nil)
        end
      end

      private def self.read_limited(io : IO, limit : Int32) : Bytes
        buffer = IO::Memory.new
        IO.copy(io, buffer, limit)
        buffer.to_slice
      end

      private def self.find_attachment(id : Int64) : Partiduo::Core::Attachment
        Partiduo::Core::Attachment.filter(id: id).first || raise NotFound.new("attachment", id)
      end

      private def self.attachment_view(attachment : Partiduo::Core::Attachment) : AttachmentView
        AttachmentView.new(
          id: attachment.id!.to_i64,
          filename: attachment.filename!,
          content_type: attachment.content_type!,
          byte_size: attachment.byte_size!.to_i64,
          sha256: attachment.sha256!,
          uploaded_by_id: attachment.uploaded_by_id.try(&.to_i64),
          created_at: attachment.created_at!,
        )
      end
    end

    # Le fichier stocké ne correspond plus à l'empreinte enregistrée : pièce
    # altérée ou perdue hors de l'application.
    class AttachmentCorrupted < Exception
      getter attachment_id : Int64

      def initialize(@attachment_id : Int64)
        super("pièce jointe #{@attachment_id} altérée")
      end

      def key : String
        "core.errors.attachment.corrupted"
      end
    end
  end
end
