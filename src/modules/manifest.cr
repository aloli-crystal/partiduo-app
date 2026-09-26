# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Modules
    # Nature d'une pièce du registre (ADR-006 D1, ADR-003 D1).
    enum Kind
      # Toujours actif : core, cards, vat…
      Socle
      # Module officiel activable, livré dans partiduo-app : accounting, invoicing…
      Module
      # Extension livrée par un shard partiduo-<nom>.
      Extension
    end

    # Entrée de menu déclarée par un manifeste (ADR-003 D2, ADR-005).
    #
    # * `code` : identifiant unique dans tout le registre (`ACC_ENTRY_PURCHASE`) ;
    # * `parent` : code de la rubrique parente (`ENTRY`), `nil` pour une rubrique
    #   de premier niveau (déclarées par `CORE`) ;
    # * `label` : clé i18n du libellé ;
    # * `route` : nom de route que *l'interface* résout (`accounting:entry_purchase`) ;
    #   le cœur n'a aucune route (ADR-005 D1) ;
    # * `permission` : permission requise pour voir l'entrée, `nil` = tout
    #   utilisateur authentifié.
    record MenuEntry,
      code : String,
      parent : String?,
      order : Int32,
      route : String?,
      permission : String?,
      label : String,
      module_code : String

    # Interface fournie par une extension (ADR-005 D4) : `ui "bulma", path: "ui/bulma"`.
    record UiEntry, name : String, path : String

    # Permission nommée (ADR-003 D4), déclarée par un manifeste et cochée par
    # l'administrateur dans les profils.
    record PermissionEntry, name : String, label : String, module_code : String

    # Dépendance à une autre pièce, avec contrainte de version facultative.
    record Dependency, code : String, version : String?

    # Manifeste déclaratif d'un module ou d'une extension (ADR-003 D2).
    #
    # Chaque méthode sans argument lit la valeur ; avec un argument, elle la
    # déclare. Le bloc de `Partiduo::Modules.register` est évalué avec le
    # manifeste pour receveur, `code` en premier :
    #
    # ```
    # Partiduo::Modules.register do
    #   code "SKEL"
    #   name "skel.module.name" # clé i18n
    #   version "0.1.0"
    #   requires_core "~> 0.1"
    #   depends_on "ACCOUNTING"
    #   depends_on_any "INVOICING", "ACCOUNTING"
    #   permission "skel.page.view"
    #   menu "SKEL", parent: "EXTENSION", order: 100, route: "skel:index", permission: "skel.page.view"
    #   ui "bulma", path: "ui/bulma"
    #   on("entry.posted") { |event| Skel::Counter.increment(event) }
    # end
    # ```
    class Manifest
      getter menus = [] of MenuEntry
      getter permission_entries = [] of PermissionEntry
      getter dependencies = [] of Dependency
      getter depends_on_any = [] of Array(String)
      getter uis = [] of UiEntry
      getter subscriptions = {} of String => Array(Partiduo::Events::Handler)

      @code : String?
      @name : String?
      @version = "0.0.0"
      @requires_core : String?
      @kind = Kind::Extension

      def code : String
        @code || raise ArgumentError.new("manifeste sans code : `code` doit être déclaré en premier")
      end

      # Code du module ou de l'extension, en majuscules (`ACCOUNTING`, `SKEL`).
      def code(value : String) : Nil
        unless value.matches?(/\A[A-Z][A-Z0-9_]*\z/)
          raise ArgumentError.new("code de module invalide (majuscules, chiffres, _) : #{value}")
        end
        @code = value
      end

      # Clé i18n du nom affiché ; par défaut `<code en minuscules>.module.name`.
      def name : String
        @name || "#{code.downcase}.module.name"
      end

      def name(value : String) : Nil
        @name = value
      end

      def version : String
        @version
      end

      # Version de la pièce, au format `majeure.mineure.correctif`.
      def version(value : String) : Nil
        @version = value
      end

      def requires_core : String?
        @requires_core
      end

      # Contrainte sur la version du cœur : `"~> 1.0"`, `">= 0.1.0, < 2.0"`, `"0.1.0"`.
      def requires_core(value : String) : Nil
        @requires_core = value
      end

      def kind : Kind
        @kind
      end

      def kind(value : Kind) : Nil
        @kind = value
      end

      def socle? : Bool
        @kind.socle?
      end

      # Codes des pièces requises (toutes).
      def depends_on : Array(String)
        @dependencies.map(&.code)
      end

      # Toutes les pièces citées doivent être actives. `version:` ajoute une
      # contrainte sur leur version (`depends_on "DOCUMENT", version: "~> 1.0"`).
      def depends_on(*codes : String, version : String? = nil) : Nil
        codes.each do |dependency|
          @dependencies << Dependency.new(dependency, version) unless depends_on.includes?(dependency)
        end
      end

      # Au moins une des pièces citées doit être active (ADR-006 D1, module Stock).
      def depends_on_any(*codes : String) : Nil
        raise ArgumentError.new("depends_on_any attend au moins deux pièces") if codes.size < 2
        @depends_on_any << codes.to_a
      end

      # Noms des permissions déclarées.
      def permissions : Array(String)
        @permission_entries.map(&.name)
      end

      # Déclare une permission nommée (ADR-003 D4), au format
      # `<préfixe>.<objet>.<action>` (`accounting.entry.post`). Libellé : clé
      # i18n, par défaut `<préfixe>.permissions.<objet>.<action>`.
      def permission(name : String, label : String? = nil) : Nil
        unless name.matches?(/\A[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+\z/)
          raise ArgumentError.new("nom de permission invalide (minuscules séparées par des points) : #{name}")
        end
        return if permissions.includes?(name)

        prefix, _, rest = name.partition('.')
        @permission_entries << PermissionEntry.new(name, label || "#{prefix}.permissions.#{rest}", code)
      end

      # Déclare une entrée de menu. Libellé par défaut :
      # `<code du manifeste en minuscules>.menu.<code de l'entrée en minuscules>`.
      def menu(code menu_code : String, parent : String? = nil, order : Int32 = 0, route : String? = nil,
               permission : String? = nil, label : String? = nil) : Nil
        unless menu_code.matches?(/\A[A-Z][A-Z0-9_]*\z/)
          raise ArgumentError.new("code de menu invalide (majuscules, chiffres, _) : #{menu_code}")
        end
        @menus << MenuEntry.new(
          code: menu_code,
          parent: parent,
          order: order,
          route: route,
          permission: permission,
          label: label || "#{code.downcase}.menu.#{menu_code.downcase}",
          module_code: code,
        )
      end

      # Interface fournie par l'extension (ADR-005 D4).
      def ui(name : String, path : String) : Nil
        @uis << UiEntry.new(name, path)
      end

      # Abonnement à un événement (ADR-003 D7). Le gestionnaire est appelé,
      # dans la transaction de l'opération, seulement si la pièce est active.
      def on(event_name : String, &handler : Partiduo::Events::Event -> Nil) : Nil
        Partiduo::Events.ensure_known!(event_name)
        (@subscriptions[event_name] ||= [] of Partiduo::Events::Handler) << handler
      end

      # Événements auxquels la pièce est abonnée.
      def subscribed_events : Array(String)
        @subscriptions.keys
      end
    end
  end
end
