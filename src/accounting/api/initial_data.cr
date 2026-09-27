# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    module Accounting
      # Charge le plan comptable (PCMN belge ou PCG français, repris de
      # NOALYSS), les comptes par défaut, le compte de base des catégories de
      # fiches par défaut du socle et les quatre journaux (achats,
      # ventes, financier, opérations diverses) du régime, noms des journaux
      # dans `locale`. Appelé par `partiduo-provision` (chargeur
      # `ACCOUNTING.reference_data`) ; refusé si le plan n'est pas vide.
      def self.load_initial_data(actor : Actor, regime : String, locale : String = "fr") : Result(InitialDataView)
        Guard.authorize!(actor, "accounting.account.write", module_code: MODULE_CODE)
        Guard.authorize!(actor, "accounting.ledger.write", module_code: MODULE_CODE)
        Transaction.run do
          unless Partiduo::Accounting::ReferenceData.regimes.includes?(regime)
            next Result(InitialDataView).failure(FieldError.new("regime", "accounting.errors.initial_data.regime.invalid"))
          end
          if Partiduo::Accounting::Account.all.exists? || Partiduo::Accounting::Ledger.all.exists?
            next Result(InitialDataView).failure(FieldError.base("accounting.errors.initial_data.not_empty"))
          end
          Result(InitialDataView).success(Partiduo::Accounting::ReferenceData.load(actor, regime, locale))
        end
      end
    end
  end
end
