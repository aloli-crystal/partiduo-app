# SPDX-License-Identifier: AGPL-3.0-or-later

# Précision des dates-heures : PostgreSQL conserve les `timestamp` à la
# microseconde, alors que `Time` est à la nanoseconde sous Linux. Sans
# correctif, un enregistrement relu après sauvegarde diffère de celui gardé
# en mémoire (vue renvoyée par une commande ≠ vue relue par une requête).
# Toute valeur `date_time` — horodatage automatique compris — est donc
# ramenée à la microseconde avant l'écriture.
class Marten::DB::Field::DateTime
  def prepare_save(record, new_record = false)
    if @auto_now || (@auto_now_add && new_record)
      record.set_field_value(id, Time.local)
    end
    value = record.get_field_value(id)
    record.set_field_value(id, Partiduo.to_microseconds(value)) if value.is_a?(Time)
  end
end

module Partiduo
  # `time` tronqué à la microseconde, précision de PostgreSQL.
  def self.to_microseconds(time : Time) : Time
    time - (time.nanosecond % 1_000).nanoseconds
  end
end
