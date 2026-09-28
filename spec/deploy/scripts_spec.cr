# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"
require "file_utils"

private APP_ROOT = File.expand_path("../..", __DIR__)

private def sh(command : String, *args : String) : {Int32, String, String}
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  env = {"PARTIDUO_DOMAIN" => nil, "PARTIDUO_MANAGE" => nil, "PARTIDUO_FLEET_CONFIG" => nil,
         "PARTIDUO_ACME_EMAIL" => nil} of String => String?
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

      # Un certificat Let's Encrypt par instance (ADR-001 D2), obtenu en HTTP-01.
      vhost.should contain("ssl_certificate     /etc/letsencrypt/live/dupont.partiduo.localhost/fullchain.pem;")
      vhost.should contain("location ^~ /.well-known/acme-challenge/ {\n    root /var/www/letsencrypt;")
      acme = File.read(File.join(dir, "dupont", "dupont.acme.nginx.conf"))
      acme.should contain("server_name dupont.partiduo.localhost;")
      acme.should_not contain("ssl_certificate")
      acme.should_not contain("{{")
      install = File.read(File.join(dir, "dupont", "INSTALL.txt"))
      install.should start_with("# Installation")
      install.should contain("\nset -eu\n")
      install.should contain("certbot certonly --webroot -w /var/www/letsencrypt -d dupont.partiduo.localhost " \
                             "--cert-name dupont.partiduo.localhost --keep-until-expiring")
      install.should contain("--register-unsafely-without-email")
      install.should_not contain("--test-cert")
      # Vhost d'amorçage avant certbot, vhost définitif après.
      install.index!("dupont.acme.nginx.conf").should be < install.index!("certbot certonly")
      install.index!("certbot certonly").should be < install.index!("install -m 644 dupont.nginx.conf")

      # Le port suivant est libre.
      _, second, _ = sh("bin/partiduo-provision", "--dry-run", "--name=X", "--regime=fr", "--output-dir", dir, "martin")
      second.should contain("port 8201")
    end
  end

  it "prend le compte ACME et l'autorité de test de Let's Encrypt" do
    with_tmpdir do |dir|
      code, output, _ = sh("bin/partiduo-provision", "--skip-createdb", "--manage", "true", "--name=X", "--regime=fr",
        "--output-dir", dir, "--acme-email", "ops@aloli.example", "--acme-staging", "--acme-webroot", "/srv/acme", "durand")
      code.should eq(0)
      output.should contain("certificat Let's Encrypt pour durand.partiduo.localhost (autorité de test)")
      install = File.read(File.join(dir, "durand", "INSTALL.txt"))
      install.should contain("--email ops@aloli.example --test-cert")
      install.should contain("-w /srv/acme")
      File.read(File.join(dir, "durand", "durand.nginx.conf")).should contain("root /srv/acme;")
    end
    sh("bin/partiduo-provision", "--dry-run", "--acme-email", "pas une adresse", "dossier").first.should eq(1)
    sh("bin/partiduo-provision", "--dry-run", "--acme-webroot", "relatif", "dossier").first.should eq(1)
  end

  it "ne produit que les fichiers de service d'une base déjà remplie (--files-only, D-AFN-009)" do
    with_tmpdir do |dir|
      Dir.mkdir_p(File.join(dir, "source"))
      File.write(File.join(dir, "source", "source.env"), "PORT=8150\n")
      code, output, errors = sh("bin/partiduo-provision", "--files-only", "--manage", "false",
        "--database", "partiduo_copie", "--output-dir", dir, "copie")
      errors.should eq("")
      code.should eq(0)
      output.should_not contain("+ env PGHOST")
      output.should_not contain(" migrate")
      output.should_not contain(" provision --domain")
      env = File.read(File.join(dir, "copie", "copie.env"))
      env.should contain("DATABASE_URL=postgres:///partiduo_copie?host=/tmp\n")
      env.should contain("PORT=8151\n")
      env.should match(/^MARTEN_SECRET_KEY=[0-9a-f]{64}$/m)
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

      # Sauvegarde : base et pièces jointes listées par l'instance (backup-plan).
      _, backup, _ = sh("deploy/bin/partiduo-fleet", config, "backup", "alpha")
      backup.should contain("pg_dump -Fc")
      # Liste relevée avant et après pg_dump, archive de l'union (D-AFN-012).
      before = backup.index!("$m instance backup-plan --list-file $f.files.before")
      dump = backup.index!("pg_dump -Fc")
      after = backup.index!("$m instance backup-plan --list-file $f.files.after >$f.plan.json")
      before.should be < dump
      dump.should be < after
      backup.should contain("sort -u $f.files.before $f.files.after >$f.files")
      backup.should contain("tar -C \"$PARTIDUO_MEDIA_ROOT\" --ignore-failed-read -czf $f.media.tar.gz -T $f.files")

      # Restauration : base, puis pièces jointes de la même sauvegarde.
      _, restore, _ = sh("deploy/bin/partiduo-fleet", config, "restore", "alpha", "/var/backups/partiduo/alpha/x.dump")
      restore.index!("pg_restore").should be < restore.index!("tar -C \"$PARTIDUO_MEDIA_ROOT\" -xzf \"$a\"")
      restore.should contain("a=${f%.dump}.media.tar.gz")

      # Montée de version : service arrêté avant la sauvegarde préalable (D-AFN-007).
      _, upgrade, _ = sh("deploy/bin/partiduo-fleet", config, "upgrade", "1.2.0", "--only", "alpha")
      upgrade.index!("systemctl stop partiduo-alpha.service").should be < upgrade.index!("pg_dump -Fc")

      _, inventory, _ = sh("deploy/bin/partiduo-fleet", config, "inventory")
      inventory.lines.size.should eq(4)
      File.read(File.join(dir, "inventory")).should contain("gamma deploy@srv2")
    end
  end
end
