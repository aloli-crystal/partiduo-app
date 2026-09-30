# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Liberal
    # Paramètres du professionnel libéral (une seule ligne, la première) :
    # profession exercée (cadre d'identification de la 2035), début
    # d'activité, nature des recettes issues de la Facturation, interface
    # du dossier (`simple` ou `accounting`, D-LIB3-001). Modèle interne :
    # l'interface passe par `Partiduo::Api::Liberal`.
    class Settings < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :profession, :string, max_size: 100, blank: true, default: ""
      field :activity_started_on, :date, null: true, blank: true
      field :default_nature_id, :big_int, null: true, blank: true
      field :interface, :string, max_size: 16, default: "simple"

      with_timestamp_fields
    end

    # Nature d'une recette ou d'une dépense : code unique, libellé, sens
    # (`receipt`, `expense`) et rubrique de la 2035-A (`heading`, liste
    # fermée `Partiduo::Api::Liberal::HEADINGS`). Le code sert aussi de clé
    # au paramétrage comptable.
    class Nature < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :code, :string, max_size: 32, unique: true
      field :label, :string, max_size: 100
      field :kind, :string, max_size: 10
      field :heading, :string, max_size: 32
      field :enabled, :bool, default: true

      with_timestamp_fields
    end

    # Ligne du livre-journal (ADR-007 D6) : recette encaissée ou dépense
    # payée, datée, ventilée par nature (donc par rubrique), toutes taxes
    # comprises (comptabilité de trésorerie). `nondeductible_amount` : part
    # d'une dépense non déductible (usage privé), réintégrée à la 2035-A.
    # `origin` : `manual` ou `invoicing` ; `source` : événement d'origine.
    # Une ligne se modifie et se supprime tant que son exercice est ouvert ;
    # ensuite elle est intangible (déclencheur) et se corrige par une
    # contre-passation (`reversal_of_id`, montants opposés) datée dans un
    # exercice ouvert (DECISIONS D-LIB2-001). `modified_at`,
    # `modified_by_id` : dernière modification.
    class Line < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :number, :string, max_size: 20, unique: true
      field :kind, :string, max_size: 10
      field :date, :date
      field :nature_id, :big_int
      field :heading, :string, max_size: 32
      field :amount, :decimal, max_digits: 20, decimal_places: 4
      field :nondeductible_amount, :decimal, max_digits: 20, decimal_places: 4, default: BigDecimal.new(0)
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

    # Compteur de numérotation par registre et par année (`J2026-00001`
    # pour le livre-journal, `I2026-00001` pour les immobilisations), sous
    # verrou (`SELECT … FOR UPDATE`, C3).
    class Counter < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :register, :string, max_size: 10
      field :year, :int
      field :next_number, :int, default: 1

      db_unique_constraint :liberal_counter_unique, field_names: [:register, :year]
    end

    # Immobilisation (registre des immobilisations, 2035-B) : désignation,
    # catégorie, dates d'acquisition et de mise en service, base
    # amortissable, durée d'amortissement linéaire en années (0 : non
    # amortissable), paiement. Se modifie et se supprime tant que l'exercice
    # d'acquisition est ouvert et qu'aucune année figée n'en dépend
    # (DECISIONS D-LIB2-004) ; sinon une erreur se corrige par une
    # contre-passation (`reversal_of_id`, base opposée) la même année, ou
    # par une cession.
    class Asset < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :number, :string, max_size: 20, unique: true
      field :label, :string, max_size: 255
      field :category, :string, max_size: 16
      field :acquired_on, :date
      field :service_on, :date
      field :amount, :decimal, max_digits: 20, decimal_places: 4
      field :duration_years, :int, default: 0
      field :method, :string, max_size: 16
      field :card_id, :big_int, null: true, blank: true
      field :party_name, :string, max_size: 255, blank: true, default: ""
      field :reference, :string, max_size: 100, blank: true, default: ""
      field :attachment_id, :big_int, null: true, blank: true
      field :reversal_of_id, :big_int, null: true, blank: true
      field :recorded_by_id, :big_int, null: true, blank: true
      field :recorded_at, :date_time
      field :modified_at, :date_time, null: true, blank: true
      field :modified_by_id, :big_int, null: true, blank: true
    end

    # Cession d'une immobilisation : date, prix encaissé, mode de règlement ;
    # une par immobilisation. Se supprime tant que son exercice est ouvert
    # (DECISIONS D-LIB2-004), intangible ensuite.
    class Disposal < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :asset_id, :big_int, unique: true
      field :date, :date
      field :price, :decimal, max_digits: 20, decimal_places: 4
      field :method, :string, max_size: 16
      field :reference, :string, max_size: 100, blank: true, default: ""
      field :recorded_by_id, :big_int, null: true, blank: true
      field :recorded_at, :date_time
    end

    # Réintégration ou déduction diverse d'une année (2035-A), hors
    # livre-journal : `kind` dans `Partiduo::Api::Liberal::ADJUSTMENT_KINDS`.
    # Figée dès que l'année compte une période close du socle (déclencheur).
    class Adjustment < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :year, :int
      field :kind, :string, max_size: 24
      field :label, :string, max_size: 255
      field :amount, :decimal, max_digits: 20, decimal_places: 4
      field :recorded_by_id, :big_int, null: true, blank: true
      field :recorded_at, :date_time
    end

    # Correspondance d'un poste (rubrique ou total calculé) avec une ligne
    # d'un formulaire (`2035`, `2035-A`, `2035-B`), en vigueur à partir du
    # millésime `millesime` (ADR-007 D6 : paramétrable, jamais en dur).
    class FormLine < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :millesime, :int
      field :item, :string, max_size: 40
      field :form, :string, max_size: 10
      field :line, :string, max_size: 10, blank: true, default: ""
      field :box, :string, max_size: 10, blank: true, default: ""

      with_timestamp_fields

      db_unique_constraint :liberal_form_line_unique, field_names: [:millesime, :item]
    end

    # État d'un exercice (année civile de la 2035) propre au module : 2035
    # transmise (`transmitted_at`, `reference` du dépôt, empreinte transmise)
    # — l'exercice est alors figé (déclencheurs) — et empreinte de la 2035
    # préparée au moment du figement (`frozen_fingerprint`, `frozen_at`),
    # par la transmission ou par la clôture au socle (DECISIONS D-LIB2-003).
    # La clôture elle-même se lit sur les périodes du socle.
    class Year < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :year, :int, unique: true
      field :transmitted_at, :date_time, null: true, blank: true
      field :transmitted_by_id, :big_int, null: true, blank: true
      field :reference, :string, max_size: 128, blank: true, default: ""
      field :transmitted_fingerprint, :string, max_size: 64, blank: true, default: ""
      field :frozen_fingerprint, :string, max_size: 64, blank: true, default: ""
      field :frozen_at, :date_time, null: true, blank: true
    end

    # Facture émise, relevée à `invoice.issued` (charge utile seule, sans
    # appel à la Facturation) : de quoi inscrire la recette à l'encaissement.
    class Invoice < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :invoice_id, :big_int, unique: true
      field :number, :string, max_size: 40, blank: true, default: ""
      field :card_id, :big_int, null: true, blank: true
    end
  end
end
