# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Core
    # Exercice comptable, héritier de `parm_periode.p_exercice` et
    # `p_exercice_label` : dans NOALYSS l'exercice n'est qu'une colonne des
    # périodes ; il devient une ligne, à qui appartiennent ses périodes.
    #
    # `year` : numéro d'exercice (entre 1900 et 2100, `COMPTA_MIN_YEAR` et
    # `COMPTA_MAX_YEAR`), `label` : libellé. Tous deux uniques : le déclencheur
    # `comptaproc.check_periode` interdisait qu'un libellé porte deux
    # exercices, ou un exercice deux libellés. Modèle interne : l'interface
    # passe par `Partiduo::Api::Core` (`fiscal_years`, `create_fiscal_year`…).
    class FiscalYear < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :year, :int, unique: true
      field :label, :string, max_size: 64, unique: true
      # Clôture de l'exercice : toutes ses périodes sont closes et aucune ne
      # peut plus être rouverte ni ajoutée.
      field :closed_at, :date_time, null: true, blank: true
      field :closed_by_id, :big_int, null: true, blank: true

      with_timestamp_fields
    end

    # Période d'un exercice, héritière de `parm_periode` : bornes incluses,
    # clôture (`p_closed`). Deux périodes ne se chevauchent jamais — contrainte
    # d'exclusion en base (migration `0002`), comme le contrôle de
    # `Periode::insert`. L'état par journal (`jrn_periode`) relève de la
    # Comptabilité.
    class Period < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :fiscal_year, :many_to_one, to: Partiduo::Core::FiscalYear, related: :periods
      field :starts_on, :date
      field :ends_on, :date
      field :closed_at, :date_time, null: true, blank: true
      field :closed_by_id, :big_int, null: true, blank: true

      with_timestamp_fields

      def closed? : Bool
        !closed_at.nil?
      end
    end
  end
end
