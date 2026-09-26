# SPDX-License-Identifier: AGPL-3.0-or-later

# Garde-fou de l'ADR-005 D3 : `src/` ne contient ni HTML, ni gabarit, ni
# fichier statique, ni handler Marten. Utilisé par la spec
# `spec/architecture/interface_boundary_spec.cr` et, en CI, directement :
#
#   crystal run scripts/interface_boundary.cr -- src
module InterfaceBoundary
  record Violation, path : String, line : Int32?, reason : String do
    def to_s(io : IO) : Nil
      io << path
      io << ':' << line if line
      io << " — " << reason
    end
  end

  # Seuls ces fichiers sont admis sous src/ : code Crystal, traductions, SQL.
  ALLOWED_EXTENSIONS = %w[.cr .yml .yaml .sql .adoc]

  # Répertoires propres à une interface dans une application Marten.
  FORBIDDEN_DIRECTORIES = %w[templates assets static handlers]

  CODE_PATTERNS = {
    /Marten::Handlers?\b/                                                                            => "handler Marten",
    /Marten::Template\b/                                                                             => "gabarit Marten",
    /Marten\.routes\b|Marten::Routing\b/                                                             => "routes Marten",
    /Marten::Middleware\b|MartenAuth::Middleware\b/                                                  => "middleware HTTP",
    /Marten::HTTP::Response\b/                                                                       => "réponse HTTP",
    /<!DOCTYPE|<\/?(html|head|body|div|span|form|input|table|button|script|style|template)\b[^>]*>/i => "balise HTML",
  }

  def self.scan(root : String) : Array(Violation)
    violations = [] of Violation

    Dir.glob(File.join(root, "**", "*"), match: File::MatchOptions::DotFiles).sort.each do |path|
      relative = path
      if File.directory?(path)
        if FORBIDDEN_DIRECTORIES.includes?(File.basename(path))
          violations << Violation.new(relative, nil, "répertoire réservé à l'interface")
        end
        next
      end

      extension = File.extname(path).downcase
      unless ALLOWED_EXTENSIONS.includes?(extension)
        violations << Violation.new(relative, nil, "fichier non admis dans le cœur (#{extension.presence || "sans extension"})")
        next
      end
      next unless extension == ".cr"

      File.read_lines(path).each_with_index(1) do |text, number|
        CODE_PATTERNS.each do |pattern, reason|
          violations << Violation.new(relative, number, reason) if text.matches?(pattern)
        end
      end
    end

    violations
  end
end

# Exécution directe : `crystal run scripts/interface_boundary.cr -- src`.
if PROGRAM_NAME.includes?("interface_boundary")
  root = ARGV.first? || "src"
  violations = InterfaceBoundary.scan(root)
  if violations.empty?
    puts "Garde-fou ADR-005 D3 : #{root}/ ne contient aucune interface."
  else
    STDERR.puts "Garde-fou ADR-005 D3 : #{violations.size} violation(s) dans #{root}/ :"
    violations.each { |violation| STDERR.puts "  #{violation}" }
    exit 1
  end
end
