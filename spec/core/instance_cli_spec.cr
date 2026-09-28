# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"
require "file_utils"

# Interface en ligne de commande d'instance (ADR-008 D4) : contrat de
# `doc/api/instance-cli.adoc`, vérifié commande par commande.

private record CliRun, code : Int32, json : JSON::Any, output : String do
  def data : JSON::Any
    json["data"]
  end

  def error : JSON::Any
    json["error"]
  end
end

private def cli(*arguments : String) : CliRun
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  command = Partiduo::Core::Commands::Instance.new(arguments.to_a, stdout: stdout, stderr: stderr, exit_raises: true)
  code = command.handle
  output = stdout.to_s
  output.lines.size.should eq(1)
  stderr.to_s.should eq("")
  CliRun.new(code, JSON.parse(output), output)
end

private def audit_events(action : String) : Array(Partiduo::Auth::AuditEvent)
  Partiduo::Auth::AuditEvent.filter(action: action).order(:id).to_a
end

# La lecture seule est un réglage de la *base* : toujours levée en fin de spec.
private def with_read_only_cleanup(&)
  yield
ensure
  Partiduo::Core::InstanceAdmin.set_read_only(false)
end

private PDF = "%PDF-1.7\n1 0 obj << >> endobj\n%%EOF\n"

# Nom de la pièce dans le stockage.
private def store_pdf(filename : String) : String
  input = Partiduo::Api::Core::AttachmentInput.new(filename, "application/pdf", IO::Memory.new(PDF))
  view = Partiduo::Api::Core.store_attachment(Partiduo::Api::Actor.system, input).value!
  Partiduo::Core::Attachment.get!(id: view.id).storage_name!
end

