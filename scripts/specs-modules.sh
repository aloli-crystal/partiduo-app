#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Lance les specs dans les configurations de modules de l'ADR-006 D7 et de
# l'ADR-007, comme la CI. Base de test : DATABASE_URL (défaut postgres:///partiduo_test?host=/tmp).
set -eu

cd "$(dirname "$0")/.."
: "${DATABASE_URL:=postgres:///partiduo_test?host=/tmp}"
export DATABASE_URL

# Le Stock et le Suivi (lot 6) suivent chaque configuration : le Stock y
# trouve toujours la Facturation ou la Comptabilité (D-STK-001). Le module
# micro-entreprise (ADR-007) ajoute trois configurations : seul, avec la
# Facturation, avec la Facturation et la Comptabilité (D-MIC-008) ; le module
# des professions libérales, deux : seul, avec la Comptabilité (D-LIB-006).
for modules in "accounting,analytic,stock,followup" "invoicing,stock,followup" \
  "accounting,invoicing,analytic,stock,followup" "micro" "micro,invoicing" "micro,invoicing,accounting" \
  "liberal" "liberal,accounting"; do
  echo "== PARTIDUO_MODULES=$modules"
  PARTIDUO_MODULES="$modules" crystal spec "$@"
done
