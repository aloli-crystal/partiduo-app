# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Core
    # Pièce jointe stockée par le socle (ADR-006 D1) : le fichier vit dans le
    # stockage de fichiers de Marten (`media_files`), la ligne en décrit
    # l'origine et l'empreinte. Remplace les _large objects_ d'origine
    # (`jrn.jr_pj oid`, ADR-001 D1).
    #
    # Le socle ne sait pas à quoi la pièce est rattachée : l'écriture, la
    # facture ou la fiche qui l'utilise porte une clé étrangère vers elle, ce
    # qui en interdit la suppression tant qu'elle est citée.
    class Attachment < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      # Nom dans le stockage (`attachments/2026/09/<uuid>.pdf`).
      field :storage_name, :string, max_size: 255, unique: true
      # Nom du fichier tel que déposé, pour l'affichage et le téléchargement.
      field :filename, :string, max_size: 255
      field :content_type, :string, max_size: 128
      field :byte_size, :big_int
      field :sha256, :string, max_size: 64
      field :uploaded_by_id, :big_int, null: true, blank: true

      with_timestamp_fields
    end
  end
end
