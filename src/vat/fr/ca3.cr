# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Vat
    module Fr
      alias Box = Returns::Box
      alias DefaultRule = Returns::DefaultRule

      # Cases communes à la CA3 (régime réel normal, formulaire 3310-CA3) et à
      # la CA12 (régime simplifié, 3517-S) : montant des opérations réalisées
      # (cadre A), TVA brute par taux (base et taxe), TVA déductible. Les
      # opérations imposables aux taux particuliers (DOM hors 8,5 et 2,1 %,
      # Corse, 2,1 % métropole, presse) sont regroupées en ligne 14 (détail
      # de l'annexe 3310-A non repris, D-TVA-006).
      OPERATIONS = [
        Box.new("A1", "fr.operations"), Box.new("A2", "fr.operations"), Box.new("A3", "fr.operations"),
        Box.new("A4", "fr.operations"), Box.new("A5", "fr.operations"), Box.new("B2", "fr.operations"),
        Box.new("B4", "fr.operations"), Box.new("B5", "fr.operations"),
        Box.new("E1", "fr.exempt"), Box.new("E2", "fr.exempt"), Box.new("F2", "fr.exempt"),
        Box.new("F6", "fr.exempt"),
      ]

      RATE_LINES = %w[08 09 9B 10 11 13 14]

      GROSS = RATE_LINES.flat_map { |line| [Box.new("#{line}.base", "fr.gross"), Box.new("#{line}.tax", "fr.gross")] } + [
        Box.new("15", "fr.gross"),
        Box.new("16", "fr.gross", ruled: false, total: true),
        Box.new("17", "fr.gross"),
      ]

      DEDUCTIBLE = [
        Box.new("19", "fr.deductible"), Box.new("20", "fr.deductible"), Box.new("21", "fr.deductible"),
        Box.new("22", "fr.deductible", ruled: false),
        Box.new("23", "fr.deductible", ruled: false, total: true),
      ]

      # Taux soumis à la TVA du jeu initial français.
      TAXED = %w[NOR INT TR55 TP021 DNOR DR DPRS DOM1 COR13 COR09]

      # Paramétrage par défaut (codes du jeu initial français, D-REF-009) :
      # ventes par taux, exportations (E1), autoliquidation par le client
      # (E2), livraisons intracommunautaires (F2), acquisitions
      # intracommunautaires autoliquidées (B2, ligne 08, ligne 17), TVA
      # déductible sur immobilisations (comptes 2, ligne 19) et sur les autres
      # biens et services (ligne 20).
      DEFAULT_RULES = [
        DefaultRule.new("A1", TAXED, "sale", "base"),
        DefaultRule.new("B2", %w[INTS], "purchase", "base"),
        DefaultRule.new("E1", %w[EXP], "sale", "base"),
        DefaultRule.new("E2", %w[AUTOL], "sale", "base"),
        DefaultRule.new("F2", %w[INTL], "sale", "base"),
        DefaultRule.new("08.base", %w[NOR], "sale", "base"),
        DefaultRule.new("08.base", %w[INTS], "purchase", "base"),
        DefaultRule.new("08.tax", %w[NOR], "sale", "collected"),
        DefaultRule.new("08.tax", %w[INTS], "purchase", "collected"),
        DefaultRule.new("09.base", %w[TR55], "sale", "base"),
        DefaultRule.new("09.tax", %w[TR55], "sale", "collected"),
        DefaultRule.new("9B.base", %w[INT], "sale", "base"),
        DefaultRule.new("9B.tax", %w[INT], "sale", "collected"),
        DefaultRule.new("10.base", %w[DNOR], "sale", "base"),
        DefaultRule.new("10.tax", %w[DNOR], "sale", "collected"),
        DefaultRule.new("11.base", %w[DR], "sale", "base"),
        DefaultRule.new("11.tax", %w[DR], "sale", "collected"),
        DefaultRule.new("14.base", %w[TP021 DPRS DOM1 COR13 COR09], "sale", "base"),
        DefaultRule.new("14.tax", %w[TP021 DPRS DOM1 COR13 COR09], "sale", "collected"),
        DefaultRule.new("17", %w[INTS], "purchase", "collected"),
        DefaultRule.new("19", nil, "purchase", "deductible", accounts: "2"),
        DefaultRule.new("20", nil, "purchase", "deductible", excluded_accounts: "2"),
      ]

      # TVA brute (16) et TVA déductible (23), communes aux deux formulaires.
      def self.gross_and_deductible!(amounts : Hash(String, BigDecimal)) : {BigDecimal, BigDecimal}
        get = ->(code : String) { amounts[code]? || Returns::ZERO }
        gross = RATE_LINES.sum(Returns::ZERO) { |line| get.call("#{line}.tax") } + get.call("15")
        deductible = %w[19 20 21 22].sum(Returns::ZERO) { |code| get.call(code) }
        amounts["16"] = gross
        amounts["23"] = deductible
        {gross, deductible}
      end

      # Déclaration mensuelle ou trimestrielle du régime réel normal.
      module Ca3
        BOXES = OPERATIONS + GROSS + DEDUCTIBLE + [
          Box.new("25", "fr.result", ruled: false, total: true),
          Box.new("26", "fr.result", ruled: false),
          Box.new("27", "fr.result", ruled: false, total: true),
          Box.new("28", "fr.result", ruled: false, total: true),
          Box.new("29", "fr.result", ruled: false),
          Box.new("32", "fr.result", ruled: false, total: true),
        ]

        # 25 crédit (23 − 16), 27 crédit à reporter (25 − 26), 28 TVA nette
        # due (16 − 23), 32 total à payer (28 + 29).
        def self.totals!(amounts : Hash(String, BigDecimal)) : Nil
          gross, deductible = Fr.gross_and_deductible!(amounts)
          credit = Returns.positive(deductible - gross)
          net = Returns.positive(gross - deductible)
          amounts["25"] = credit
          amounts["27"] = Returns.positive(credit - (amounts["26"]? || Returns::ZERO))
          amounts["28"] = net
          amounts["32"] = net + (amounts["29"]? || Returns::ZERO)
          nil
        end
      end

      # Déclaration annuelle du régime simplifié : mêmes lignes de calcul,
      # puis acomptes versés (`ac`, saisis), solde à payer (`sp`) ou
      # excédent de versements (`ex`) (D-TVA-006).
      module Ca12
        BOXES = OPERATIONS + GROSS + DEDUCTIBLE + [
          Box.new("25", "fr.result", ruled: false, total: true),
          Box.new("28", "fr.result", ruled: false, total: true),
          Box.new("29", "fr.result", ruled: false),
          Box.new("ac", "fr.result", ruled: false),
          Box.new("sp", "fr.result", ruled: false, total: true),
          Box.new("ex", "fr.result", ruled: false, total: true),
        ]

        def self.totals!(amounts : Hash(String, BigDecimal)) : Nil
          gross, deductible = Fr.gross_and_deductible!(amounts)
          net = Returns.positive(gross - deductible)
          amounts["25"] = Returns.positive(deductible - gross)
          amounts["28"] = net
          due = net + (amounts["29"]? || Returns::ZERO)
          paid = amounts["ac"]? || Returns::ZERO
          amounts["sp"] = Returns.positive(due - paid)
          amounts["ex"] = Returns.positive(paid - due)
          nil
        end
      end
    end
  end
end
