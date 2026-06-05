# Forking & Modernizing Elixir Gherkin + Cabbage to Cucumber Parity

A roadmap to fork `cabbage-ex/gherkin` (parser) and `cabbage-ex/cabbage` (runner), modernize them
for current Elixir, resolve the standing issue backlog, and reach 100% feature parity with the
official Cucumber/Gherkin reference implementation.

> Scope note: we do **not** own these packages. The plan assumes a hard fork under a new org/name
> (see "Fork strategy"), cherry-picking the live work (notably PR #97) as a starting baseline.

---

## 1. The two-layer architecture (and the one rule that governs the whole design)

The reference implementation deliberately decouples the two layers at a single seam — the **Pickle**:

```
.feature text
   │
   ▼   ┌─────────────────────── GHERKIN package (parser) ───────────────────────┐
 Source → Scanner → Tokens → Parser → AST → Pickles compiler → cucumber-messages │
   │                          (i18n dialect-driven)   (flatten/expand/inherit)   │
   └────────────────────────────────────────────────────────────────────────────┘
                                          │  Pickle (one runnable scenario)
                                          ▼
       ┌──────────────────────── CABBAGE package (runner) ────────────────────────┐
       │  consumes Pickles ONLY → matches steps → executes → emits result messages │
       └───────────────────────────────────────────────────────────────────────────┘
```

- **AST node** = faithful structure of the source (outlines, backgrounds, tables-as-templates preserved).
- **Pickle** = one concrete runnable scenario: outline rows already expanded, background steps already
  prepended, tags already inherited/unioned, placeholders already substituted.

**The governing rule: the runner must consume pickles, never re-parse `.feature` syntax.** Today cabbage
re-walks parser structs and does ad-hoc flattening (`Gherkin.flatten`). Routing through pickles is the
single architectural change that makes Background (#68), Rule (#69), and Scenario Outline expansion
*fall out for free* instead of being special-cased in the runner.

---

## 2. Current state (source-grounded audit)

### `gherkin` 2.0.0 — the parser (~822 LOC, zero runtime deps, frozen Sep 2023)
A hand-written, line-oriented recursive-descent parser. No tokenizer, no grammar file, no dialect tables.

| Area | State |
|---|---|
| Feature / Scenario / Example / Background | ✅ (Feature has a brittle hardcoded `"Feature: "` match) |
| Scenario Outline + Examples (+ synonyms) | ✅ substitution via `String.replace(~r/<k>/)` |
| Rule (v6) | ⚠️ parsed into `feature.rules` but `flatten`/`scenarios_for` **ignore rules** |
| Given/When/Then/And/But | ⚠️ parsed; `And`/`But` not resolved to prior keyword (runner does `And` only) |
| Data tables | ⚠️ rows become **atom-keyed maps** (unbounded-atom footgun); not cucumber cell shape |
| Doc strings | ⚠️ only `"""`; **no backtick fence, no media type** |
| Tags | ⚠️ **atom** tags (footgun); **non-standard `@key value` valued tags**; **no inheritance** |
| Comments | ⚠️ silently dropped, not in AST |
| i18n / `# language:` | ❌ **0 languages** (English hardcoded) — biggest gap |
| Output shape | ❌ ad-hoc structs; **no pickles, no cucumber-messages, no Location columns** |
| Error path | ❌ raises bare strings; no `bad`/recovery handling |
| Tests | ❌ ad-hoc heredocs; **not** the official conformance corpus |

**Verdict: closer to a rewrite than a patch** if true parity is the goal — there's no tokenizer/grammar
to extend and the entire i18n + pickles + messages surface is absent.

### `cabbage` 0.4.1 — the runner (~739 LOC, master on Mar 2025 *revert*)
`use Cabbage.Feature` reads a feature at compile time and emits ExUnit tests; state threads through a
per-scenario named `Agent`.

| Capability | State |
|---|---|
| defgiven/defwhen/defthen | ✅ |
| Cucumber Expressions | ⚠️ only `{int}{float}{word}{string}`; no `(s)`, no `a/b`, no escapes; collapses whitespace |
| Regex steps | ✅ |
| Data tables / doc strings into steps | ✅ |
| Scenario Outline expansion | ✅ (via parser flatten) |
| Background execution | ❌ `background_steps` never prepended (was implemented then reverted) |
| Rule execution | ❌ rules never read |
| Tags → ExUnit filter | ⚠️ works basically; untagged path buggy (#94) |
| setup/setup_all, custom case template | ⚠️ `:template` lets you compose `DataCase`; no first-class user setup (#71) |
| Hooks (Before/After/Around/step/all) | ❌ none (only a `tag @x do…end` macro) |
| Ambiguous-step detection | ❌ `Enum.find` silently takes first match (#88) |
| Undefined/pending semantics | ⚠️ missing step = **compile-time raise**, no runtime pending |
| Snippet generation | ✅ basic (regex-style) |
| Formatters (pretty/json/junit/message) | ❌ none (ExUnit output + `Logger.info`) |
| `register_test` | ❌ master reverted to **deprecated /4**; PR #97 fixes it properly |

**Verdict: basics are present; missing Background, Rule, hooks, ambiguity, formatters, and modern
ExUnit registration.** PR #97 is the correct fork baseline for the deprecation/compat work.

---

## 3. Fork strategy (decision required up front)

1. **Names.** `cabbage-ex` is dormant but not archived (a 2026 PR exists), so publishing under the same
   hex names is off the table. Options:
   - **New names** (recommended): e.g. `gherkin_ex`/`cabbage_ex` → no, pick distinct names to avoid
     confusion, e.g. `feature_parser` + a runner name. Keep module namespaces clean (`Gherkin.*`,
     `Cabbage.*` can be reused in your own org's packages if names differ on hex).
   - Offer the work upstream first (open a coordination issue) — cheap goodwill, may fail given dormancy.
2. **Two packages or one?** Keep the **parser/runner split** — it mirrors the reference, lets the parser
   be used standalone (gherkin already has ~25k recent downloads independent of cabbage), and keeps the
   pickle seam honest.
3. **Baseline commit.** Fork at current `master` of both, immediately apply the PR #97 equivalent to
   cabbage so you start on a warning-clean, multi-version build.

---

## 4. Elixir modernization track (runs alongside every phase)

The language has been stable, so this is mostly hygiene, but do it deliberately:

- **Version floor.** Bump to `~> 1.15` minimum (drops the `~> 1.3`/`~> 1.13` split); test matrix
  **1.15 → 1.19** on **OTP 26/27/28**.
- **`register_test` deprecation (#93).** Adopt PR #97's version-conditional approach
  (`register_test/6` on new Elixir, `/4` fallback) behind a compile-time version check. This is the
  one genuinely load-bearing modernization item.
- **Warnings to zero.** `mix format`, `mix credo` (non-strict, matching house style), `mix dialyzer`
  green in CI; treat warnings as errors in CI.
- **Typespecs + `@spec`** across public API; consider Elixir 1.18+ set-theoretic type annotations on
  the core structs (nice-to-have, not parity).
- **ExUnit modernization opportunity.** Elixir 1.18 added **parameterized tests** — a natural fit for
  Scenario Outline rows (one parameterized case per Examples row) and a cleaner alternative to emitting
  N separate test functions. Evaluate during Phase 2.
- **Config.** Already on `Config` (not `Mix.Config`); keep it.
- **Vendor data, don't hand-maintain.** `gherkin-languages.json` is a data file — vendor it verbatim
  and regenerate from upstream, never hand-edit keywords.
- **Conformance corpus as a git submodule / vendored fixtures**, regenerated from upstream
  `cucumber/gherkin` `testdata/`.

---

## 5. Phased roadmap

Effort labels assume heavy LLM assistance: **S** ≈ hours, **M** ≈ a few days, **L** ≈ 1–2 weeks,
**XL** ≈ multi-week. The parser conformance work is the long pole.

### Phase 0 — Fork & green baseline  (unblocks everything) — **M**
- Fork both repos; new hex names; CI matrix Elixir 1.15–1.19 × OTP 26–28.
- Apply PR #97 equivalent → fix `register_test` (#93), clear all warnings.
- **Breaking-but-early cleanups** (do now, before users):
  - Tags: **atom → string**; **drop non-standard `@key value` valued tags** (REJECT — not in spec).
  - Data-table keys: **atom → string** (kills atom-exhaustion footgun).
- Cheap runner correctness wins:
  - `But` keyword resolution (#83) — one clause next to the `And` rewrite.
  - Untagged-scenario tag plumbing (#94).
  - Exact-string step matching mode (#64).
- Wire up the official **`testdata/good` + `testdata/bad`** corpus as a (initially failing) test suite —
  this becomes the objective parity scoreboard for Phase 1.

### Phase 1 — Parser to conformance  (`gherkin` package; the big one) — **XL**
Effectively re-architect the parser around the reference pipeline. Output parity (passing testdata) is
the goal — a hand-written recursive-descent parser is fine; Berp generation is **not** required.
- **Dialect-driven scanning + i18n (#largest gap):** vendor `gherkin-languages.json` (80 languages);
  `# language:` header support; token matcher classifies lines against the active dialect.
- **AST with `Location{line, column}`** on every node; comments preserved.
- **Full grammar:** Rule (proper, incl. rule-level background + tags), Background, `*` bullet steps,
  doc strings with **both `"""` and backtick fences + media type**, descriptions under all elements.
- **Tag inheritance** Feature→Rule→Scenario/Outline→Examples.
- **Pickles compiler:** AST → pickles (one per scenario + per Examples row; background prepended;
  placeholder substitution incl. in tables/doc strings; tag union onto each pickle).
- **cucumber-messages emit:** `Source`, `GherkinDocument`, `Pickle` envelopes as NDJSON.
- **Error recovery / `bad` path** matching the testdata error expectations.
- **Definition of done = green `testdata/good` (ast + pickles + tokens) and `testdata/bad` (errors).**

### Phase 2 — Runner core to parity  (`cabbage` package) — **L/XL**
- **Re-point the runner at pickles** from the new gherkin (stop re-parsing). This *delivers
  Background (#68), Rule (#69), and outline expansion* without runner special-casing.
- **Step result state machine:** passed / failed / **undefined** / **pending** / **ambiguous (#88)** /
  **skipped**, with skip-after-failure/undefined/pending semantics. Replace `Enum.find` (first-match)
  with collect-all → raise/report on >1 (ambiguity).
- **Hooks:** Before/After (scenario), BeforeAll/AfterAll, **tagged hooks** (needs the tag-expression
  evaluator below); then BeforeStep/AfterStep (invoke-around semantics); Around (nice).
- **setup/setup_all integration (#71)** reconciled with the auto-generated per-scenario setup; keep the
  `:template` hook for composing app case templates (DataCase/Ecto sandbox) — and ship a first-class
  Ecto-sandbox recipe (the thing that blocks real-app adoption).
- **Feature-level grouping (#73)**; revisit `tag → setup_tag` (#74) under the new hook model.
- **World/state isolation:** fresh per-scenario state (current Agent model refined); document the
  "scenarios must be independent" contract.
- **Cucumber Expressions hardening (#47):** optional text `(s)`, alternation `a/b`, escaping; full
  built-in parameter types (`{}`, `{bigdecimal}`, `{double}`, …) + **custom parameter type registration**
  (name/regexp/type/transformer/use_for_snippets/prefer_for_regexp_match). Keep regex steps.
- **Tag-expression evaluator:** `and`/`or`/`not`/parentheses — powers `--tags` filtering and tagged hooks.
- **DataTable helper API:** `raw`, `rows`, `hashes`, `rows_hash`, `transpose` (core); `diff!`,
  `column_names`, cell-type conversion (nice). Doc-string content-type delivered to the step. Runner-side
  data-table-type / doc-string-type / default transformers.
- **ExUnit parameterized tests** evaluation for outline rows (modernization).

### Phase 3 — Reporting & ecosystem interop — **M/L**
- **`message` (NDJSON) formatter** — runner-side envelopes (TestCase / TestStep* / TestRun* / Attachment).
  This is the highest-leverage formatter: it unlocks `reports.cucumber.io`, the official HTML report, and
  any cucumber-messages consumer. Prioritize over reimplementing legacy formatters.
- **`pretty` formatter** (human console output).
- **Attachments/embeddings** (media type → Attachment envelopes).
- Nice-to-have formatters: `progress`, legacy `json`, `junit`, `rerun`, `usage`.
- **Retry** (`--retry` + retry tag filter), **profiles** (`cucumber.yml`/`@profile`), **parallel** —
  largely delegate to ExUnit's own parallelism/`--max-failures`/`mix test --failed` where possible rather
  than reinventing.

### Phase 4 — DX & "first-class" polish — **M/L**
- `mix` generators: `mix cabbage.gen.steps <feature>` scaffolds step stubs; cucumber-expression snippets
  for undefined steps.
- Integration adapters: **Phoenix/Ecto sandbox** recipe, **LiveView**, **Wallaby/Playwright** browser steps.
- **`.feature` language server** (step navigation/autocomplete/go-to-definition) — the editor experience
  that signals first-class.
- Docs site + a "spec layer for AI-generated Elixir" narrative (the demand thesis from earlier in the
  conversation).

---

## 6. Open-issue triage (all 21 — "if they make sense")

**Adopt as-is / absorbed into a phase:**

| # | Issue | Verdict | Where |
|---|---|---|---|
| 47 | Cucumber expressions | Adopt (harden the partial impl) | Phase 2 |
| 53 | How to log steps (cucumber-style) | Adopt | Phase 3 (pretty/message formatters) |
| 61 | README links broken (Table/DocStrings) | Adopt (trivial) | Phase 0 docs |
| 64 | Match exact strings | Adopt | Phase 0 |
| 65 | Allow returning keyword list in result tuple | Adopt (small ergonomics) | Phase 2 |
| 68 | Background steps | Adopt | Phase 2 (free via pickles) |
| 69 | Gherkin Rule | Adopt | Phase 1 (parser) + Phase 2 (via pickles) |
| 71 | setup / setup_all | Adopt | Phase 2 |
| 73 | Group scenarios by feature | Adopt | Phase 2 |
| 74 | tag → setup_tag | Adopt (re-frame under hook model) | Phase 2 |
| 75 | Test on all supported versions | Adopt | Phase 0 (CI matrix) |
| 77 | One way to import a feature file | Adopt (API cleanup) | Phase 0/2 |
| 83 | `But` keyword | Adopt (one-liner) | Phase 0 |
| 88 | Two `defwhen` both match (ambiguity) | Adopt | Phase 2 |
| 93 | Deprecation warnings | Adopt | Phase 0 (PR #97) |
| 94 | Untagged scenarios | Adopt | Phase 0 |

**Reconsider / reshape:**

| # | Issue | Verdict | Rationale |
|---|---|---|---|
| 72 | Rename to `Cabbage.Case` | Defer / optional | Aligns with ExUnit `*.Case` naming, but cosmetic and breaking. If renaming the fork anyway, fold into the new public API; otherwise skip. |
| 5 | Need open-source icon | Skip (not parity) | Cosmetic; nice for a docs site in Phase 4, irrelevant to functionality. |

**Implicitly rejected (not tracked as issues, surfaced by the audit):**
- **Non-standard valued tags `@key value`** in the current parser → **remove**; real Gherkin tags are flat
  strings. (Phase 0 cleanup.)
- **Atom-keyed tags & table cells** → **replace with strings**; unbounded-atom creation on untrusted
  feature files is a memory/DoS footgun. (Phase 0 cleanup.)

Net: **every open issue makes sense and is absorbed**, except the icon (#5, skip) and the rename (#72,
optional). Two latent design choices in the current code are actively reversed.

---

## 7. Sequencing & critical path

```
Phase 0 (green baseline + cheap wins + footgun removal + testdata scoreboard)
        │
        ├─► Phase 1  (parser → conformance; i18n, pickles, messages)         [long pole]
        │              │
        │              ▼
        └─────────► Phase 2  (runner consumes pickles; results, hooks, expressions)
                           │
                           ▼
                     Phase 3 (message/pretty formatters, attachments)
                           │
                           ▼
                     Phase 4 (generators, integrations, language server, docs)
```

- Phase 2 depends on Phase 1's pickle output for Background/Rule/outline correctness, but the
  result-state-machine, hooks, and cucumber-expression work can proceed in parallel against the
  *current* parser and re-point to pickles when Phase 1 lands.
- **The objective definition of "done" for parser parity is binary and external:** the upstream
  `testdata` corpus passes. That removes all subjectivity from the biggest chunk of work.

## 8. Honest framing

- The **parser** is the real project — i18n (80 languages), pickles, cucumber-messages, conformance, and
  error recovery are all absent and amount to a rewrite. It is, however, almost entirely mechanical,
  spec-defined, and conformance-gated work — i.e. extremely LLM-tractable.
- The **runner** is a meaningful upgrade but not a rewrite; the key insight (consume pickles) collapses
  several issues at once.
- None of this makes it *first-class by adoption* — that's a demand/trust problem, not a code problem
  (see the earlier conversation). But it would make the fork the **complete, conformant, modern,
  best-in-class option for Gherkin in Elixir**, which is a winnable and worthwhile target.
