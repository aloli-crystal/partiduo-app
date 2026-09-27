# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Vat
    module Fr
      # Taux français chargés au provisionnement (d'après `mod2/data.sql`,
      # `tva_rate`, mis à jour : taux intermédiaire de 10 %, taux de Corse en
      # vigueur ; les taux historiques ne sont pas repris). Libellés traduits
      # dans la langue du dossier : `vat.initial.fr.<code>`.
      RATES = [
        Partiduo::Api::Vat::RateInput.new(code: "NOR", label: "vat.initial.fr.nor", rate: BigDecimal.new("20")),
        Partiduo::Api::Vat::RateInput.new(code: "INT", label: "vat.initial.fr.int", rate: BigDecimal.new("10")),
        Partiduo::Api::Vat::RateInput.new(code: "TR55", label: "vat.initial.fr.tr55", rate: BigDecimal.new("5.5")),
        Partiduo::Api::Vat::RateInput.new(code: "TP021", label: "vat.initial.fr.tp021", rate: BigDecimal.new("2.1")),
        Partiduo::Api::Vat::RateInput.new(code: "DNOR", label: "vat.initial.fr.dnor", rate: BigDecimal.new("8.5")),
        Partiduo::Api::Vat::RateInput.new(code: "DR", label: "vat.initial.fr.dr", rate: BigDecimal.new("2.1")),
        Partiduo::Api::Vat::RateInput.new(code: "DPRS", label: "vat.initial.fr.dprs", rate: BigDecimal.new("1.05")),
        Partiduo::Api::Vat::RateInput.new(code: "COR13", label: "vat.initial.fr.cor13", rate: BigDecimal.new("13")),
        Partiduo::Api::Vat::RateInput.new(code: "COR09", label: "vat.initial.fr.cor09", rate: BigDecimal.new("0.9")),
        Partiduo::Api::Vat::RateInput.new(code: "EXP", label: "vat.initial.fr.exp", rate: BigDecimal.new("0"),
          category: "G", exemption_code: "VATEX-EU-G"),
        Partiduo::Api::Vat::RateInput.new(code: "INTL", label: "vat.initial.fr.intl", rate: BigDecimal.new("0"),
          category: "K", exemption_code: "VATEX-EU-IC"),
        Partiduo::Api::Vat::RateInput.new(code: "AUTOL", label: "vat.initial.fr.autol", rate: BigDecimal.new("0"),
          category: "AE", exemption_code: "VATEX-EU-AE", reverse_charge: true),
        Partiduo::Api::Vat::RateInput.new(code: "INTS", label: "vat.initial.fr.ints", rate: BigDecimal.new("20"),
          category: "AE", exemption_code: "VATEX-EU-AE", reverse_charge: true),
        Partiduo::Api::Vat::RateInput.new(code: "FRANC", label: "vat.initial.fr.franc", rate: BigDecimal.new("0"),
          category: "E", exemption_code: "VATEX-FR-FRANCHISE"),
      ]
    end
  end
end
