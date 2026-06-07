# Releasing cabbage 1.0.0 (and gherkin 3.0.0)

`cabbage` depends on the rewritten **gherkin** fork. Until gherkin `3.0.0` is on
hex, `mix.exs` keeps a **git** dependency on the fork so the build, tests, and CI
stay green:

```elixir
# RELEASE: replace with {:gherkin, "~> 3.0"} once gherkin 3.0.0 is published to hex (see RELEASING.md).
{:gherkin, git: "https://github.com/tomasz-tomczyk/gherkin.git", branch: "master"},
```

Publishing must therefore happen in a **strict order**: gherkin first, then
cabbage. Do **not** swap the cabbage dep to `~> 3.0` before gherkin 3.0.0 exists
on hex — `mix deps.get` will fail and CI will go red.

## Prerequisites

1. **Ownership / maintainership.**
   - Hex: a current `gherkin` owner adds the new maintainer
     (`mix hex.owner add gherkin <email>`), or transfers ownership
     (`mix hex.owner transfer gherkin <email>`). Confirm with `mix hex.owner list gherkin`.
   - Do the same for `cabbage` (`mix hex.owner add cabbage <email>` /
     `mix hex.owner list cabbage`).
   - GitHub: accept the maintainer invite on `cabbage-ex/gherkin` and
     `cabbage-ex/cabbage`.

## Step 1 — Publish gherkin 3.0.0 first

From the **gherkin** repo:

```sh
mix deps.get
mix compile --warnings-as-errors
mix format --check-formatted
mix test
# run gherkin's own conformance scoreboards (whatever the gherkin repo defines)
mix hex.publish        # publishes gherkin 3.0.0 + docs
```

Wait until `gherkin 3.0.0` is visible on https://hex.pm/packages/gherkin before
continuing.

## Step 2 — Switch cabbage to the hex dep

In `cabbage/mix.exs`, replace the git dep with the hex dep:

```elixir
{:gherkin, "~> 3.0"},
```

Then refresh and re-verify the **full** gate locally:

```sh
mix deps.unlock gherkin
mix deps.get
mix compile --warnings-as-errors
mix format --check-formatted
mix test                         # expect 0 failures
MIX_ENV=test mix conformance.cck          # expect CCK 43/44 (1 deferred)
MIX_ENV=test mix conformance.tags         # expect 64/64
MIX_ENV=test mix conformance.expressions  # expect 115/115
```

Commit the dep swap + the updated `mix.lock`.

## Step 3 — Publish cabbage 1.0.0

```sh
mix hex.publish        # publishes cabbage 1.0.0 + docs
```

(Equivalently, `mix publish` runs the project's `hex.publish` + `hex.publish docs` + `tag` alias.)

Verify `cabbage 1.0.0` on https://hex.pm/packages/cabbage and that the docs
render on HexDocs.

## Step 4 — Push the modernized branches upstream

Push the modernized `master` to the canonical org (or open PRs if you prefer
review):

```sh
# gherkin repo
git push cabbage-ex master   # or: open a PR against cabbage-ex/gherkin

# cabbage repo
git push cabbage-ex master   # or: open a PR against cabbage-ex/cabbage
```

Tag the releases (`v3.0.0` for gherkin, `v1.0.0` for cabbage) on the canonical
remote.

## Rollback note

Hex versions are immutable — you cannot overwrite a published version. If a
release is bad, `mix hex.retire <package> <version>` and publish a patch. This is
the main reason the order above is strict: never publish cabbage 1.0.0 against a
gherkin that is not yet on hex.
