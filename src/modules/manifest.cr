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

    record MenuEntry, code : String, parent : String?, order : Int32, route : String?, permission : String?
    record UiEntry, name : String, path : String

    # Manifeste déclaratif d'un module ou d'une extension (ADR-003 D2).
    #
    # Chaque méthode sans argument lit la valeur ; avec un argument, elle la
    # déclare. Le bloc de `Partiduo::Modules.register` est évalué avec le
    # manifeste pour receveur :
    #
    # ```
    # Partiduo::Modules.register do
    #   code "SKEL"
    #   name "skel.module.name" # clé i18n
    #   version "0.1.0"
    #   requires_core "~> 0.1"
    #   depends_on "ACCOUNTING"
    #   permission "skel.page.view"
    #   menu "SKEL", parent: "EXTENSION", order: 100, route: "skel:index", permission: "skel.page.view"
    #   ui "bulma", path: "ui/bulma"
    #   on "entry.posted" { |event| Skel::Counter.increment(event) }
    # end
    # ```
    class Manifest
      getter menus = [] of MenuEntry
      getter permissions = [] of String
      getter depends_on = [] of String
      getter depends_on_any = [] of Array(String)
      getter uis = [] of UiEntry
      getter subscriptions = {} of String => Array(Partiduo::Events::Handler)

      @code : String?
      @name : String?
      @version = "0.0.0"
      @requires_core : String?
      @kind = Kind::Extension

      def code : String
        @code || raise ArgumentError.new("manifeste sans code")
      end

      # Code du module ou de l'extension, en majuscules (`ACCOUNTING`, `SKEL`).
      def code(value : String) : Nil
        unless value.matches?(/\A[A-Z][A-Z0-9_]*\z/)
          raise ArgumentError.new("code de module invalide (majuscules, chiffres, _) : #{value}")
        end
        @code = value
      end

      # Clé i18n du nom affiché.
      def name : String
        @name || "#{code.downcase}.module.name"
      end

      def name(value : String) : Nil
        @name = value
      end

      def version : String
        @version
      end

      def version(value : String) : Nil
        @version = value
      end

      def requires_core : String?
        @requires_core
      end

      # Contrainte sur la version du cœur : `"~> 1.0"`, `">= 0.1.0"`, `"0.1.0"`.
      def requires_core(value : String) : Nil
        @requires_core = value
      end

      def kind : Kind
        @kind
      end

      def kind(value : Kind) : Nil
        @kind = value
      end

      # Toutes les pièces citées doivent être actives.
      def depends_on(*codes : String) : Nil
        @depends_on.concat(codes.to_a)
      end

      # Au moins une des pièces citées doit être active (ADR-006 D1, module Stock).
      def depends_on_any(*codes : String) : Nil
        @depends_on_any << codes.to_a
      end

      # Déclare une permission nommée (ADR-003 D4). Convention : préfixée par le
      # code du module en minuscules (`accounting.entry.post`).
      def permission(name : String) : Nil
        @permissions << name unless @permissions.includes?(name)
      end

      def menu(code : String, parent : String? = nil, order : Int32 = 0, route : String? = nil, permission : String? = nil) : Nil
        @menus << MenuEntry.new(code, parent, order, route, permission)
      end

      # Interface fournie par l'extension (ADR-005 D4).
      def ui(name : String, path : String) : Nil
        @uis << UiEntry.new(name, path)
      end

      # Abonnement à un événement (ADR-003 D7). Le gestionnaire n'est appelé
      # que si la pièce est active.
      def on(event_name : String, &handler : Partiduo::Events::Event -> Nil) : Nil
        Partiduo::Events.ensure_known!(event_name)
        (@subscriptions[event_name] ||= [] of Partiduo::Events::Handler) << handler
      end

      def socle? : Bool
        @kind.socle?
      end
    end
  end
end
