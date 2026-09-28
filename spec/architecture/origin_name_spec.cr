# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Règle du projet (D-NOM-001) : le nom du logiciel d'origine n'apparaît que
# dans les fichiers *.adoc et *.md (attribution), jamais dans le code, les
# scripts, les données, les traductions ni la CI. Même contrôle que l'étape
# « Garde-fou du nom d'origine » de la CI. Le motif est assemblé pour que ce
# fichier ne se signale pas lui-même.
describe "Garde-fou du nom d'origine" do
  it "ne trouve le nom d'origine dans aucun fichier suivi hors *.adoc et *.md" do
    base = File.expand_path("../..", __DIR__)
    pattern = "noa" + "lyss"
    output = IO::Memory.new
    status = Process.run("git", ["grep", "-il", pattern, "--", ".", ":!*.adoc", ":!*.md"],
      chdir: base, output: output, error: Process::Redirect::Inherit)
    # git grep : 0 = trouvé, 1 = rien trouvé, au-delà = erreur.
    status.exit_code.should be <= 1
    output.to_s.lines.should eq([] of String)
  end
end
