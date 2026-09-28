# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Interface en ligne de commande d'instance (ADR-008 D4) : règles et cas
# limites du contrat `doc/api/instance-cli.adoc` qui complètent
# `instance_cli_spec.cr` — données conservées d'une pièce désactivée
# (ADR-006 D2, `ModuleDisabled`), dépendances, lecture seule posée sur la
# base, recours d'accès sans droits nouveaux (D-CLI-005), préparation de
# sauvegarde sans chemin hors du stockage (D-CLI-006).

private record RuleRun, code : Int32, json : JSON::Any, output : String do
  def data : JSON::Any
    json["data"]
  end

  def error : JSON::Any
    json["error"]
  end
end

private def run_cli(*arguments : String) : RuleRun
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  command = Partiduo::Core::Commands::Instance.new(arguments.to_a, stdout: stdout, stderr: stderr, exit_raises: true)
  code = command.handle
  output = stdout.to_s
  # Contrat : une seule ligne JSON, rien sur la sortie d'erreur.
  output.lines.size.should eq(1)
  stderr.to_s.should eq("")
  json = JSON.parse(output)
  json["contract"].should eq(Partiduo::INSTANCE_CLI_VERSION)
  json["ok"].as_bool.should eq(code == 0)
  unless code == 0
    %w[code reason message details].each { |key| json["error"].as_h.has_key?(key).should be_true }
    json["error"]["details"].as_a?.should_not be_nil
  end
  RuleRun.new(code, json, output)
end

private def events(action : String) : Array(Partiduo::Auth::AuditEvent)
  Partiduo::Auth::AuditEvent.filter(action: action).order(:id).to_a
end

private def invite_options(reason = "passkey perdue", reference = "DV-TEST-0001", approvers = "a@cabinet.example,b@cabinet.example")
  {"--reason", reason, "--approval-ref", reference, "--approvers", approvers}
end

# La lecture seule est un réglage de la base : toujours levée en fin de spec.
private def read_only_guard(&)
  yield
ensure
  Partiduo::Core::InstanceAdmin.set_read_only(false)
end

private CLI_PDF = "%PDF-1.7\n1 0 obj << >> endobj\n%%EOF\n"

private def stored_pdf(filename : String) : Partiduo::Core::Attachment
  input = Partiduo::Api::Core::AttachmentInput.new(filename, "application/pdf", IO::Memory.new(CLI_PDF))
  view = Partiduo::Api::Core.store_attachment(Partiduo::Api::Actor.system, input).value!
  Partiduo::Core::Attachment.get!(id: view.id)
end

describe "manage instance : pièces activables (ADR-006 D2)" do
  it "désactive un module : ses requêtes lèvent ModuleDisabled, ses données restent, la réactivation rend tout" do
    with_active_modules("accounting,invoicing") do
      AccountingSpec.load("fr")
      accounts = Partiduo::Api::Accounting.chart(Partiduo::Api::Actor.system).size
      accounts.should be > 0

      off = run_cli("disable", "accounting", "--task", "T-1")
      off.code.should eq(0)
      off.data["code"].should eq("ACCOUNTING")
      off.data["active"].should be_false
      off.data["data"].should eq("kept")
      expect_raises(Partiduo::Api::ModuleDisabled) { Partiduo::Api::Accounting.chart(Partiduo::Api::Actor.system) }
      # Les lignes sont toujours en base.
      Partiduo::Accounting::Account.all.count.should eq(accounts)
      run_cli("status").data["modules"].as_a.find!(&.["code"].==("ACCOUNTING"))["active"].should be_false

      on = run_cli("enable", "ACCOUNTING", "--task", "T-2")
      on.code.should eq(0)
      Partiduo::Api::Accounting.chart(Partiduo::Api::Actor.system).size.should eq(accounts)
      events("instance.module.disable").size.should eq(1)
      events("instance.module.enable").size.should eq(1)
    end
  end

  it "refuse de désactiver une pièce requise par une pièce active (4), sans rien tracer" do
    with_active_modules("accounting,invoicing,analytic") do
      Partiduo::Modules.active?("ANALYTIC").should be_true
      refused = run_cli("disable", "accounting")
      refused.code.should eq(4)
      refused.error["code"].should eq("refused")
      refused.error["reason"].should eq("modules.errors.activation.required_by")
      refused.error["details"].as_a.first["field"].should eq("code")
      refused.error["message"].as_s.should_not be_empty
      Partiduo::Modules.active?("ACCOUNTING").should be_true
      events("instance.module.disable").should be_empty

      # Dans l'ordre inverse des dépendances, le retrait passe.
      run_cli("disable", "analytic").code.should eq(0)
      run_cli("disable", "accounting").code.should eq(0)
      Partiduo::Modules.active?("ACCOUNTING").should be_false
    end
  end

  it "rend un succès sans changement pour une pièce déjà dans l'état demandé" do
    with_active_modules("accounting,invoicing") do
      again = run_cli("enable", "invoicing")
      again.code.should eq(0)
      again.data["active"].should be_true
      idle = run_cli("disable", "followup")
      idle.code.should eq(0)
      idle.data["active"].should be_false
      Partiduo::Modules.active?("INVOICING").should be_true
    end
  end
