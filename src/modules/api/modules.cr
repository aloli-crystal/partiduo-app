# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    # Contrat du registre : pièces de l'instance, activation, catalogue des
    # permissions, menus (ADR-003 D2, D4 ; ADR-006 D2). Documentation :
    # `doc/api/modules.adoc`.
    module Modules
      MODULE_CODE    = "CORE"
      MANAGE_MODULES = "core.modules.manage"

      # Une pièce du registre.
      record ModuleView,
        code : String,
        name_key : String,
        kind : String,
        version : String,
        active : Bool,
        depends_on : Array(String),
        depends_on_any : Array(Array(String)),
        permissions : Array(String)

      # Une permission cochable dans un profil. `label_key` : clé i18n du libellé.
      record PermissionView, name : String, label_key : String, module_code : String

      # Une entrée de menu, avec ses enfants visibles. `route` : nom de route
      # que l'interface résout (le cœur n'a pas de route) ; `nil` pour une rubrique.
      record MenuView,
        code : String,
        label_key : String,
        route : String?,
        module_code : String,
        children : Array(MenuView)

      # Pièces enregistrées (socle, modules, extensions) et leur état.
      # Tout utilisateur authentifié peut les lire.
      def self.list(actor : Actor) : Array(ModuleView)
        Guard.authorize_account!(actor, module_code: MODULE_CODE)
        active_codes = Partiduo::Modules::State.active_codes
        Partiduo::Modules.manifests.values.map { |manifest| view(manifest, active_codes) }
      end

      # Une pièce ; `NotFound` si le code est inconnu.
      def self.get(actor : Actor, code : String) : ModuleView
        Guard.authorize_account!(actor, module_code: MODULE_CODE)
        manifest = Partiduo::Modules[code.upcase]? || raise NotFound.new("module", code)
        view(manifest, Partiduo::Modules::State.active_codes)
      end

      # Active un module ou une extension sur l'instance (ADR-006 D2).
      #
      # Erreurs (champ `code`) : `modules.errors.activation.socle` (pièce du
      # socle, toujours active), `modules.errors.activation.missing_dependency`
      # (`%{module}`, `%{dependency}`) et `modules.errors.activation.incompatible`
      # (`%{module}`, `%{detail}`). Activer une pièce active ne change rien.
      def self.activate(actor : Actor, code : String) : Result(ModuleView)
        Guard.authorize!(actor, MANAGE_MODULES, module_code: MODULE_CODE)
        manifest = Partiduo::Modules[code.upcase]? || raise NotFound.new("module", code)

        Transaction.run do
          current = Partiduo::Modules::State.active_codes
          if manifest.socle?
            next Result(ModuleView).failure(FieldError.new("code", "modules.errors.activation.socle", {"module" => manifest.code}))
          end
          next Result(ModuleView).success(view(manifest, current)) if current.includes?(manifest.code)

          wanted = current + Set{manifest.code}
          errors = activation_errors(manifest, wanted)
          next Result(ModuleView).failure(errors) unless errors.empty?

          Partiduo::Modules::State.save(wanted, actor.user_id)
          Result(ModuleView).success(view(manifest, wanted))
        end
      end

      # Désactive un module ou une extension. Ses données sont conservées
      # (ADR-006 D2) ; ses commandes et requêtes lèvent `ModuleDisabled`.
      #
      # Erreurs (champ `code`) : `modules.errors.activation.socle`,
      # `modules.errors.activation.required_by` (`%{module}`, `%{dependent}`).
      def self.deactivate(actor : Actor, code : String) : Result(ModuleView)
        Guard.authorize!(actor, MANAGE_MODULES, module_code: MODULE_CODE)
        manifest = Partiduo::Modules[code.upcase]? || raise NotFound.new("module", code)

        Transaction.run do
          current = Partiduo::Modules::State.active_codes
          if manifest.socle?
            next Result(ModuleView).failure(FieldError.new("code", "modules.errors.activation.socle", {"module" => manifest.code}))
          end
          next Result(ModuleView).success(view(manifest, current)) unless current.includes?(manifest.code)

          dependents = Partiduo::Modules.dependents(manifest.code, current)
          unless dependents.empty?
            errors = dependents.map do |dependent|
              FieldError.new("code", "modules.errors.activation.required_by",
                {"module" => manifest.code, "dependent" => dependent.code})
            end
            next Result(ModuleView).failure(errors)
          end

          wanted = current - Set{manifest.code}
          Partiduo::Modules::State.save(wanted, actor.user_id)
          Result(ModuleView).success(view(manifest, wanted))
        end
      end

      # Permissions des pièces actives, que l'administrateur coche dans un
      # profil (ADR-003 D4). Le catalogue n'est pas confidentiel (il découle
      # des manifestes) : tout utilisateur authentifié peut le lire.
      def self.permissions(actor : Actor) : Array(PermissionView)
        Guard.authorize_account!(actor, module_code: MODULE_CODE)
        Partiduo::Modules.active_manifests.flat_map(&.permission_entries).map do |entry|
          PermissionView.new(entry.name, entry.label, entry.module_code)
        end
      end

      # Menu de l'acteur : entrées des pièces actives dont il a la permission,
      # en arbre, triées par ordre. Une rubrique sans route ni enfant visible
      # est omise (ADR-005 : seuls les modules actifs apparaissent).
      def self.menu(actor : Actor) : Array(MenuView)
        Guard.authorize_account!(actor, module_code: MODULE_CODE)
        menus = Partiduo::Modules.active_menus.select do |entry|
          (permission = entry.permission).nil? || actor.can?(permission)
        end
        build_menu(menus, nil)
      end

      private def self.build_menu(entries : Array(Partiduo::Modules::MenuEntry), parent : String?) : Array(MenuView)
        entries.select(&.parent.==(parent)).compact_map do |entry|
          children = build_menu(entries, entry.code)
          next if entry.route.nil? && children.empty?
          MenuView.new(entry.code, entry.label, entry.route, entry.module_code, children)
        end
      end

      private def self.activation_errors(manifest : Partiduo::Modules::Manifest, wanted : Set(String)) : Array(FieldError)
        errors = [] of FieldError
        manifest.dependencies.each do |dependency|
          unless Partiduo::Modules.active_in?(dependency.code, wanted)
            errors << FieldError.new("code", "modules.errors.activation.missing_dependency",
              {"module" => manifest.code, "dependency" => dependency.code})
          end
        end
        manifest.depends_on_any.each do |alternatives|
          unless alternatives.any? { |other| Partiduo::Modules.active_in?(other, wanted) }
            errors << FieldError.new("code", "modules.errors.activation.missing_dependency",
              {"module" => manifest.code, "dependency" => alternatives.join(" | ")})
          end
        end
        if errors.empty?
          Partiduo::Modules.dependency_errors(manifest, wanted).each do |detail|
            errors << FieldError.new("code", "modules.errors.activation.incompatible",
              {"module" => manifest.code, "detail" => detail})
          end
        end
        errors
      end

      private def self.view(manifest : Partiduo::Modules::Manifest, active_codes : Set(String)) : ModuleView
        ModuleView.new(
          code: manifest.code,
          name_key: manifest.name,
          kind: manifest.kind.to_s.downcase,
          version: manifest.version,
          active: Partiduo::Modules.active_in?(manifest.code, active_codes),
          depends_on: manifest.depends_on,
          depends_on_any: manifest.depends_on_any,
          permissions: manifest.permissions,
        )
      end
    end
  end
end
