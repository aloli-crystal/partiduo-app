# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Vat
    # Taux de TVA, héritier de `tva_rate` (et de la vue `v_tva_rate`).
    #
    # * `code` : code court (`tva_code`), lettres et chiffres, au moins une
    #   lettre, cinq caractères au plus ;
    # * `rate` : taux en *pourcentage* (`20.0000`), et non en fraction comme
    #   `tva_rate.tva_rate` (`0.2000`) ;
    # * `reverse_charge` : autoliquidation (`tva_both_side`) ;
    # * `sale_on_payment`, `purchase_on_payment` : exigibilité à l'encaissement
    #   (`tva_payment_sale`, `tva_payment_purchase` = `P`) plutôt qu'à
    #   l'opération (`O`) ;
    # * `category` : catégorie de TVA de la facture électronique (UNCL5305 :
    #   `S`, `Z`, `E`, `AE`, `K`, `G`, `O`, `L`, `M` — `tva_peppol_code`) ;
    # * `exemption_code`, `exemption_reason` : motif d'exonération (code VATEX,
    #   `vx_code`, ou texte libre), exigé par l'EN 16931 pour `E`, `AE`, `K`,
    #   `G` et `O`.
    #
    # Les comptes de TVA (`tva_poste`) relèvent de la Comptabilité, qui les
    # rattache au taux par son identifiant : le socle ne cite pas le module.
    class Rate < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :code, :string, max_size: 5, unique: true
      field :label, :string, max_size: 64
      field :rate, :decimal, max_digits: 7, decimal_places: 4
      field :description, :text, blank: true, default: ""
      field :category, :string, max_size: 2
      field :exemption_code, :string, max_size: 32, blank: true, default: ""
      field :exemption_reason, :string, max_size: 255, blank: true, default: ""
      field :reverse_charge, :bool, default: false
      field :sale_on_payment, :bool, default: false
      field :purchase_on_payment, :bool, default: false
      field :enabled, :bool, default: true

      with_timestamp_fields
    end
  end
end
