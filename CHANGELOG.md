# Changelog

## 1.0.0 - 2026-06-05

Cabbage graduates to `1.0.0`. The internals are a ground-up rewrite onto a
spec-conformant Gherkin pipeline and a cucumber-messages runner, but the
**public macro API you write against is unchanged** — see "Unchanged" below.

### Breaking

- **Elixir floor raised** from `~> 1.13` to `~> 1.18`. Cabbage now relies on
  the built-in `JSON` module (Elixir 1.18+) and drops the `jason`/`excoveralls`
  dependencies entirely.
- **Requires gherkin `~> 3.0`.** The runner consumes the rewritten gherkin
  pipeline (`Gherkin.parse!/2` + `Gherkin.pickles/2`); gherkin `2.x` will not
  work.
- **Non-standard "valued" tags are rejected.** Tags like `@timeout 100` are not
  valid Gherkin and now raise a parse error. Use a plain tag (`@timeout`) plus
  step/config logic, or split the value into its own construct.
- **Background steps now EXECUTE.** Previously `Background` steps were silently
  broken and effectively skipped; they are now prepended to every scenario in
  the feature (via pickle expansion), matching Cucumber semantics. Features that
  relied on Background being a no-op may now run those steps.
- **Internal struct modules renamed:** `Gherkin.Elements.*` →
  `Cabbage.Feature.{Document, Scenario, Step}`. This only affects code that
  pattern-matched on Cabbage/Gherkin internals; step-definition code is
  unaffected.

### Unchanged (source-compatible)

- The public macro API is **byte-for-byte unchanged** — existing step
  definitions compile as-is:
  - `use Cabbage.Feature, file: ..., template: ...`
  - `defgiven/2`, `defwhen/2`, `defthen/2`
  - `import_feature/1`, `import_steps/1`, `import_tags/1`
  - `tag/2`

### Added

- **Pickle-based execution.** Background prepending, `Rule` flattening, and
  Scenario Outline expansion now come "for free" from the gherkin pickle
  compiler instead of bespoke Cabbage logic.
- **Full Cucumber Expressions engine** (`{int}`, `{word}`, `{string}`,
  custom/optional/alternation), validated at **115/115** against the upstream
  cucumber-expressions conformance corpus.
- **Tag Expressions engine** (`and`/`or`/`not`/parentheses), validated at
  **64/64** against the upstream tag-expressions corpus.
- **cucumber-messages runner** (`Cabbage.Messages`) with hooks, attachments,
  retry, and parameter-types support — validated at **43/44** against the
  Cucumber Compatibility Kit (CCK) (the 44th asserts a run-level crash and is
  deferred as `unsupported`).
- **Opt-in ambiguous-step handling** via `on_ambiguous_step:` in
  `@feature_options` (default preserves prior last-match-wins behaviour).

See [UPGRADING.md](UPGRADING.md) for a 0.4.1 → 1.0.0 migration guide.

### v0.4.1

- Updated dependencies, remove dependency on retired `gherkin 1.6.1`

### v0.4.0

- Support for new Elixir versions >= 1.13

### v0.3.4-dev

- Support for Elixir 1.7 #50.

### v0.3.3

- Support for Elixir 1.5 #38. Thanks to @lboekhorst and @rawkode

### v0.3.2

- Fix for improper state tracking #33. Thanks to @lboekhorst

### v0.3.1

- Better support for missing steps (produces the pattern match for the given missing data). #26 Thanks to @shdblowers
- Breaks `import_feature/1` into two separate macros for more explicit control. Issue #21. Thanks for @hisapy for the
  suggestion.

### v0.3.0

- Support for running specific tests #15 on a specific line number.
- Bug fix #19 Thanks to @rawkode - Defaulting steps and tags to empty list when get_attributes returns nil
- Missing step advisor improvements #14 Thanks to @shdblowers
- Data tables and doc strings are now available in the variables under the `:table` and `:doc_string` keys

### v0.2.2

- Support for ExUnit case templates. Simply specify the case template module name like
  `use Cabbage, template: MyApp.ConnCase, feature: "some_file.feature"`
- Support for tags as ExUnit setup callbacks.

### v0.2.1

- Bug fix #9 Thanks to @shdblowers - Fixes updating of state properly from one step to the next

### v0.2.0

- Support for Scenario Outlines. Scenario Outlines are supported by expanding them into
  basic scenarios by filling in all variables. The name of each scenario is appended to have
  `(Example x)` where `x` is the row from the `Examples` block in the Scenario Outline. See
  https://github.com/cabbage-ex/cabbage/blob/master/test/outline_test.exs for an example.

### v0.1.0

- Initial features to run a simple scenario with variable matching and state tracking.
