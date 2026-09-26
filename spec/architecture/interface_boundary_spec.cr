# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"
require "../../scripts/interface_boundary"

describe "Garde-fou ADR-005 D3" do
  it "ne trouve ni HTML, ni gabarit, ni fichier statique, ni handler sous src/" do
    violations = InterfaceBoundary.scan(File.expand_path("../../src", __DIR__))
    violations.map(&.to_s).should eq([] of String)
  end

  it "détecte une interface glissée dans le cœur" do
    root = File.join(Dir.tempdir, "partiduo-garde-fou-#{Random::Secure.hex(4)}")
    Dir.mkdir_p(File.join(root, "app", "templates"))
    File.write(File.join(root, "app", "page.cr"), "class Page < Marten::Handler\n  HTML = \"<div class='box'>\"\nend\n")
    File.write(File.join(root, "app", "app.js"), "")

    reasons = InterfaceBoundary.scan(root).map(&.reason)

    reasons.should contain("handler Marten")
    reasons.should contain("balise HTML")
    reasons.should contain("répertoire réservé à l'interface")
    reasons.any?(&.starts_with?("fichier non admis")).should be_true
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "impose l'en-tête SPDX à chaque fichier source" do
    base = File.expand_path("../..", __DIR__)
    files = Dir.glob(%w[src spec config scripts].map { |dir| File.join(base, dir, "**", "*.cr") }) + [File.join(base, "manage.cr")]
    missing = files.reject { |path| File.read_lines(path).first? == "# SPDX-License-Identifier: AGPL-3.0-or-later" }
    missing.map { |path| Path[path].relative_to(base).to_s }.should eq([] of String)
  end
end
