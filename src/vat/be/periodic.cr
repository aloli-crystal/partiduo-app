# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Vat
    module Be
      # Déclaration périodique belge (formulaire 625, grilles de
      # `tva_belge.declaration_amount` et `form_detail`) : cadres II à VII,
      # totaux `xx`, `yy`, solde 71 ou 72 (`Ext_Tva::compute`).
      module Periodic
        alias Box = Returns::Box

        BOXES = [
          Box.new("00", "be.frame2"), Box.new("01", "be.frame2"), Box.new("02", "be.frame2"),
          Box.new("03", "be.frame2"), Box.new("44", "be.frame2"), Box.new("45", "be.frame2"),
          Box.new("46", "be.frame2"), Box.new("47", "be.frame2"), Box.new("48", "be.frame2"),
          Box.new("49", "be.frame2"),
          Box.new("81", "be.frame3"), Box.new("82", "be.frame3"), Box.new("83", "be.frame3"),
          Box.new("84", "be.frame3"), Box.new("85", "be.frame3"), Box.new("86", "be.frame3"),
          Box.new("87", "be.frame3"), Box.new("88", "be.frame3"),
          Box.new("54", "be.frame4"), Box.new("55", "be.frame4"), Box.new("56", "be.frame4"),
          Box.new("57", "be.frame4"), Box.new("61", "be.frame4"), Box.new("63", "be.frame4"),
          Box.new("xx", "be.frame4", ruled: false, total: true),
          Box.new("59", "be.frame5"), Box.new("62", "be.frame5"), Box.new("64", "be.frame5"),
          Box.new("yy", "be.frame5", ruled: false, total: true),
          Box.new("71", "be.frame6", ruled: false, total: true),
          Box.new("72", "be.frame6", ruled: false, total: true),
          Box.new("91", "be.frame7", ruled: false),
        ]

        # Grilles transmises à Intervat (toutes sauf `xx` et `yy`), numéro de
        # grille (`GridNumber`) : `00` → `0`, `01` → `1`…
        def self.grid_number(code : String) : String?
          return if code.in?("xx", "yy")
          code.to_i.to_s
        end

        # Cadre IV (`xx` = 54 + 55 + 56 + 57 + 61 + 63), cadre V (`yy` = 59 +
        # 62 + 64), cadre VI : 71 (dû à l'État) ou 72 (dû par l'État), une
        # seule des deux.
        def self.totals!(amounts : Hash(String, BigDecimal)) : Nil
          get = ->(code : String) { amounts[code]? || Returns::ZERO }
          xx = %w[54 55 56 57 61 63].sum(Returns::ZERO) { |code| get.call(code) }
          yy = %w[59 62 64].sum(Returns::ZERO) { |code| get.call(code) }
          amounts["xx"] = xx
          amounts["yy"] = yy
          amounts["71"] = Returns.positive(xx - yy)
          amounts["72"] = Returns.positive(yy - xx)
          nil
        end
      end

      # Pseudo-cases des relevés (`ASSUJETTI`, `CLINTRA`, `CLINTRAGD`,
      # `CLINTRATR` de `tva_belge.parameter`) : chiffre d'affaires et TVA du
      # listing des clients assujettis ; montants des services (`S`), des
      # livraisons de biens (`L`) et des opérations triangulaires (`T`) du
      # relevé intracommunautaire.
      LISTING_BOXES = %w[listing listing_vat intra_s intra_l intra_t]

      alias DefaultRule = Returns::DefaultRule

      TAXED     = %w[21G 12A 6A]
      PURCHASES = %w[21G 12A 6A 0TVA COC EXP INTL]

      # Paramétrage par défaut, d'après `tva_belge.parameter` et la notice
      # de l'extension (codes des taux du jeu initial belge, D-REF-009) :
      # ventes (cadre II, TVA due 54, à récupérer sur avoirs 64), achats
      # (cadre III : 81 marchandises et approvisionnements, 83 biens
      # d'investissement des classes 20 à 27, 82 tout le reste — services et
      # biens divers ; TVA déductible 59, à reverser sur avoirs 63),
      # acquisitions intracommunautaires et cocontractant autoliquidés (86,
      # 87, 55, 56). Les avoirs sont reconnus au signe (montant négatif) et
      # reportés en positif dans leurs grilles (48, 49, 84, 85). Cases
      # laissées vides : 44, 57, 61, 62, 88, 91 (à paramétrer ou saisir).
      DEFAULT_RULES = [
        DefaultRule.new("00", %w[0TVA], "sale", "base", sign: "positive"),
        DefaultRule.new("01", %w[6A], "sale", "base", sign: "positive"),
        DefaultRule.new("02", %w[12A], "sale", "base", sign: "positive"),
        DefaultRule.new("03", %w[21G], "sale", "base", sign: "positive"),
        DefaultRule.new("45", %w[COC], "sale", "base", sign: "positive"),
        DefaultRule.new("46", %w[INTL], "sale", "base", sign: "positive"),
        DefaultRule.new("47", %w[EXP], "sale", "base", sign: "positive"),
        DefaultRule.new("48", %w[INTL], "sale", "base", sign: "negative", operation: "subtract"),
        DefaultRule.new("49", %w[6A 12A 21G COC EXP 0TVA], "sale", "base", sign: "negative", operation: "subtract"),
        DefaultRule.new("81", nil, "purchase", "base", accounts: "60", sign: "positive"),
        DefaultRule.new("82", nil, "purchase", "base", excluded_accounts: "2,60", sign: "positive"),
        DefaultRule.new("83", nil, "purchase", "base", accounts: "20,21,22,23,24,25,26,27", sign: "positive"),
        DefaultRule.new("84", %w[INTA], "purchase", "base", sign: "negative", operation: "subtract"),
        DefaultRule.new("85", PURCHASES, "purchase", "base", sign: "negative", operation: "subtract"),
        DefaultRule.new("86", %w[INTA], "purchase", "base", sign: "positive"),
        DefaultRule.new("87", %w[COC], "purchase", "base", sign: "positive"),
        DefaultRule.new("54", TAXED, "sale", "collected", sign: "positive"),
        DefaultRule.new("55", %w[INTA], "purchase", "collected", sign: "positive"),
        DefaultRule.new("56", %w[COC], "purchase", "collected", sign: "positive"),
        DefaultRule.new("63", nil, "purchase", "deductible", sign: "negative", operation: "subtract"),
        DefaultRule.new("59", nil, "purchase", "deductible", sign: "positive"),
        DefaultRule.new("64", TAXED, "sale", "collected", sign: "negative", operation: "subtract"),
        DefaultRule.new("listing", %w[21G 12A 6A 0TVA COC], "sale", "base"),
        DefaultRule.new("listing_vat", %w[21G 12A 6A 0TVA COC], "sale", "collected"),
        DefaultRule.new("intra_l", %w[INTL], "sale", "base"),
      ]
    end
  end
end
