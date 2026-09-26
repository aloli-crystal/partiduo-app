# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  # Registre des pièces du socle, des modules officiels et des extensions
  # (ADR-003 D2, ADR-006 D1).
  #
  # Composition à la compilation (chaque pièce appelle `register` à son
  # chargement), activation à l'exécution (`Partiduo::Modules::State`).
  #
  # Ce module est interne au cœur : l'interface et les extensions passent par
  # `Partiduo::Api::Modules`. Les applications du cœur (profils, contrat) s'en
  # servent directement — voir `doc/api/modules.adoc`.
  module Modules
    # Incohérence du registre ou de la configuration : empêche le démarrage.
    class ConfigurationError < Exception
    end

    @@manifests : Hash(String, Manifest)?

    # Pièces enregistrées, dans l'ordre d'enregistrement (ordre des `require`).
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

    # ---------------------------------------------------------------------------
    # Activation
    # ---------------------------------------------------------------------------

    # Une pièce du socle est toujours active ; un module ou une extension l'est
    # s'il figure dans l'ensemble actif de l'instance (`State`).
    def self.active?(code : String) : Bool
      active_in?(code, State.active_codes)
    end

    def self.active_in?(code : String, active_codes : Set(String)) : Bool
      manifest = manifests[code]?
      return false if manifest.nil?
      manifest.socle? || active_codes.includes?(code)
    end

    # Pièces actives, dans l'ordre d'enregistrement.
    def self.active_manifests : Array(Manifest)
      active_codes = State.active_codes
      manifests.values.select { |manifest| active_in?(manifest.code, active_codes) }
    end

    # Lève `Partiduo::Api::ModuleDisabled` si la pièce n'est pas active
    # (ADR-006 D2). `Partiduo::Api::Guard.authorize!` l'appelle en tête de
    # chaque commande et requête.
    def self.require_active!(code : String) : Nil
      raise Partiduo::Api::ModuleDisabled.new(code) unless active?(code)
    end

    # Pièces actives qui exigent `code` (par `depends_on`, ou par
    # `depends_on_any` si `code` est la seule alternative active).
    def self.dependents(code : String, active_codes : Set(String) = State.active_codes) : Array(Manifest)
      manifests.values.select do |manifest|
        next false unless manifest.code != code && active_in?(manifest.code, active_codes)
        manifest.depends_on.includes?(code) ||
          manifest.depends_on_any.any? do |alternatives|
            alternatives.includes?(code) &&
              alternatives.none? { |other| other != code && active_in?(other, active_codes) }
          end
      end
    end

    # ---------------------------------------------------------------------------
    # Permissions (ADR-003 D4)
    # ---------------------------------------------------------------------------

    # Toutes les permissions déclarées, pièces inactives comprises.
    def self.permission_catalog : Array(PermissionEntry)
      manifests.values.flat_map(&.permission_entries)
    end

    def self.permission_declared?(permission : String) : Bool
      manifests.each_value.any?(&.permissions.includes?(permission))
    end

    # Permission déclarée, ou `nil`.
    def self.permission_entry(permission : String) : PermissionEntry?
      manifests.each_value do |manifest|
        manifest.permission_entries.each { |entry| return entry if entry.name == permission }
      end
      nil
    end

    # Permissions des pièces actives : ce que l'administrateur peut cocher.
    def self.active_permissions : Array(String)
      active_manifests.flat_map(&.permissions)
    end

    # Noms qui ne correspondent à aucune permission déclarée. Un profil refuse
    # de les enregistrer.
    def self.unknown_permissions(names : Enumerable(String)) : Array(String)
      names.reject { |name| permission_declared?(name) }.uniq!
    end

    # Permissions effectives d'un profil : celles qu'il porte *et* qui
    # appartiennent à une pièce active. Un profil garde ses permissions d'un
    # module désactivé ; elles reprennent effet à sa réactivation.
    def self.effective_permissions(names : Enumerable(String)) : Set(String)
      active = active_permissions.to_set
      names.select { |name| active.includes?(name) }.to_set
    end

    # ---------------------------------------------------------------------------
    # Menus
    # ---------------------------------------------------------------------------

    # Entrées de menu des pièces actives, triées par ordre puis par code.
    def self.active_menus : Array(MenuEntry)
      active_manifests.flat_map(&.menus).sort_by! { |menu| {menu.order, menu.code} }
    end

    # ---------------------------------------------------------------------------
    # Vérification au démarrage (ADR-003 D2)
    # ---------------------------------------------------------------------------

    # Vérifie la cohérence du registre et de l'ensemble actif. Une incohérence
    # lève `ConfigurationError` et empêche le démarrage, au lieu d'échouer à
    # l'usage. Appelée par `Partiduo::Modules::App#setup`.
    def self.check! : Nil
      errors = structure_errors + activation_errors(State.active_codes)
      raise ConfigurationError.new(errors.join("\n")) unless errors.empty?
    end

    # Défauts de composition, indépendants de l'activation : versions mal
    # formées, permissions ou menus déclarés deux fois, menus orphelins.
    def self.structure_errors : Array(String)
      errors = [] of String
      permission_owner = {} of String => String
      menu_owner = {} of String => String

      manifests.each_value do |manifest|
        unless Version.valid?(manifest.version)
          errors << "#{manifest.code} : version invalide « #{manifest.version} »"
        end
        manifest.permissions.each do |permission|
          if owner = permission_owner[permission]?
            errors << "permission #{permission} déclarée par #{owner} et #{manifest.code}"
          else
            permission_owner[permission] = manifest.code
          end
        end
        manifest.menus.each do |menu|
          if owner = menu_owner[menu.code]?
            errors << "menu #{menu.code} déclaré par #{owner} et #{manifest.code}"
          else
            menu_owner[menu.code] = manifest.code
          end
        end
      end

      manifests.each_value do |manifest|
        manifest.menus.each do |menu|
          if (parent = menu.parent) && !menu_owner.has_key?(parent)
            errors << "#{manifest.code} : menu #{menu.code} rattaché à #{parent}, inconnu"
          end
          if (permission = menu.permission) && !permission_owner.has_key?(permission)
            errors << "#{manifest.code} : menu #{menu.code} exige #{permission}, non déclarée"
          end
        end
      end

      errors
    end

    # Défauts de l'ensemble actif : pièce inconnue, dépendance inactive ou de
    # version incompatible, cœur hors de `requires_core`.
    def self.activation_errors(active_codes : Set(String)) : Array(String)
      errors = [] of String

      active_codes.each do |code|
        manifest = manifests[code]?
        if manifest.nil?
          errors << "module actif inconnu : #{code.downcase}"
        elsif manifest.socle?
          errors << "#{code} appartient au socle : toujours actif, ne s'active pas"
        end
      end

      manifests.each_value do |manifest|
        next unless active_in?(manifest.code, active_codes)
        errors.concat(dependency_errors(manifest, active_codes))
      end

      errors
    end

    # Dépendances non satisfaites d'une pièce, si elle était active avec
    # `active_codes`.
    def self.dependency_errors(manifest : Manifest, active_codes : Set(String)) : Array(String)
      errors = [] of String
      manifest.dependencies.each do |dependency|
        target = manifests[dependency.code]?
        if target.nil?
          errors << "#{manifest.code} requiert #{dependency.code}, inconnu"
        elsif !active_in?(dependency.code, active_codes)
          errors << "#{manifest.code} requiert #{dependency.code}, inactif"
        elsif (constraint = dependency.version) && !Version.satisfies?(target.version, constraint)
          errors << "#{manifest.code} requiert #{dependency.code} #{constraint}, version #{target.version}"
        end
      end
      manifest.depends_on_any.each do |alternatives|
        unless alternatives.any? { |code| active_in?(code, active_codes) }
          errors << "#{manifest.code} requiert l'un de #{alternatives.join(", ")}, tous inactifs"
        end
      end
      if (constraint = manifest.requires_core) && !Version.satisfies?(Partiduo::VERSION, constraint)
        errors << "#{manifest.code} requiert le cœur #{constraint}, version #{Partiduo::VERSION}"
      end
      errors
    end

    # Contraintes de version à la manière de shards : `~>`, `>=`, `>`, `<=`,
    # `<`, `=`, combinables par des virgules (`">= 0.1, < 1.0"`).
    module Version
      def self.valid?(version : String) : Bool
        !SemanticVersion.parse?(version).nil?
      end

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
