# Crystal — `String#encode(…, invalid: :skip)` perd un octet tous les 1 024 octets

Blocage : `BLOCAGES.adoc` B-ED-001 (lot 3, éditions). Contournement en place :
encodage ISO 8859-15 écrit par Partiduo pour le FEC (DECISIONS D-ED-008).
Ticket **à ouvrir par le mainteneur** sur <https://github.com/crystal-lang/crystal/issues>
(non ouvert par l'agent).

## Constat

Avec `invalid: :skip`, `String#encode` perd un octet *valide* à chaque fois
que le tampon de sortie de 1 024 octets se remplit : un texte entièrement
représentable dans l'encodage cible ressort tronqué. Sans `invalid:`, le même
texte s'encode correctement.

Reproduit le 29 septembre 2026 avec Crystal 1.19.1 et 1.21.1 (macOS 26,
arm64, iconv du système).

## Cause probable

`String.encode` (`src/string.cr`) appelle `iconv` avec un tampon de sortie de
1 024 octets. Quand ce tampon est plein, `iconv` rend `-1` avec
`errno = E2BIG` ; le code appelle alors `Crystal::Iconv#handle_invalid`, qui,
en mode `skip`, avance d'un octet dans l'entrée *quel que soit* `errno`
(`src/crystal/iconv.cr`). L'octet sauté est un octet valide qui n'a pas
encore été converti. Le correctif consiste à ne sauter un octet que pour
`EILSEQ` (et `EINVAL` en fin d'entrée), jamais pour `E2BIG`.

## Reproduction minimale

```crystal
text = String.build do |io|
  200.times do |i|
    io << "20240101|VT|Ventes|" << i.to_s.rjust(6, '0') << "|Libellé é à ç|1234,56|0,00|\n"
  end
end
plain = text.encode("ISO-8859-15")
skipped = text.encode("ISO-8859-15", invalid: :skip)
puts "encode:        #{plain.size} bytes"
puts "encode(skip):  #{skipped.size} bytes"
puts "equal:         #{plain == skipped}"
index = plain.each_with_index.find { |(byte, i)| skipped[i]? != byte }.try(&.[1])
puts "first difference at byte #{index}"
```

Sortie :

```
encode:        10800 bytes
encode(skip):  10790 bytes
equal:         false
first difference at byte 1024
```

## Texte du ticket (en anglais)

**Title:** `String#encode(..., invalid: :skip)` drops one valid byte every 1024 output bytes

**Body:**

> `String#encode` with `invalid: :skip` loses data on inputs that are
> entirely valid in the target encoding: one byte disappears every time the
> internal 1024-byte output buffer fills up. Without `invalid:` the same
> input encodes correctly.
>
> Reproduced with Crystal 1.19.1 and 1.21.1 on macOS (arm64, system iconv).
>
> ```crystal
> text = String.build do |io|
>   200.times do |i|
>     io << "20240101|VT|Ventes|" << i.to_s.rjust(6, '0') << "|Libellé é à ç|1234,56|0,00|\n"
>   end
> end
> plain = text.encode("ISO-8859-15")
> skipped = text.encode("ISO-8859-15", invalid: :skip)
> p plain.size    # => 10800
> p skipped.size  # => 10790 (expected 10800)
> ```
>
> The first difference is at byte 1024: the `|` right before the buffer
> boundary is missing.
>
> **Likely cause:** in `String.encode` (`src/string.cr`), when
> `iconv.convert` returns `ERROR` because the output buffer is full
> (`errno == E2BIG`), `Crystal::Iconv#handle_invalid` is still called and, in
> skip mode, unconditionally advances the input pointer by one byte
> (`src/crystal/iconv.cr`). `E2BIG` is not an invalid sequence; the byte is
> valid and has not been converted yet.
>
> **Suggested fix:** only skip input bytes for `EILSEQ` (and `EINVAL`), e.g.
> check `Errno.value` in `handle_invalid` before skipping, or handle `E2BIG`
> in `String.encode` by flushing the buffer and continuing. `IO` encoding
> (`IO::Encoder`) may deserve the same check.
>
> **Expected:** `text.encode("ISO-8859-15", invalid: :skip) == text.encode("ISO-8859-15")`
> for any text fully representable in ISO-8859-15.
