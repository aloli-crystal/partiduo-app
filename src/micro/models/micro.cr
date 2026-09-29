# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Micro
    # Paramètres du micro-entrepreneur (une seule ligne, la première) :
    # périodicité de la déclaration URSSAF (`monthly`, `quarterly`), option
    # pour le versement libératoire, début d'activité, nature de recette par
    # défaut des factures encaissées, dates de bascule vers la TVA et vers le
    # régime réel (ADR-007 D1). Modèle interne : l'interface passe par
    # `Partiduo::Api::Micro`.
    class Settings < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :periodicity, :string, max_size: 10, default: "quarterly"
      field :flat_tax, :bool, default: false
      field :activity_started_on, :date, null: true, blank: true
      field :default_nature_id, :big_int, null: true, blank: true
      field :vat_liable_since, :date, null: true, blank: true
      field :real_regime_since, :date, null: true, blank: true

      with_timestamp_fields
    end

    # Nature d'une recette ou d'un achat : code unique, libellé, sens
    # (`receipt`, `purchase`) et catégorie — pour une recette, celle de la
    # déclaration URSSAF (`sale_bic`, `service_bic`, `bnc`) ; pour un achat,
    # `goods` (marchandises revendues) ou `other`. Le code sert aussi de clé
    # au paramétrage comptable (D-MIC-004).
    class Nature < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :code, :string, max_size: 24, unique: true
      field :label, :string, max_size: 100
      field :kind, :string, max_size: 10
      field :category, :string, max_size: 12
      field :enabled, :bool, default: true

      with_timestamp_fields
    end

    # Ligne du livre des recettes (ADR-007 D1) : encaissement daté, client
    # (fiche du socle ou nom libre), nature, montant encaissé et TVA
    # comprise, mode de règlement, référence de la pièce, pièce jointe.
    # `origin` : `manual` (saisie) ou `invoicing` (facture encaissée) ;
    # `source` : référence de l'événement d'origine (`payment:12`,
    # `matching:5:invoice:42`). Une ligne se modifie ou s'efface tant que sa
    # période de déclaration URSSAF n'est ni déclarée ni close au socle
    # (déclencheur, D-MIC2-001) ; ensuite, la correction est une
    # contre-passation (`reversal_of_id`, montant négatif). `modified_at`,
    # `modified_by_id` : dernière modification.
    class Receipt < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :number, :string, max_size: 20, unique: true
      field :date, :date
      field :nature_id, :big_int
      field :category, :string, max_size: 12
      field :amount, :decimal, max_digits: 20, decimal_places: 4
      field :vat_amount, :decimal, max_digits: 20, decimal_places: 4, default: BigDecimal.new(0)
      field :method, :string, max_size: 16
      field :card_id, :big_int, null: true, blank: true
      field :party_name, :string, max_size: 255, blank: true, default: ""
      field :label, :string, max_size: 255, blank: true, default: ""
      field :reference, :string, max_size: 100, blank: true, default: ""
      field :attachment_id, :big_int, null: true, blank: true
      field :origin, :string, max_size: 16, default: "manual"
      field :source, :string, max_size: 100, blank: true, default: ""
      field :reversal_of_id, :big_int, null: true, blank: true
      field :recorded_by_id, :big_int, null: true, blank: true
      field :recorded_at, :date_time
      field :modified_at, :date_time, null: true, blank: true
      field :modified_by_id, :big_int, null: true, blank: true
    end

    # Ligne du registre des achats (ADR-007 D1), mêmes règles que le livre
    # des recettes. `vat_amount` : TVA déductible comprise dans le montant
    # payé (après la bascule vers la TVA seulement).
    class Purchase < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :number, :string, max_size: 20, unique: true
      field :date, :date
      field :nature_id, :big_int
      field :category, :string, max_size: 12
      field :amount, :decimal, max_digits: 20, decimal_places: 4
      field :vat_amount, :decimal, max_digits: 20, decimal_places: 4, default: BigDecimal.new(0)
      field :method, :string, max_size: 16
      field :card_id, :big_int, null: true, blank: true
      field :party_name, :string, max_size: 255, blank: true, default: ""
      field :label, :string, max_size: 255, blank: true, default: ""
      field :reference, :string, max_size: 100, blank: true, default: ""
      field :attachment_id, :big_int, null: true, blank: true
      field :reversal_of_id, :big_int, null: true, blank: true
      field :recorded_by_id, :big_int, null: true, blank: true
      field :recorded_at, :date_time
      field :modified_at, :date_time, null: true, blank: true
      field :modified_by_id, :big_int, null: true, blank: true
    end

    # Compteur de numérotation d'un registre par année (`R2026-00001`,
    # `A2026-00001`), tenu sous verrou (`SELECT … FOR UPDATE`, C3).
    class Counter < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :register, :string, max_size: 10
      field :year, :int
      field :next_number, :int, default: 1

      db_unique_constraint :micro_counter_unique, field_names: [:register, :year]
    end

    # Paramètre daté (taux URSSAF, seuils, cases de la 2042-C-PRO) : valeur
    # numérique ou texte en vigueur à partir de `valid_from` (ADR-007 D1 :
    # jamais écrit en dur).
    class Parameter < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :code, :string, max_size: 60
      field :valid_from, :date
      field :value, :decimal, max_digits: 20, decimal_places: 6, null: true, blank: true
      field :text, :string, max_size: 60, blank: true, default: ""

      with_timestamp_fields

      db_unique_constraint :micro_parameter_unique, field_names: [:code, :valid_from]
    end

    # Déclaration URSSAF faite par l'utilisateur pour une période (report
    # manuel des montants sur le site de l'URSSAF, ADR-007 D1).
    class Declaration < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :starts_on, :date, unique: true
      field :ends_on, :date
      field :declared_on, :date
      field :reference, :string, max_size: 100, blank: true, default: ""
      field :declared_by_id, :big_int, null: true, blank: true

      with_timestamp_fields
    end

    # Nature de recette d'un article du socle, pour ventiler une facture
    # encaissée par catégorie.
    class ItemNature < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :item_card_id, :big_int, unique: true
      field :nature_id, :big_int
    end

    # Facture émise, relevée à `invoice.issued` (charge utile seule, sans
    # appel à la Facturation) : de quoi inscrire la recette à l'encaissement.
    # `shares` : JSON `[{"item_card_id", "vat_rate_id", "amount"}]` des parts
    # hors taxe ; `vats` : JSON `[{"vat_rate_id", "amount"}]` de la TVA par
    # taux du socle.
    class Invoice < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :invoice_id, :big_int, unique: true
      field :number, :string, max_size: 40, blank: true, default: ""
      field :card_id, :big_int, null: true, blank: true
      field :issue_date, :date, null: true, blank: true
      field :total_vat, :decimal, max_digits: 20, decimal_places: 4
      field :total_gross, :decimal, max_digits: 20, decimal_places: 4
      field :shares, :text, blank: true, default: "[]"
      field :vats, :text, blank: true, default: "[]"
    end
  end
end