describe "manage instance (ADR-008 D4, doc/api/instance-cli.adoc)" do
  it "rend la version du code, du contrat Partiduo::Api et de ce contrat, sans base" do
    run = cli("version")
    run.code.should eq(0)
    run.json["contract"].should eq(Partiduo::INSTANCE_CLI_VERSION)
    run.json["action"].should eq("version")
    run.json["ok"].should be_true
    run.data["version"].should eq(Partiduo::VERSION)
    run.data["api_version"].should eq(Partiduo::API_VERSION)
    run.data["pieces"].as_a.map(&.["code"].as_s).should contain("CORE")
  end

  it "rend l'état : provisionnement, lecture seule, migrations, pièces actives" do
    before = cli("status")
    before.code.should eq(0)
    before.data["provisioned"].should be_false
    before.data["database"].as_s.should contain("test")
    before.data["migrations"]["pending"].should eq(0)
    before.data["migrations"]["applied"].as_i.should be > 0
    before.data["read_only"]["active"].should be_false

    provision_instance
    after = cli("status").data
    after["provisioned"].should be_true
    after["tax_regime"].should eq("fr")
    modules = after["modules"].as_a.to_h { |piece| {piece["code"].as_s, piece} }
    modules["CORE"]["kind"].should eq("socle")
    modules["CORE"]["active"].should be_true
    Partiduo::Modules.manifests.each_key do |code|
      modules[code]["active"].should eq(Partiduo::Modules.active?(code))
    end
    # Aucune donnée comptable, ni même la raison sociale (ADR-008 D3).
    cli("status").output.should_not contain("Exemple SARL")
  end

  it "liste les migrations en attente et les applique" do
    run = cli("migrations", "--check")
    run.code.should eq(0)
    run.data["pending"].as_a.should be_empty
    migrate = cli("migrate")
    migrate.code.should eq(0)
    migrate.data["applied"].as_a.should be_empty
    migrate.data["pending"].should eq(0)
    audit_events("instance.migrate").should be_empty
  end

  it "rend les erreurs d'usage au format du contrat, code 2" do
    {
      ["frob"]                        => "usage.action_unknown",
      [] of String                    => "usage.action_missing",
      ["status", "extra"]             => "usage.argument_extra",
      ["enable"]                      => "usage.argument_missing",
      ["read-only", "sometimes"]      => "usage.read_only_mode",
      ["read-only", "on"]             => "usage.reason_missing",
      ["status", "--inconnue"]        => "usage.option",
      ["read-only", "on", "--reason"] => "usage.option",
    }.each do |arguments, reason|
      stdout = IO::Memory.new
      command = Partiduo::Core::Commands::Instance.new(arguments, stdout: stdout, stderr: IO::Memory.new, exit_raises: true)
      command.handle.should eq(2)
      json = JSON.parse(stdout.to_s)
      json["ok"].should be_false
      json["error"]["code"].should eq("usage")
      json["error"]["reason"].should eq(reason)
      json["error"]["message"].as_s.should_not be_empty
    end
  end

  it "traduit les messages (--locale), les codes restant stables" do
    run = cli("frob", "--locale", "en")
    run.error["message"].as_s.should start_with("Unknown action: frob")
    cli("frob", "--locale", "nl").error["message"].as_s.should start_with("Onbekende actie")
  end

  it "active et désactive une pièce, trace l'action ; la désactivation garde les données" do
    with_active_modules("invoicing") do
      provision_instance
      run = cli("enable", "followup", "--task", "T-42", "--requested-by", "gestionnaire@cabinet.example")
      run.code.should eq(0)
      run.data["code"].should eq("FOLLOWUP")
      run.data["kind"].should eq("module")
      run.data["active"].should be_true
      Partiduo::Modules.active?("FOLLOWUP").should be_true

      event = audit_events("instance.module.enable").last
      event.user_label.should eq("partiduo-admin")
      event.state.should eq("ADMIN")
      JSON.parse(event.detail.to_s).should eq(JSON.parse(%({"reason":"FOLLOWUP","task":"T-42","requested_by":"gestionnaire@cabinet.example"})))

      off = cli("disable", "FOLLOWUP")
      off.code.should eq(0)
      off.data["active"].should be_false
      off.data["data"].should eq("kept")
      Partiduo::Modules.active?("FOLLOWUP").should be_false
    end
  end

  it "refuse une pièce inconnue (3), du socle ou une dépendance manquante (4)" do
    with_active_modules("invoicing") do
      unknown = cli("enable", "inconnue")
      unknown.code.should eq(3)
      unknown.error["code"].should eq("not_found")

      socle = cli("disable", "core")
      socle.code.should eq(4)
      socle.error["code"].should eq("refused")
      socle.error["reason"].should eq("modules.errors.activation.socle")

      missing = cli("enable", "analytic")
      missing.code.should eq(4)
      missing.error["reason"].should eq("modules.errors.activation.missing_dependency")
      missing.error["details"].as_a.first["key"].should eq("modules.errors.activation.missing_dependency")
      Partiduo::Modules.active?("ANALYTIC").should be_false
    end
  end

  it "met l'instance en lecture seule, refuse alors les gestes (5), puis lève l'état" do
    with_read_only_cleanup do
      provision_instance
      on = cli("read-only", "on", "--reason", "archivage", "--task", "T-7")
      on.code.should eq(0)
      on.data["read_only"]["active"].should be_true
      on.data["read_only"]["reason"].should eq("archivage")
      on.data["read_only"]["since"].as_s.should_not be_empty
      on.data["restart_required"].should be_true
      Partiduo::Core::InstanceAdmin.read_only?.should be_true

      # Une session neuve (le serveur de l'instance) ne peut plus écrire.
      DB.open(Partiduo::Config.database_url) do |db|
        expect_raises(PQ::PQError, /read-only transaction/) do
          db.exec("UPDATE modules_activation SET active = active")
        end
      end

      cli("status").data["read_only"]["reason"].should eq("archivage")
      cli("read-only", "status").data["read_only"]["active"].should be_true
      refused = cli("enable", "followup")
      refused.code.should eq(5)
      refused.error["code"].should eq("read_only")
      cli("admin-invite", "x@exemple.test", "--reason", "r", "--approval-ref", "V-1", "--approvers", "a,b").code.should eq(5)
      # Idempotent : une seule trace.
      cli("read-only", "on", "--reason", "encore").code.should eq(0)
      audit_events("instance.read_only.on").size.should eq(1)

      off = cli("read-only", "off", "--reason", "restauration")
      off.code.should eq(0)
      off.data["read_only"]["active"].should be_false
      Partiduo::Core::InstanceAdmin.read_only?.should be_false
      audit_events("instance.read_only.off").size.should eq(1)
    end
  end

  it "réémet l'invitation d'administrateur avec motif et double validation, tracée" do
    provision_instance(admin_email: "patron@exemple.test")
    arguments = {"--reason", "passkey perdue", "--approval-ref", "VAL-2026-001", "--approvers",
                 "admin@cabinet.example,super@aloli.example", "--task", "T-9"}

    run = cli("admin-invite", "patron@exemple.test", *arguments)
    run.code.should eq(0)
    run.data["email"].should eq("patron@exemple.test")
    run.data["user_created"].should be_false
    token = run.data["token"].as_s
    run.data["url"].as_s.should end_with("/invitation/#{token}")
    run.data["expires_at"].as_s.should match(/\A\d{4}-\d\d-\d\dT/)
    run.data["usable_admins"].should eq(0)

    event = audit_events("instance.admin_invitation").last
    event.user_label.should eq("partiduo-admin")
    detail = JSON.parse(event.detail.to_s)
    detail["reason"].should eq("passkey perdue")
    detail["approval_ref"].should eq("VAL-2026-001")
    detail["approvers"].should eq("admin@cabinet.example,super@aloli.example")
    detail["task"].should eq("T-9")
    audit_events("user.invite").size.should eq(1)

    # Adresse inconnue : la plateforme ne crée pas d'administrateur (D-AFN-003).
    unknown = cli("admin-invite", "nouvelle@exemple.test", *arguments)
    unknown.code.should eq(4)
    unknown.error["reason"].should eq("instance.admin_invitation.unknown")
    Partiduo::Api::Auth.user_by_email(Partiduo::Api::Actor.system, "nouvelle@exemple.test").should be_nil
    audit_events("instance.admin_invitation").size.should eq(1)
  end

  it "exige deux validateurs distincts et une référence, et refuse de donner des droits" do
    provision_instance
    single = cli("admin-invite", "a@exemple.test", "--reason", "r", "--approval-ref", "V", "--approvers", "a@x,A@X")
    single.code.should eq(2)
    single.error["reason"].should eq("usage.approvers")
    cli("admin-invite", "a@exemple.test", "--reason", "r", "--approvers", "a,b").error["reason"]
      .should eq("usage.approval_missing")

    actor = Partiduo::Api::Actor.system
    Partiduo::Api::Auth.create_user(actor, Partiduo::Api::Auth::UserInput.new(email: "membre@exemple.test")).value!
    member = cli("admin-invite", "membre@exemple.test", "--reason", "r", "--approval-ref", "V", "--approvers", "a,b")
    member.code.should eq(4)
    member.error["reason"].should eq("instance.admin_invitation.not_admin")

    admin = Partiduo::Api::Auth.ensure_default_profiles(actor).find!(&.code.==("ADMIN"))
    Partiduo::Api::Auth.create_user(actor, Partiduo::Api::Auth::UserInput.new(email: "revoque@exemple.test",
      profile_id: admin.id)).value!
    revoked = Partiduo::Auth::User.get!(email: "revoque@exemple.test")
    revoked.revoked_at = Time.utc
    revoked.save!
    again = cli("admin-invite", "revoque@exemple.test", "--reason", "r", "--approval-ref", "V", "--approvers", "a,b")
    again.code.should eq(4)
    again.error["reason"].should eq("instance.admin_invitation.revoked")
    audit_events("instance.admin_invitation").should be_empty
  end

  it "refuse la réémission sur une instance non provisionnée" do
    run = cli("admin-invite", "a@exemple.test", "--reason", "r", "--approval-ref", "V", "--approvers", "a,b")
    run.code.should eq(4)
    run.error["reason"].should eq("instance.not_provisioned")
  end

  it "prépare la sauvegarde : pièces jointes à inclure, manquantes, altérées" do
    kept = store_pdf("facture-client-durand.pdf")
    lost = store_pdf("releve.pdf")
    altered = store_pdf("contrat.pdf")
    root = Partiduo::Core::InstanceAdmin.media_root
    File.delete(File.join(root, lost))
    File.write(File.join(root, altered), "%PDF-1.7 modifié")
    list = File.join(Dir.tempdir, "partiduo-backup-#{Random::Secure.hex(4)}.txt")

    begin
      run = cli("backup-plan", "--verify", "--list-file", list)
      run.code.should eq(0)
      data = run.data
      data["media_root"].should eq(root)
      data["verified"].should be_true
      data["read_only"].should be_false
      states = data["files"].as_a.to_h { |file| {file["path"].as_s, file["state"].as_s} }
      states.should eq({kept => "present", lost => "missing", altered => "corrupted"})
      data["file_count"].should eq(1)
      data["total_bytes"].should eq(PDF.bytesize)
      data["missing"].as_a.map(&.as_s).sort!.should eq([lost, altered].sort)
      File.read(list).should eq("#{kept}\n")
      # Le nom déposé, qui peut révéler le contenu, n'est pas rendu (ADR-008 D3).
      run.output.should_not contain("durand")

      cli("backup-plan").data["files"].as_a.count(&.["state"].==("present")).should eq(2)
    ensure
      File.delete(list) if File.exists?(list)
    end
  end
end
