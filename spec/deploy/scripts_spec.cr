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
    output.should contain("+ gabarit partiduo-instance.cron.tmpl")
    output.should contain("paquet partiduo-app)")
  end

  it "génère environnement, vhost et tâche cron pour FreeBSD sans rien installer" do
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
      env.should contain("PARTIDUO_MEDIA_ROOT=/var/db/partiduo/dupont/media\n")
      env.should contain("PARTIDUO_MODELES_PDF=auto\n")
      # Gabarits et fichiers statiques : trouvés à côté des programmes du paquet.
      env.should_not contain("PARTIDUO_ASSETS_ROOT")
      (File.info(File.join(dir, "dupont", "dupont.env")).permissions.value & 0o077).should eq(0)

      vhost = File.read(File.join(dir, "dupont", "dupont.nginx.conf"))
      vhost.should contain("server_name dupont.partiduo.localhost;")
      vhost.should contain("proxy_pass         http://127.0.0.1:8200;")
      cron = File.read(File.join(dir, "dupont", "partiduo-dupont.cron"))
      cron.should contain("40 3 * * * partiduo set -a && . /usr/local/etc/partiduo/dupont.env && set +a " \
                          "&& cd /var/db/partiduo/dupont && /usr/local/lib/partiduo/bin/partiduo-manage invoicing_month_end")
      [env, vhost, cron].each(&.should_not(contain("{{")))
      File.exists?(File.join(dir, "dupont", "partiduo-dupont.service")).should be_false

      # Un certificat Let's Encrypt par instance (ADR-001 D2), obtenu en HTTP-01.
      vhost.should contain("ssl_certificate     /usr/local/etc/letsencrypt/live/dupont.partiduo.localhost/fullchain.pem;")
      vhost.should contain("location ^~ /.well-known/acme-challenge/ {\n    root /usr/local/www/letsencrypt;")
      acme = File.read(File.join(dir, "dupont", "dupont.acme.nginx.conf"))
      acme.should contain("server_name dupont.partiduo.localhost;")
      acme.should_not contain("ssl_certificate")
      acme.should_not contain("{{")
      install = File.read(File.join(dir, "dupont", "INSTALL.txt"))
      install.should start_with("# Installation")
      install.should contain("\nset -eu\n")
      install.should contain("certbot certonly --webroot -w /usr/local/www/letsencrypt -d dupont.partiduo.localhost " \
                             "--cert-name dupont.partiduo.localhost --keep-until-expiring")
      install.should contain("--deploy-hook 'service nginx reload'")
      # Service FreeBSD : une instance de plus pour le script rc.d du paquet.
      install.should contain("*) sysrc partiduo_instances+=\" dupont\" ;;")
      install.should contain("service partiduo start dupont")
      install.should contain("install -m 644 partiduo-dupont.cron /usr/local/etc/cron.d/partiduo-dupont")
      install.should contain("/usr/local/etc/nginx/partiduo/dupont.conf")
      install.should_not contain("systemctl")
      # Prérequis nginx vérifié avant toute modification.
      install.index!("include partiduo/*.conf").should be < install.index!("install -d -o root")
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

  it "sert l'instance par partiduo-app-devel (--version devel)" do
    with_tmpdir do |dir|
      code, output, _ = sh("bin/partiduo-provision", "--skip-createdb", "--manage", "true", "--name=X", "--regime=fr",
        "--output-dir", dir, "--port", "8230", "--version", "devel", "recette")
      code.should eq(0)
      output.should contain("paquet partiduo-app-devel)")
      install = File.read(File.join(dir, "recette", "INSTALL.txt"))
      install.should contain("sysrc partiduo_devel_instances+=\" recette\"")
      install.should contain("service partiduo_devel start recette")
      File.read(File.join(dir, "recette", "partiduo-recette.cron")).should contain("/usr/local/lib/partiduo-devel/bin/partiduo-manage")
    end
    sh("bin/partiduo-provision", "--dry-run", "--version", "beta", "dossier").first.should eq(1)
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
  it "planifie sauvegardes, restauration et retrait sans rien exécuter ; la mise à jour relève de beryl" do
    with_tmpdir do |dir|
      File.write(File.join(dir, "inventory"),
        "# parc\nalpha deploy@srv1\nbeta deploy@srv1 app\nrecette deploy@srv1 devel\ngamma deploy@srv2\n")
      File.write(File.join(dir, "fleet.conf"), "INVENTORY=inventory\nPARTIDUO_DOMAIN=compta.example\n")
      config = "--config=#{File.join(dir, "fleet.conf")}"

      # Paquets mis à jour par beryl ; le script rc.d migre au démarrage (D-PKG-003).
      code, _, errors = sh("deploy/bin/partiduo-fleet", config, "upgrade", "--all")
      code.should eq(1)
      errors.should contain("beryl")
      sh("deploy/bin/partiduo-fleet", config, "build", "1.2.0").first.should eq(1)

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
      # bsdtar : seules les pièces encore présentes sont archivées.
      backup.should contain("tar -C \"$PARTIDUO_MEDIA_ROOT\" -czf $f.media.tar.gz -T $f.files.present")
      backup.should_not contain("--ignore-failed-read")

      # Restauration : base, puis pièces jointes de la même sauvegarde.
      _, restore, _ = sh("deploy/bin/partiduo-fleet", config, "restore", "recette", "/var/backups/partiduo/recette/x.dump")
      restore.should contain("service partiduo_devel stop recette")
      restore.index!("pg_restore").should be < restore.index!("tar -C \"$PARTIDUO_MEDIA_ROOT\" -xzf \"$a\"")
      restore.should contain("a=${f%.dump}.media.tar.gz")

      _, retire, _ = sh("deploy/bin/partiduo-fleet", config, "retire", "gamma")
      retire.should contain("sysrc partiduo_instances-=gamma")
      retire.should contain("rm -f /usr/local/etc/nginx/partiduo/gamma.conf")

      _, inventory, _ = sh("deploy/bin/partiduo-fleet", config, "inventory")
      inventory.lines.size.should eq(5)
      inventory.should contain("recette")
      File.read(File.join(dir, "inventory")).should contain("gamma deploy@srv2")
    end
  end

  it "provisionne par le partiduo-provision du paquet choisi" do
    with_tmpdir do |dir|
      File.write(File.join(dir, "fleet.conf"), "INVENTORY=inventory\nPARTIDUO_DOMAIN=compta.example\n")
      code, output, _ = sh("deploy/bin/partiduo-fleet", "--config=#{File.join(dir, "fleet.conf")}", "provision",
        "deploy@srv1", "recette", "--version", "devel", "--name=Recette SARL", "--regime=fr")
      code.should eq(0)
      output.should contain("/usr/local/lib/partiduo-devel/bin/partiduo-provision --version=devel")
      output.should contain("--data-dir=/var/db/partiduo --etc-dir=/usr/local/etc/partiduo")
      output.should contain("'--name=Recette SARL'")
      output.should contain("printf '%s %s %s\\n' 'recette' 'deploy@srv1' 'devel'")
    end
  end
end
