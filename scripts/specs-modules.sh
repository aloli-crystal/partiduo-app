#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Lance les specs dans les trois configurations de modules de l'ADR-006 D7,
# comme la CI. Base de test : DATABASE_URL (défaut postgres:///partiduo_test?host=/tmp).
set -eu

cd "$(dirname "$0")/.."
: "${DATABASE_URL:=postgres:///partiduo_test?host=/tmp}"
export DATABASE_URL

for modules in "accounting,analytic" "invoicing" "accounting,invoicing,analytic"; do
  echo "== PARTIDUO_MODULES=$modules"
  PARTIDUO_MODULES="$modules" crystal spec "$@"
done
