# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"
require "file_utils"

private APP_ROOT = File.expand_path("../..", __DIR__)

private def sh(command : String, *args : String) : {Int32, String, String}
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  env = {"PARTIDUO_DOMAIN" => nil, "PARTIDUO_MANAGE" => nil, "PARTIDUO_FLEET_CONFIG" => nil} of String => String?
  status = Process.run(File.join(APP_ROOT, command), args.to_a, env: env, output: stdout, error: stderr, chdir: APP_ROOT)
  {status.exit_code, stdout.to_s, stderr.to_s}
end

private def with_tmpdir(&)
  dir = File.join(Dir.tempdir, "partiduo-spec-#{Random::Secure.hex(6)}")
  Dir.mkdir_p(dir)
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end

describe "bin/partiduo-provision" do
  it "déroule les étapes de l'ADR-001 D2 en simulation" do
    code, output, _ = sh("bin/partiduo-provision", "--dry-run", "--name", "Exemple SARL", "--regime=fr",
      "--modules", "accounting", "--with", "skel", "--owner", "partiduo", "--domain", "compta.example", "exemple-sarl")

    code.should eq(0)
    output.should contain("+ env PGHOST=/tmp createdb --owner=partiduo --encoding=UTF8 partiduo_exemple_sarl")
    output.should contain("manage.cr -- migrate")
    output.should contain("-- provision --domain=exemple-sarl.compta.example --modules=accounting --with=skel " \
                          "'--name=Exemple SARL' --regime=fr")
    output.should contain("modules accounting,skel")
    output.should contain("+ gabarit nginx-vhost.conf.tmpl")
    output.should contain("+ gabarit partiduo-instance.service.tmpl")
  end

  it "génère environnement, vhost et unité systemd sans rien installer" do
    with_tmpdir do |dir|
      code, output, errors = sh("bin/partiduo-provision", "--skip-createdb", "--manage", "true",
        "--name=Exemple", "--regime=be", "--output-dir", dir, "--port", "8200", "dupont")
      errors.should eq("")
      code.should eq(0)
      output.should contain("Instance dupont provisionnée")

      env = File.read(File.join(dir, "dupont", "dupont.env"))
      env.should contain("DATABASE_URL=postgres:///partiduo_dupont?host=/tmp\n")
      env.should contain("PARTIDUO_MODULES=accounting,invoicing\n")
      env.should contain("MARTEN_ALLOWED_HOSTS=dupont.partiduo.localhost\n")
      env.should match(/^MARTEN_SECRET_KEY=[0-9a-f]{64}$/m)
      (File.info(File.join(dir, "dupont", "dupont.env")).permissions.value & 0o077).should eq(0)

      vhost = File.read(File.join(dir, "dupont", "dupont.nginx.conf"))
      vhost.should contain("server_name dupont.partiduo.localhost;")
      vhost.should contain("proxy_pass         http://127.0.0.1:8200;")
      unit = File.read(File.join(dir, "dupont", "partiduo-dupont.service"))
      unit.should contain("EnvironmentFile=/etc/partiduo/dupont.env")
      unit.should contain("ExecStart=/opt/partiduo/instances/dupont/release/bin/partiduo-server")
      [env, vhost, unit].each(&.should_not(contain("{{")))
      File.read(File.join(dir, "dupont", "INSTALL.txt")).should contain("systemctl enable --now partiduo-dupont.service")

      # Le port suivant est libre.
      _, second, _ = sh("bin/partiduo-provision", "--dry-run", "--name=X", "--regime=fr", "--output-dir", dir, "martin")
      second.should contain("port 8201")
    end
  end

  it "refuse un nom de dossier, un module ou une option invalides" do
    sh("bin/partiduo-provision", "--dry-run", "Dossier").first.should eq(1)
    sh("bin/partiduo-provision", "--dry-run", "dossier-").first.should eq(1)
    sh("bin/partiduo-provision", "--dry-run", "--modules", "compta;rm", "dossier").first.should eq(1)
    code, _, errors = sh("bin/partiduo-provision", "--inconnue", "dossier")
    code.should eq(1)
    errors.should contain("option inconnue : --inconnue")
  end
end

describe "deploy/bin/partiduo-fleet" do
  it "planifie une montée de version progressive sans rien exécuter" do
    with_tmpdir do |dir|
      File.write(File.join(dir, "inventory"), "# parc\nalpha deploy@srv1\nbeta deploy@srv1\ngamma deploy@srv2\n")
      File.write(File.join(dir, "fleet.conf"), "INVENTORY=inventory\nPARTIDUO_DOMAIN=compta.example\n")
      config = "--config=#{File.join(dir, "fleet.conf")}"

      code, output, _ = sh("deploy/bin/partiduo-fleet", config, "upgrade", "1.2.0", "--canary", "2")
      code.should eq(0)
      output.should contain("## alpha (deploy@srv1)")
      output.should contain("## beta (deploy@srv1)")
      output.should_not contain("gamma")
      output.should contain("pg_dump -Fc")
      output.should contain("/opt/partiduo/releases/1.2.0/bin/partiduo-manage migrate")
      output.should contain("plan (ajoutez --execute pour exécuter)")

      sh("deploy/bin/partiduo-fleet", config, "upgrade", "1.2.0").first.should eq(1)
      sh("deploy/bin/partiduo-fleet", config, "upgrade", "1.2.0", "--only", "alpha,inconnu").first.should eq(1)

      _, inventory, _ = sh("deploy/bin/partiduo-fleet", config, "inventory")
      inventory.lines.size.should eq(4)
      File.read(File.join(dir, "inventory")).should contain("gamma deploy@srv2")
    end
  end
end
