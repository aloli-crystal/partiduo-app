# SPDX-License-Identifier: AGPL-3.0-or-later

# Lot 4 (relecture) : un seul brouillon par formulaire et par période,
# garanti en base (la création vérifie aussi, sous verrou par régime).
class Migration::Vat::V0003 < Marten::Migration
  depends_on :vat, "0002_vat_returns"

  def plan
    execute(
      "CREATE UNIQUE INDEX vat_return_draft_unique ON vat_return (form, date_from, date_to) WHERE status = 'draft'",
      "DROP INDEX IF EXISTS vat_return_draft_unique"
    )
  end
end
