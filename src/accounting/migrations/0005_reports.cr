# SPDX-License-Identifier: AGPL-3.0-or-later

# Lot 3 — rapports personnalisés (`formulaire`, `form_definition`
# d'origine) : un rapport et ses lignes (libellé et formule), effacées avec
# lui par Marten (`on_delete: :cascade`). Les profils ACCOUNTANT des
# dossiers déjà provisionnés reçoivent la nouvelle permission
# `accounting.report.write`, qu'un profil créé ensuite reçoit d'office
# (D-ED-006) ; le retour arrière la laisse en place (sans effet sans la
# table des rapports).
class Migration::Accounting::V0005 < Marten::Migration
  depends_on :accounting, "0004_billing_sources"
  depends_on :auth, "0002_auth_security"

  def plan
    create_table :accounting_report do
      column :id, :big_int, primary_key: true, auto: true
      column :name, :string, max_size: 100, unique: true
      column :created_by_id, :big_int, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :accounting_report_line do
      column :id, :big_int, primary_key: true, auto: true
      column :position, :int, default: 0
      column :label, :string, max_size: 255
      column :formula, :text
      column :report_id, :reference, to_table: :accounting_report, to_column: :id
    end

    execute(
      "CREATE INDEX accounting_report_line_report ON accounting_report_line (report_id, position)",
      "DROP INDEX IF EXISTS accounting_report_line_report"
    )

    execute(
      "INSERT INTO auth_profile_permission (profile_id, permission) " \
      "SELECT id, 'accounting.report.write' FROM auth_profile WHERE code = 'ACCOUNTANT' " \
      "ON CONFLICT (profile_id, permission) DO NOTHING",
      "SELECT 1"
    )
  end
end
