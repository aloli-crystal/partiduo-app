# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

require "digest/crc32"

private alias Api = Partiduo::Api::Core
private alias R = ReferentialSpec

private PDF = "%PDF-1.7\n1 0 obj << >> endobj\n%%EOF\n"

private def writer : Partiduo::Api::Actor
  actor_with("core.attachment.read", "core.attachment.write")
end

private ODT_TYPE  = Partiduo::Core::Attachments::ODT
private DOCX_TYPE = Partiduo::Core::Attachments::DOCX

# Archive ZIP construite par la bibliothèque standard : `entries` dans
# l'ordre, `mimetype` écrit sans compression (comme l'exige OpenDocument).
# L'heure des entrées est fixée : deux archives construites de part et
# d'autre d'une seconde restent identiques octet pour octet.
private def zip(entries : Array({String, String}), stored : Array(String) = ["mimetype"]) : String
  io = IO::Memory.new
  Compress::Zip::Writer.open(io) do |writer|
    entries.each do |name, body|
      entry = Compress::Zip::Writer::Entry.new(name, time: Time.utc(2026, 1, 1))
      if stored.includes?(name)
        entry.compression_method = Compress::Zip::CompressionMethod::STORED
        entry.crc32 = Digest::CRC32.checksum(body)
        entry.compressed_size = entry.uncompressed_size = body.bytesize.to_u32
      end
      writer.add(entry, body)
    end
  end
  String.new(io.to_slice)
end

private def odt(mimetype : String = ODT_TYPE, first : Bool = true, stored : Bool = true) : String
  parts = [{"content.xml", "<office:document-content/>"}, {"META-INF/manifest.xml", "<manifest/>"}]
  mime = {"mimetype", mimetype}
  zip(first ? [mime] + parts : parts + [mime], stored ? ["mimetype"] : [] of String)
end

private def docx(names : Array(String) = ["[Content_Types].xml", "_rels/.rels", "word/document.xml"]) : String
  zip(names.map { |name| {name, "<x/>"} })
end

private def store(content : String = PDF, filename : String = "facture.pdf",
                  content_type : String = "application/pdf") : Partiduo::Api::Result(Api::AttachmentView)
  Api.store_attachment(writer, Api::AttachmentInput.new(filename, content_type, IO::Memory.new(content)))
end

