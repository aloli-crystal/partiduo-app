# Marten — champs déclarés après `db_unique_constraint` ignorés

Blocage : `BLOCAGES.adoc` B-REF-001 (lot 1, socle-référentiel). Contournement
en place : les champs sont toujours déclarés avant les contraintes (DECISIONS
D-REF-014). Ticket **à ouvrir par le mainteneur** sur
<https://github.com/martenframework/marten/issues> (non ouvert par l'agent).

## Constat

Dans un modèle, un champ déclaré *après* `db_unique_constraint` (par exemple
par `with_timestamp_fields`) n'apparaît pas parmi les champs du modèle :
l'enregistrement lève `Unknown field 'created_at'`
(`Marten::DB::Errors::UnknownField`).

Reproduit le 29 septembre 2026 avec Marten 0.7.0 et Crystal 1.19.1.

## Cause probable

`db_unique_constraint` résout les champs cités par `get_field`, qui construit
et *mémorise* `@@field_contexts_map` (`src/marten/db/model/table.cr`). Les
champs enregistrés ensuite par `register_field` sont ajoutés à
`@@local_fields`, mais la table mémorisée n'est jamais invalidée : `fields`,
`get_field` et la lecture des valeurs les ignorent. Le correctif consiste à
remettre `@@field_contexts_map` à `nil` dans `register_field` (et
`@@reverse_relation_contexts` dans `register_reverse_relation`), ou à ne
résoudre les champs des contraintes qu'au moment où elles sont lues.

## Reproduction minimale

Sans base de données : il suffit de lister les champs.

```crystal
require "marten"

class FieldsFirst < Marten::Model
  field :id, :big_int, primary_key: true, auto: true
  field :code, :string, max_size: 10
  with_timestamp_fields
  db_unique_constraint :fields_first_code, field_names: [:code]
end

class ConstraintFirst < Marten::Model
  field :id, :big_int, primary_key: true, auto: true
  field :code, :string, max_size: 10
  db_unique_constraint :constraint_first_code, field_names: [:code]
  with_timestamp_fields
end

puts FieldsFirst.fields.map(&.id).join(", ")
puts ConstraintFirst.fields.map(&.id).join(", ")
```

Sortie :

```
id, code, created_at, updated_at
id, code
```

## Texte du ticket (en anglais)

**Title:** Fields declared after `db_unique_constraint` are ignored by the model

**Body:**

> When a model declares a field after a `db_unique_constraint` (for example
> through `with_timestamp_fields`), the field is silently dropped from the
> model's field list: `Model.fields` does not return it and saving a record
> raises `Marten::DB::Errors::UnknownField: Unknown field 'created_at'`.
>
> Marten 0.7.0, Crystal 1.19.1.
>
> ```crystal
> require "marten"
>
> class ConstraintFirst < Marten::Model
>   field :id, :big_int, primary_key: true, auto: true
>   field :code, :string, max_size: 10
>   db_unique_constraint :constraint_first_code, field_names: [:code]
>   with_timestamp_fields
> end
>
> p ConstraintFirst.fields.map(&.id) # => ["id", "code"]
> # expected ["id", "code", "created_at", "updated_at"]
> ```
>
> Declaring the same fields before the constraint works.
>
> **Likely cause:** `db_unique_constraint` resolves its fields with
> `get_field`, which builds and memoizes `@@field_contexts_map`
> (`src/marten/db/model/table.cr`). Fields registered afterwards by
> `register_field` go into `@@local_fields`, but the memoized map is never
> invalidated, so `fields`, `get_field` and value accessors do not see them.
>
> **Suggested fix:** reset `@@field_contexts_map` (and
> `@@reverse_relation_contexts` in `register_reverse_relation`) when a field
> is registered, or resolve constraint fields lazily. Alternatively, raise a
> clear error when a field is declared after a constraint.
