# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Cards
    # Unités de mesure des articles et services : codes de la recommandation
    # UN/ECE n° 20 (et n° 21 pour les colis), ceux qu'attend l'EN 16931
    # (`BT-130`, facture Factur-X). Liste retenue : les unités courantes d'une
    # facture de biens et de services ; libellés `cards.units.<code>`.
    module Units
      CODES = %w[
        C62 H87 EA XPP SET PR DZN XBX XPK
        LS E48
        SEC MIN HUR DAY WEE MON ANN
        KGM GRM MGM TNE
        MTR CMT MMT KMT MTK MTQ LTR MLT CLT
        KWH MWH KWT
        P1
      ]

      # Unité par défaut d'un article (« une unité »).
      DEFAULT = "C62"

      def self.valid?(code : String) : Bool
        CODES.includes?(code)
      end
    end
  end
end
