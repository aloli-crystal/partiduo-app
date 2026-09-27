#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Lance les specs dans les trois configurations de modules de l'ADR-006 D7,
# comme la CI. Base de test : DATABASE_URL (défaut postgres:///partiduo_test?host=/tmp).
set -eu

cd "$(dirname "$0")/.."
: "${DATABASE_URL:=postgres:///partiduo_test?host=/tmp}"
export DATABASE_URL

# Le Stock et le Suivi (lot 6) suivent chaque configuration : le Stock y
# trouve toujours la Facturation ou la Comptabilité (D-STK-001).
for modules in "accounting,analytic,stock,followup" "invoicing,stock,followup" \
  "accounting,invoicing,analytic,stock,followup"; do
  echo "== PARTIDUO_MODULES=$modules"
  PARTIDUO_MODULES="$modules" crystal spec "$@"
done
