# Vendored test fixtures

## ircdocs/parser-tests

- **Upstream:** https://github.com/ircdocs/parser-tests
- **Commit:** `6b417e666de20ba677b14e0189213b3706009df6` (2023-05-29)
- **Files:** `tests/msg-split.yaml`, `tests/msg-join.yaml`, `tests/userhost-split.yaml`,
  `tests/mask-match.yaml`
- **Licence:** CC0-1.0 (public domain dedication)

The SHA is recorded because "we pass the corpus" means nothing without knowing which
corpus. Anyone can reproduce these files exactly from the commit above.

### Converted from YAML to JSON

The project has zero external SwiftPM dependencies, so there is no YAML parser
available at test time; `JSONDecoder` is in the standard library. The corpus uses only
plain scalars, sequences and maps, so the conversion is lossless.

To regenerate:

```sh
SHA=6b417e666de20ba677b14e0189213b3706009df6
for name in msg-split msg-join userhost-split mask-match; do
  curl -sSfL "https://raw.githubusercontent.com/ircdocs/parser-tests/$SHA/tests/$name.yaml" \
    | ruby -ryaml -rjson -e 'puts JSON.pretty_generate(YAML.safe_load(STDIN.read))' \
    > "$name.json"
done
```

### Deviation from the prompt

Prompt 3 specified `Tests/Fixtures/`. The files live under
`Tests/IRCProtocolTests/Fixtures/` instead, because SwiftPM only bundles resources
declared inside a target's own directory, and loading via `Bundle.module` is more
robust than deriving a path from `#filePath`.

### Known corpus quirks

`msg-join` contains two tests with **identical atoms** — `{"asd": ""}` with a
space-filled trailing — but different accepted outputs: one lists both `@asd` and
`@asd=`, the other only `@asd`. No implementation can pass both by choosing per-test,
so the serializer emits the valueless form for empty values, which appears in both
lists. IRCv3 treats `@a` and `@a=` as equivalent, so nothing is lost.
