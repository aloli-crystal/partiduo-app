# SPDX-License-Identifier: AGPL-3.0-or-later

require "pg/pg_ext/big_decimal"

# Correctif de `PG::Numeric#to_big_d` (crystal-pg) : un `numeric` dont le
# dernier groupe de 4 chiffres significatif est à gauche de la virgule
# (10 000, 20 000 000…) donne une échelle négative, et `BigDecimal.new` lève
# `OverflowError`. Tout montant multiple de 10 000 serait illisible.
# Voir BLOCAGES.adoc (B-SET-001) ; à retirer quand crystal-pg sera corrigé.
struct PG::Numeric
  def to_big_d
    return BigDecimal.new(0, 0) if nan? || ndigits == 0

    ten_k = BigInt.new(10_000)
    num = digits.reduce(BigInt.new(0)) { |acc, group| acc * ten_k + BigInt.new(group) }
    scale = 4 * (ndigits - 1 - weight)
    value = if scale >= 0
              BigDecimal.new(num, scale)
            else
              BigDecimal.new(num * BigInt.new(10) ** (-scale), 0)
            end
    neg? ? -value : value
  end
end