end

describe "manage instance : lecture seule (D-CLI-003)" do
  it "rend l'état levé sans date ni motif, et « off » sur une base inscriptible ne trace rien" do
    status = run_cli("read-only", "status")
    status.code.should eq(0)
    status.data["read_only"]["active"].should be_false
    status.data["read_only"]["since"].raw.should be_nil
    status.data["read_only"]["reason"].raw.should be_nil

    off = run_cli("read-only", "off")
    off.code.should eq(0)
    off.data["read_only"]["active"].should be_false
    events("instance.read_only.off").should be_empty
  end

  it "refuse un motif fait d'espaces" do
    run = run_cli("read-only", "on", "--reason", "   ")
    run.code.should eq(2)
    run.error["reason"].should eq("usage.reason_missing")
    Partiduo::Core::InstanceAdmin.read_only?.should be_false
  end

  it "laisse lire, migrer et préparer la sauvegarde d'une instance en lecture seule" do
    read_only_guard do
      provision_instance
      run_cli("read-only", "on", "--reason", "archivage").code.should eq(0)
      status = run_cli("status")
      status.code.should eq(0)
      status.data["read_only"]["active"].should be_true
      run_cli("migrations", "--check").code.should eq(0)
      run_cli("migrate").code.should eq(0)
      plan = run_cli("backup-plan")
      plan.code.should eq(0)
      plan.data["read_only"].should be_true
      disable = run_cli("disable", "followup")
      disable.code.should eq(5)
      disable.error["reason"].should eq("instance.read_only")
    end
  end

  it "coupe les sessions ouvertes avec --terminate-sessions" do
    read_only_guard do
      DB.open(Partiduo::Config.database_url) do |other|
        other.using_connection do |connection|
          connection.scalar("SELECT 1").should eq(1)
          run = run_cli("read-only", "on", "--reason", "archivage", "--terminate-sessions")
          run.code.should eq(0)
          run.data["sessions_terminated"].as_i.should be >= 1
          run.data["restart_required"].should be_false
          expect_raises(Exception) { connection.scalar("SELECT 1") }
        end
      end
      # Le processus de la commande garde la main : il lève la lecture seule.
      off = run_cli("read-only", "off", "--reason", "fin d'essai")
      off.code.should eq(0)
      Partiduo::Core::InstanceAdmin.read_only?.should be_false
    end
  end
end

describe "manage instance : recours d'accès (D-CLI-005)" do
  it "retrouve l'administrateur existant quelle que soit la casse de l'adresse" do
    provision_instance(admin_email: "patron@exemple.test")
    run = run_cli("admin-invite", "  Patron@Exemple.TEST ", *invite_options)
    run.code.should eq(0)
    run.data["user_created"].should be_false
    run.data["email"].should eq("patron@exemple.test")
    Partiduo::Auth::User.filter(email: "patron@exemple.test").count.should eq(1)
  end

  it "compte les administrateurs encore utilisables avant la réémission" do
    provision_instance
    admin = Partiduo::Api::Auth.ensure_default_profiles(Partiduo::Api::Actor.system).find!(&.code.==("ADMIN"))
    Partiduo::Api::Auth.create_user(Partiduo::Api::Actor.system, Partiduo::Api::Auth::UserInput.new(
      email: "actif@exemple.test", profile_id: admin.id, password: AuthSpec::PASSWORD)).value!
    run = run_cli("admin-invite", "actif@exemple.test", *invite_options)
    run.code.should eq(0)
    run.data["usable_admins"].should eq(1)
  end

  it "refuse une adresse inconnue ou invalide (4) sans créer de compte ni de trace (D-AFN-003)" do
    provision_instance
    users = Partiduo::Auth::User.all.count
    %w[pas-une-adresse inconnue@exemple.test].each do |address|
      run = run_cli("admin-invite", address, *invite_options)
      run.code.should eq(4)
      run.error["code"].should eq("refused")
      run.error["reason"].should eq("instance.admin_invitation.unknown")
    end
    Partiduo::Auth::User.all.count.should eq(users)
    events("instance.admin_invitation").should be_empty
  end

  it "bâtit le lien sur l'hôte de l'instance, jamais sur le domaine du parc" do
    provision_instance(admin_email: "patron@exemple.test")
    # Société sans domaine (instance ancienne ou réglage effacé).
    Partiduo::Core::Settings.all.update(domain: "")
    previous = ENV["PARTIDUO_HOST"]?
    begin
      ENV.delete("PARTIDUO_HOST")
      allowed = ENV["MARTEN_ALLOWED_HOSTS"]?
      begin
        ENV.delete("MARTEN_ALLOWED_HOSTS")
        refused = run_cli("admin-invite", "patron@exemple.test", *invite_options)
        refused.code.should eq(4)
        refused.error["reason"].should eq("instance.host_unknown")
        events("instance.admin_invitation").should be_empty
      ensure
        allowed ? (ENV["MARTEN_ALLOWED_HOSTS"] = allowed) : ENV.delete("MARTEN_ALLOWED_HOSTS")
      end
      ENV["PARTIDUO_HOST"] = "patron.partiduo.example"
      run = run_cli("admin-invite", "patron@exemple.test", *invite_options)
      run.code.should eq(0)
      run.data["url"].as_s.should start_with("https://patron.partiduo.example/invitation/")
    ensure
      previous ? (ENV["PARTIDUO_HOST"] = previous) : ENV.delete("PARTIDUO_HOST")
    end
  end

  it "refuse motif ou référence faits d'espaces, et un même validateur écrit deux fois" do
    provision_instance
    run_cli("admin-invite", "a@exemple.test", *invite_options(reason: "  ")).error["reason"].should eq("usage.reason_missing")
    run_cli("admin-invite", "a@exemple.test", *invite_options(reference: " ")).error["reason"].should eq("usage.approval_missing")
    run_cli("admin-invite", "a@exemple.test", *invite_options(approvers: "a@x.fr, ,A@X.FR ,")).error["reason"]
      .should eq("usage.approvers")
    run_cli("admin-invite", "a@exemple.test", "--reason", "r", "--approval-ref", "V").error["reason"]
      .should eq("usage.approvers")
    Partiduo::Auth::User.filter(email: "a@exemple.test").exists?.should be_false
  end

  it "réémet l'invitation d'un administrateur existant sans toucher à son profil" do
    provision_instance(admin_email: "patron@exemple.test")
    user = Partiduo::Auth::User.get!(email: "patron@exemple.test")
    profile = user.profile_id
    run = run_cli("admin-invite", "patron@exemple.test", *invite_options)
    run.code.should eq(0)
    Partiduo::Auth::User.get!(email: "patron@exemple.test").profile_id.should eq(profile)
  end
