# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  # Registre des modules officiels et des extensions (ADR-003 D2, ADR-006 D1).
  #
  # Composition à la compilation (chaque pièce appelle `register` à son
  # chargement), activation à l'exécution (`Partiduo::Config.active_module_codes`).
  module Modules
    class ConfigurationError < Exception
    end

    @@manifests : Hash(String, Manifest)?

    def self.manifests : Hash(String, Manifest)
      @@manifests ||= {} of String => Manifest
    end

    # Déclare une pièce. Le bloc est évalué avec le manifeste pour receveur.
    def self.register(&) : Manifest
      manifest = Manifest.new
      with manifest yield manifest
      code = manifest.code
      raise ArgumentError.new("module déjà enregistré : #{code}") if manifests.has_key?(code)
      manifests[code] = manifest
    end

    def self.[](code : String) : Manifest
      manifests[code]? || raise KeyError.new("module inconnu : #{code}")
    end

    def self.[]?(code : String) : Manifest?
      manifests[code]?
    end

    def self.registered?(code : String) : Bool
      manifests.has_key?(code)
    end

    # Une pièce du socle est toujours active ; un module ou une extension l'est
    # s'il figure dans la configuration de l'instance.
    def self.active?(code : String) : Bool
      manifest = manifests[code]?
      return false if manifest.nil?
      manifest.socle? || Partiduo::Config.active_module_codes.includes?(code.downcase)
    end

    def self.active_manifests : Array(Manifest)
      manifests.values.select { |manifest| active?(manifest.code) }
    end

    def self.permission_declared?(permission : String) : Bool
      manifests.each_value.any?(&.permissions.includes?(permission))
    end

    # Permissions des pièces actives : ce que l'administrateur peut cocher.
    def self.active_permissions : Array(String)
      active_manifests.flat_map(&.permissions)
    end

    # Vérifie la cohérence de la configuration au démarrage (ADR-003 D2) : une
    # incohérence empêche le démarrage au lieu d'échouer à l'usage.
    def self.check! : Nil
      errors = [] of String

      Partiduo::Config.active_module_codes.each do |code|
        errors << "module actif inconnu : #{code}" unless manifests.has_key?(code.upcase)
      end

      active_manifests.each do |manifest|
        manifest.depends_on.each do |dependency|
          errors << "#{manifest.code} requiert #{dependency}, inactif" unless active?(dependency)
        end
        manifest.depends_on_any.each do |alternatives|
          unless alternatives.any? { |dependency| active?(dependency) }
            errors << "#{manifest.code} requiert l'un de #{alternatives.join(", ")}, tous inactifs"
          end
        end
        if (constraint = manifest.requires_core) && !Version.satisfies?(Partiduo::VERSION, constraint)
          errors << "#{manifest.code} requiert le cœur #{constraint}, version #{Partiduo::VERSION}"
        end
      end

      raise ConfigurationError.new(errors.join("\n")) unless errors.empty?
    end

    # Contraintes de version à la manière de shards : `~>`, `>=`, `>`, `<=`, `<`, `=`.
    module Version
      def self.satisfies?(version : String, constraint : String) : Bool
        current = SemanticVersion.parse(version)
        constraint.split(',').all? do |part|
          operator, _, target = part.strip.partition(' ')
          if target.empty?
            target, operator = operator, "="
          end
          check(current, operator, target.strip)
        end
      end

      private def self.check(current : SemanticVersion, operator : String, target : String) : Bool
        case operator
        when "~>"
          segments = target.split('.')
          lower = SemanticVersion.parse(normalize(target))
          upper_segments = segments[0...(segments.size > 1 ? segments.size - 1 : 1)].map(&.to_i)
          upper_segments[-1] += 1
          upper = SemanticVersion.parse(normalize(upper_segments.join('.')))
          current >= lower && current < upper
        when ">=" then current >= SemanticVersion.parse(normalize(target))
        when ">"  then current > SemanticVersion.parse(normalize(target))
        when "<=" then current <= SemanticVersion.parse(normalize(target))
        when "<"  then current < SemanticVersion.parse(normalize(target))
        when "="  then current == SemanticVersion.parse(normalize(target))
        else
          raise ArgumentError.new("opérateur de version inconnu : #{operator}")
        end
      end

      private def self.normalize(version : String) : String
        parts = version.split('.')
        (parts + ["0"] * {3 - parts.size, 0}.max).first(3).join('.')
      end
    end
  end
end
