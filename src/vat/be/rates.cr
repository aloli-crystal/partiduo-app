# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Vat
    module Be
      # Taux belges chargés au provisionnement (d'après `mod1/data.sql`,
      # `tva_rate`, codes raccourcis à cinq caractères). Libellés traduits dans
      # la langue du dossier : `vat.initial.be.<code>`.
      RATES = [
        Partiduo::Api::Vat::RateInput.new(code: "21G", label: "vat.initial.be.21g", rate: BigDecimal.new("21")),
        Partiduo::Api::Vat::RateInput.new(code: "12A", label: "vat.initial.be.12a", rate: BigDecimal.new("12")),
        Partiduo::Api::Vat::RateInput.new(code: "6A", label: "vat.initial.be.6a", rate: BigDecimal.new("6")),
        Partiduo::Api::Vat::RateInput.new(code: "0TVA", label: "vat.initial.be.0tva", rate: BigDecimal.new("0")),
        Partiduo::Api::Vat::RateInput.new(code: "EXP", label: "vat.initial.be.exp", rate: BigDecimal.new("0"),
          category: "G", exemption_code: "VATEX-EU-G"),
        Partiduo::Api::Vat::RateInput.new(code: "INTL", label: "vat.initial.be.intl", rate: BigDecimal.new("0"),
          category: "K", exemption_code: "VATEX-EU-IC"),
        Partiduo::Api::Vat::RateInput.new(code: "COC", label: "vat.initial.be.coc", rate: BigDecimal.new("0"),
          category: "AE", exemption_code: "VATEX-EU-AE", reverse_charge: true),
        Partiduo::Api::Vat::RateInput.new(code: "INTA", label: "vat.initial.be.inta", rate: BigDecimal.new("21"),
          category: "AE", exemption_code: "VATEX-EU-AE", reverse_charge: true),
      ]
    end
  end
end