end

describe "manage instance : préparation de sauvegarde (D-CLI-006)" do
  it "rend un plan vide et une liste vide sur une instance sans pièce" do
    list = File.join(Dir.tempdir, "partiduo-backup-vide-#{Random::Secure.hex(4)}.txt")
    begin
      run = run_cli("backup-plan", "--list-file", list)
      run.code.should eq(0)
      run.data["file_count"].should eq(0)
      run.data["total_bytes"].should eq(0)
      run.data["files"].as_a.should be_empty
      run.data["missing"].as_a.should be_empty
      run.data["list_file"].should eq(File.expand_path(list))
      File.read(list).should eq("")
    ensure
      File.delete(list) if File.exists?(list)
    end
  end

  it "écarte un nom de stockage qui sortirait de la racine des pièces" do
    attachment = stored_pdf("piece.pdf")
    Partiduo::Core::Attachment.filter(id: attachment.id).update(storage_name: "../../etc/passwd")
    run = run_cli("backup-plan")
    run.data["files"].as_a.first["state"].should eq("missing")
    run.data["file_count"].should eq(0)
    run.data["missing"].as_a.map(&.as_s).should eq(["../../etc/passwd"])
  end

  it "ne signale une pièce altérée qu'avec --verify" do
    attachment = stored_pdf("contrat.pdf")
    File.write(File.join(Partiduo::Core::InstanceAdmin.media_root, attachment.storage_name!), "%PDF altéré")
    run_cli("backup-plan").data["files"].as_a.first["state"].should eq("present")
    run_cli("backup-plan", "--verify").data["files"].as_a.first["state"].should eq("corrupted")
  end
end

describe "manage instance : forme des réponses" do
  it "rend action vide quand l'analyse échoue avant l'action, et retombe sur le français pour une langue inconnue" do
    parse = run_cli("--reason")
    parse.code.should eq(2)
    parse.json["action"].should eq("")
    parse.error["reason"].should eq("usage.option")

    english = run_cli("--locale", "en", "--reason")
    english.error["reason"].should eq("usage.option")
    english.error["message"].should eq("Unrecognized option or missing value: --reason.")

    unknown = run_cli("frob", "--locale", "de")
    unknown.error["message"].as_s.should start_with("Action inconnue : frob")
  end

  it "reporte le seul demandeur au journal quand la tâche n'est pas donnée" do
    with_active_modules("invoicing") do
      run_cli("enable", "followup", "--requested-by", "gestionnaire@cabinet.example").code.should eq(0)
      detail = JSON.parse(events("instance.module.enable").last.detail.to_s)
      detail["requested_by"].should eq("gestionnaire@cabinet.example")
      detail.as_h.has_key?("task").should be_false
    end
  end
end
