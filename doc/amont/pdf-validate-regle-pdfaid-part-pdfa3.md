# pdf-validate — la règle PDF/A-3 `pdfa3-6.6.4-pdfaid-part-2` exige `pdfaid:part = 2`

Blocage : `BLOCAGES.adoc` B-INV-001 (lot F, facturation). Contournement en
place : `Partiduo::Invoicing::Output::IGNORED_RULES` écarte cette seule règle ;
les specs vérifient `<pdfaid:part>3</pdfaid:part>`. Ticket **à ouvrir par le
mainteneur** sur le dépôt de `pdf-validate` (non ouvert par l'agent ; le
dépôt `prod-crystal/pdf-validate` ne se modifie pas ici).

## Constat

Dans `pdf-validate` 0.47.0, `rules/pdf-a-3b.yml` déclare :

```yaml
- id: pdfa3-6.6.4-pdfaid-part-2
  clause: "ISO 19005-3 § 6.6.4"
  title: "Declared PDF/A part is 2"
  severity: error
  check: xmp_property_equals
  args: ["pdfaid:part", "2"]
```

Un PDF/A-3 déclare `pdfaid:part = 3` (ISO 19005-3 § 6.6.4) : *tout* PDF/A-3
conforme échoue à cette règle, qui semble recopiée du profil PDF/A-2.

Reproduit le 29 septembre 2026 avec `pdf-validate` 0.47.0 et `pdf-a`
(`prod-crystal/pdf-a`), Crystal 1.19.1.

## Reproduction minimale

```crystal
require "pdf-a"
require "pdf-validate"

document = PDF::A::Document.new(PDF::A::Profile::A_3B)
document.title = "PDF/A-3b sample"
document.page(595.28, 841.89) { }
bytes = document.to_slice

puts String.new(bytes).scrub.scan(/<pdfaid:part>(\d)<\/pdfaid:part>/).map(&.[1]).join(", ")
PDF::Validate.bytes(bytes, profile: "pdf-a-3b").fatal_failures.each do |failure|
  puts "FAILED #{failure.rule.id}: #{failure.rule.title}"
end
```

Sortie :

```
3
FAILED pdfa3-6.6.4-pdfaid-part-2: Declared PDF/A part is 2
```

C'est le seul échec : les 64 autres règles fatales du profil passent.

## Texte du ticket (en anglais)

**Title:** PDF/A-3b profile rule `pdfa3-6.6.4-pdfaid-part-2` requires `pdfaid:part = 2`

**Body:**

> In pdf-validate 0.47.0, `rules/pdf-a-3b.yml` contains:
>
> ```yaml
> - id: pdfa3-6.6.4-pdfaid-part-2
>   clause: "ISO 19005-3 § 6.6.4"
>   title: "Declared PDF/A part is 2"
>   check: xmp_property_equals
>   args: ["pdfaid:part", "2"]
> ```
>
> ISO 19005-3 § 6.6.4 requires a PDF/A-3 file to declare `pdfaid:part` = 3,
> so every conforming PDF/A-3 document fails this rule (it looks copied from
> the PDF/A-2 profile). Minimal reproduction with `pdf-a`:
>
> ```crystal
> document = PDF::A::Document.new(PDF::A::Profile::A_3B)
> document.page(595.28, 841.89) { }
> report = PDF::Validate.bytes(document.to_slice, profile: "pdf-a-3b")
> report.fatal_failures.map(&.rule.id) # => ["pdfa3-6.6.4-pdfaid-part-2"]
> ```
>
> The XMP of that file declares `<pdfaid:part>3</pdfaid:part>`; it is the only
> fatal failure.
>
> **Suggested fix:** rename the rule (e.g. `pdfa3-6.6.4-pdfaid-part-3`),
> change its title to "Declared PDF/A part is 3" and its arguments to
> `["pdfaid:part", "3"]`; a spec validating a minimal PDF/A-3b file would
> catch regressions of this kind.