describe "Partiduo::Api::Core — pièces jointes (ADR-006 D1)" do
  it "stocke le fichier, son empreinte et son déposant" do
    view = store.value!
    view.filename.should eq("facture.pdf")
    view.content_type.should eq("application/pdf")
    view.byte_size.should eq(PDF.bytesize)
    view.sha256.should eq(Digest::SHA256.hexdigest(PDF))
    view.uploaded_by_id.should eq(1_i64)
    String.new(Api.attachment_content(writer, view.id)).should eq(PDF)
    Api.attachment(writer, view.id).should eq(view)
  end

  it "ne garde du nom déposé que le nom de fichier" do
    store(filename: "../../etc/C:\\temp\\relevé\u0007.pdf").value!.filename.should eq("relevé.pdf")
  end

  it "refuse un type non admis, un contenu qui ne correspond pas, un fichier vide" do
    result = store(content: "MZ\x90\x00", filename: "virus.exe", content_type: "application/x-msdownload")
    result.error_keys.should eq(["core.errors.attachment.content_type.unsupported"])
    mismatch = store(content: "pas un PDF", content_type: "application/pdf")
    mismatch.error_keys.should eq(["core.errors.attachment.content_type.mismatch"])
    empty = store(content: "", filename: " ")
    empty.error_keys.should eq(["core.errors.attachment.filename.blank", "core.errors.attachment.content.empty"])
    R.expect_translated(result)
    R.expect_translated(mismatch)
    R.expect_translated(empty)
  end

  it "accepte PNG, JPEG, XML et CSV d'après leur signature" do
    store("\x89PNG\r\n\x1A\n....", "photo.png", "image/png").success?.should be_true
    store("\xFF\xD8\xFF\xE0....", "photo.jpg", "image/jpeg").success?.should be_true
    store("\uFEFF<?xml version=\"1.0\"?><Invoice/>", "facture.xml", "application/xml; charset=utf-8").success?.should be_true
    store("date;montant\n2026-01-01;12.50\n", "releve.csv", "text/csv").success?.should be_true
  end

  it "accepte un document ODT dont l'entrée mimetype vient en premier, non compressée" do
    content = odt
    view = store(content, "facture.odt", ODT_TYPE).value!
    view.content_type.should eq(ODT_TYPE)
    Partiduo::Core::Attachment.get!(id: view.id).storage_name!.should end_with(".odt")
    Api.attachment_content(writer, view.id).should eq(content.to_slice)
  end

  it "refuse un faux ODT : autre type, mimetype absent, déplacé ou compressé, archive tronquée" do
    mismatch = ["core.errors.attachment.content_type.mismatch"]
    store(odt("application/vnd.oasis.opendocument.spreadsheet"), "a.odt", ODT_TYPE).error_keys.should eq(mismatch)
    store(odt(first: false), "a.odt", ODT_TYPE).error_keys.should eq(mismatch)
    store(odt(stored: false), "a.odt", ODT_TYPE).error_keys.should eq(mismatch)
    store(docx, "a.odt", ODT_TYPE).error_keys.should eq(mismatch)
    store(odt[0, 40], "a.odt", ODT_TYPE).error_keys.should eq(mismatch)
    store("PK\x03\x04", "a.odt", ODT_TYPE).error_keys.should eq(mismatch)
    store(PDF, "a.odt", ODT_TYPE).error_keys.should eq(mismatch)
  end

  it "accepte un document DOCX qui contient [Content_Types].xml et word/document.xml" do
    view = store(docx, "facture.docx", DOCX_TYPE).value!
    view.content_type.should eq(DOCX_TYPE)
    Partiduo::Core::Attachment.get!(id: view.id).storage_name!.should end_with(".docx")
  end

  it "refuse un faux DOCX : partie manquante, archive tronquée ou autre contenu" do
    mismatch = ["core.errors.attachment.content_type.mismatch"]
    store(docx(["[Content_Types].xml", "xl/workbook.xml"]), "a.docx", DOCX_TYPE).error_keys.should eq(mismatch)
    store(docx(["word/document.xml"]), "a.docx", DOCX_TYPE).error_keys.should eq(mismatch)
    store(docx[0, docx.bytesize - 10], "a.docx", DOCX_TYPE).error_keys.should eq(mismatch)
    store("PK\x03\x04" + "x" * 100, "a.docx", DOCX_TYPE).error_keys.should eq(mismatch)
    store(PDF, "a.docx", DOCX_TYPE).error_keys.should eq(mismatch)
  end

  it "applique aux documents ODT et DOCX la limite de taille commune" do
    big = odt + "x" * Partiduo::Core::Attachments::MAX_BYTES
    store(big, "gros.odt", ODT_TYPE).error_keys.should eq(["core.errors.attachment.content.too_large"])
  end

  it "refuse un fichier trop volumineux" do
    big = "%PDF-" + "x" * Partiduo::Core::Attachments::MAX_BYTES
    store(big).error_keys.should eq(["core.errors.attachment.content.too_large"])
  end

  it "détecte un fichier altéré dans le stockage" do
    view = store.value!
    name = Partiduo::Core::Attachment.get!(id: view.id).storage_name!
    Marten.media_files_storage.write(name, IO::Memory.new("%PDF-altéré"))
    expect_raises(Partiduo::Api::AttachmentCorrupted) { Api.attachment_content(writer, view.id) }
  end

  it "supprime une pièce libre et son fichier, pas une pièce citée" do
    view = store.value!
    name = Partiduo::Core::Attachment.get!(id: view.id).storage_name!
    Api.delete_attachment(writer, view.id).success?.should be_true
    Marten.media_files_storage.exists?(name).should be_false

    cited = store.value!
    Marten::DB::Connection.default.open do |db|
      db.exec("CREATE TABLE spec_attachment_ref (id bigserial PRIMARY KEY, attachment_id bigint REFERENCES core_attachment (id))")
    end
    begin
      Marten::DB::Connection.default.open { |db| db.exec("INSERT INTO spec_attachment_ref (attachment_id) VALUES ($1)", cited.id) }
      Api.delete_attachment(writer, cited.id).error_keys.should eq(["core.errors.attachment.in_use"])
      Api.attachment_content(writer, cited.id).size.should eq(PDF.bytesize)
    ensure
      Marten::DB::Connection.default.open(&.exec("DROP TABLE spec_attachment_ref"))
    end
  end

  it "exige les permissions de lecture et d'écriture" do
    expect_raises(Partiduo::Api::Forbidden) do
      Api.store_attachment(actor_with("core.attachment.read"),
        Api::AttachmentInput.new("a.pdf", "application/pdf", IO::Memory.new(PDF)))
    end
    view = store.value!
    expect_raises(Partiduo::Api::Forbidden) { Api.attachment(actor_with, view.id) }
  end
end
