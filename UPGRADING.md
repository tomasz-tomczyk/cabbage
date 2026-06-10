# Upgrading cabbage 0.4.1 → 1.0.0

**The headline: your step-definition code does not change.** The public macro
API (`use Cabbage.Feature`, `defgiven/defwhen/defthen`,
`import_feature/import_steps/import_tags`, `tag`) is byte-for-byte the same as
0.4.x. Existing step modules compile and run as-is.

The 1.0.0 internals are a ground-up rewrite onto a spec-conformant Gherkin
pipeline, so the things you may need to touch are your **versions** and your
**`.feature` files**, not your Elixir step code.

## What you must change

### 1. Toolchain / dependency versions

- **Elixir** must be `~> 1.18` (Cabbage now uses the built-in `JSON` module).
- **gherkin** must be `~> 3.0` (the rewritten pipeline). Update both in your
  `mix.exs`:

  ```elixir
  def project do
    [
      elixir: "~> 1.18",
      # ...
    ]
  end

  defp deps do
    [
      {:cabbage, "~> 1.0"}
      # gherkin ~> 3.0 comes in transitively
    ]
  end
  ```

  Then `mix deps.get`.

### 2. Remove non-standard "valued" tags from `.feature` files

Tags like `@timeout 100` were never valid Gherkin and are now **rejected** with
a parse error. Find them:

```sh
grep -rnE '^\s*@[A-Za-z0-9_]+\s+\S' features/
```

Rewrite each as a plain tag, optionally moving the value elsewhere:

```diff
- @timeout 100
+ @slow
  Scenario: ...
```

…and handle `@slow` in your step/config logic (e.g. an ExUnit `@tag timeout:`
set via a `tag/2` callback).

### 3. Audit your `Background:` blocks — they now RUN

Previously `Background` steps were broken and effectively **skipped**. In 1.0.0
they are prepended to every scenario in the feature (correct Cucumber behaviour,
implemented via pickle expansion). If a feature relied on Background being a
no-op, those steps will now execute — make sure they:

- have matching step definitions, and
- are safe to run before every scenario (idempotent setup).

### 4. Replace the non-standard `{name:type}` step sugar

Cabbage used to accept a cabbage-specific `{name:type}` step pattern (e.g.
`{count:int}`) that compiled to a regex with a *named* capture group and bound
the matched value into the step's `vars` map under that name. This was never
part of the Cucumber Expressions spec and has been **removed** in 1.0.0.

If you leave such a pattern in place, it now reaches the spec Cucumber
Expressions engine, which rejects `:` in a parameter-type name and raises at
compile time:

```
This Cucumber Expression has a problem at column 1:

{count:int} rows
^---------^
Undefined parameter type 'count:int'.
```

Find them:

```sh
grep -rnE '"\{[A-Za-z_][A-Za-z0-9_]*:[A-Za-z]+\}' test/ lib/
```

The faithful replacement is a **regex with a named capture**, which preserves
the named `vars` binding exactly:

```diff
- defgiven "{count:int} rows", %{count: count}, _state do
+ defgiven ~r/^(?<count>\d+) rows$/, %{count: count}, _state do
```

Type equivalents for the old `{name:type}` forms:

| old sugar       | named-capture regex            |
| --------------- | ------------------------------ |
| `{name:int}`    | `(?<name>\d+)`                 |
| `{name:float}`  | `(?<name>\d+\.\d+)`            |
| `{name:word}`   | `(?<name>\w*\S)`               |
| `{name:string}` | `(?<name>"(.*)")`              |

Alternatively, use a spec Cucumber Expression such as `{int}`, which now works
directly in `defgiven`/`defwhen`/`defthen`:

```diff
- defgiven "{count:int} rows", %{count: count}, _state do
+ defgiven "{int} rows", [count], _state do
```

Note the **tradeoff**: spec parameters are *positional*, not named. `{int}` binds
its value (already transformed to an integer) into the matched-data **list**
rather than a `%{count: count}` map, so you address it by position (`[count]`),
not by name. Use the regex form above if you specifically need the named variable
in a map.

## What you might change (only if you matched internals)

If any of your code pattern-matched on parser/AST structs, the internal struct
modules were renamed:

| 0.4.1 | 1.0.0 |
| --- | --- |
| `Gherkin.Elements.Document` (or similar) | `Cabbage.Feature.Document` |
| `Gherkin.Elements.Scenario` | `Cabbage.Feature.Scenario` |
| `Gherkin.Elements.Step` | `Cabbage.Feature.Step` |

Normal step definitions never reference these, so most projects skip this step.

## What you get for free

- **Scenario Outlines, `Rule:`, and `Background:`** all work via spec-compliant
  pickle expansion.
- **Cucumber Expressions** (`{int}`, `{string}`, `{word}`, custom params) in
  addition to the existing regex step matching.
- An optional **`on_ambiguous_step:`** mode if you want ambiguous matches to
  raise instead of silently picking the last-defined step.

## Verifying your upgrade

```sh
mix deps.get
mix compile --warnings-as-errors
mix test
```

If compilation fails, it is almost always (1) an Elixir/gherkin version mismatch
or (2) a valued tag in a `.feature` file — see sections above.
