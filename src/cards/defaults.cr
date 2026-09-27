# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Cards
    # Catégories créées au provisionnement, d'après les `fiche_def` de
    # `mod1/data.sql` et `mod2/data.sql` (Client, Fournisseur, Banque,
    # Vente, Marchandises, Services & Biens Divers) et les modèles de
    # `fiche_def_ref` (salariés, contacts, administrations). Libellés :
    # `cards.initial.categories.<code>` et `cards.initial.attributes.<clé>`.
    module Defaults
      record Definition, code : String, kind : String, attributes : Array({String, String}) = [] of {String, String}

      CATEGORIES = [
        Definition.new("CUSTOMER", "customer"),
        Definition.new("SUPPLIER", "supplier"),
        Definition.new("BANK", "bank"),
        Definition.new("SALE", "item"),
        Definition.new("PURCHASE", "item"),
        Definition.new("EXPENSE", "item"),
        Definition.new("EMPLOYEE", "employee", [{"first_name", "text"}]),
        # NOALYSS : attribut « Société » (type `card`) d'un contact.
        Definition.new("CONTACT", "contact", [{"first_name", "text"}, {"company", "card"}]),
        Definition.new("TAX_AUTHORITY", "other"),
      ]
    end
  end
end
