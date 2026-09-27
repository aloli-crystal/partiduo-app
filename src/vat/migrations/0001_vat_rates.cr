# SPDX-License-Identifier: AGPL-3.0-or-later

# Lot 1 : taux de TVA (successeur de `tva_rate`). Contraintes reprises de
# NOALYSS (`tva_code_number_check` : un code n'est pas qu'un nombre) et de
# `Tva_Rate_MTable::check` (taux borné, libellé unique sans tenir compte de la
# casse), plus les catégories UNCL5305 de l'EN 16931.
class Migration::Vat::V0001 < Marten::Migration
  def plan
    create_table :vat_rate do
      column :id, :big_int, primary_key: true, auto: true
      column :code, :string, max_size: 5, unique: true
      column :label, :string, max_size: 64
      column :rate, :decimal, max_digits: 7, decimal_places: 4
      column :description, :text, default: ""
      column :category, :string, max_size: 2
      column :exemption_code, :string, max_size: 32, default: ""
      column :exemption_reason, :string, max_size: 255, default: ""
      column :reverse_charge, :bool, default: false
      column :sale_on_payment, :bool, default: false
      column :purchase_on_payment, :bool, default: false
      column :enabled, :bool, default: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    execute(<<-SQL)
        ALTER TABLE vat_rate
          ADD CONSTRAINT vat_rate_code_check CHECK (code ~ '^[A-Z0-9]{1,5}$' AND code !~ '^[0-9]+$'),
          ADD CONSTRAINT vat_rate_rate_check CHECK (rate >= 0 AND rate <= 100),
          ADD CONSTRAINT vat_rate_label_check CHECK (btrim(label) <> ''),
          ADD CONSTRAINT vat_rate_category_check CHECK (category IN ('S', 'Z', 'E', 'AE', 'K', 'G', 'O', 'L', 'M'))
      SQL
    execute(<<-SQL)
        CREATE UNIQUE INDEX vat_rate_label_unique ON vat_rate (lower(label))
      SQL
  end
end
