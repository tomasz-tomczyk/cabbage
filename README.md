# Cabbage

[![CI](https://github.com/tomasz-tomczyk/cabbage/actions/workflows/ci.yml/badge.svg)](https://github.com/tomasz-tomczyk/cabbage/actions/workflows/ci.yml)

A spec-conformant [Cucumber](https://cucumber.io/) runner for Elixir.

Cabbage compiles Gherkin `.feature` files into [ExUnit](https://hexdocs.pm/ex_unit/ExUnit.html)
tests at compile time, so non-technical stakeholders read and write the feature files while
developers maintain ordinary Elixir step definitions. It parses Gherkin with the
[gherkin fork](https://github.com/tomasz-tomczyk/gherkin) and also ships a message-emitting
interpreter that is graded against the official Cucumber test kits.

## Conformance

This fork is verified against the upstream Cucumber suites:

| Suite | Score |
| --- | --- |
| Cucumber Compatibility Kit (CCK) | **43 / 44** |
| Cucumber Expressions | **115 / 115** |
| Tag Expressions | **64 / 64** |

The scoreboards are reproducible locally:

```shell
MIX_ENV=test mix conformance.cck
MIX_ENV=test mix conformance.tags
MIX_ENV=test mix conformance.expressions
```

These tasks print scoreboards. The hard regression gate (run in CI) is the tagged ExUnit
suite, which asserts the expected passing-sample sets:

```shell
mix test --only conformance
```

## Requirements & dependencies

- **Elixir 1.18+** (CI covers 1.18, 1.19, and 1.20).
- Uses the **built-in `JSON` module** — no `jason` dependency.
- The only runtime dependency is the [gherkin fork](https://github.com/tomasz-tomczyk/gherkin)
  (itself `jason`-free). `ex_doc` is dev-only.

## Installation

Add `cabbage` to your dependencies in `mix.exs`, pointing at this fork:

```elixir
def deps do
  [
    {:cabbage, github: "tomasz-tomczyk/cabbage", branch: "master"}
  ]
end
```

> The Hex package and OTP application name remain `:cabbage`; a rename is deferred to a
> later release so existing dependents keep resolving.

## Example Usage

By default, feature files are expected inside `test/features`. This can be configured within
your application:

```elixir
config :cabbage, features: "some/other/path/from/your/project/root"
```

Inside `test/features/coffee.feature`:

```gherkin
Feature: Serve coffee
  Coffee should not be served until paid for
  Coffee should not be served until the button has been pressed
  If there is no coffee left then money should be refunded

  Scenario: Buy last coffee
    Given there are 1 coffees left in the machine
    And I have deposited £1
    When I press the coffee button
    Then I should be served a coffee
```

Translate each line to a step by `use`-ing `Cabbage.Feature` and providing `defgiven/4`,
`defwhen/4`, and `defthen/4` step definitions. Inside `test/features/coffee_test.exs`:

```elixir
defmodule MyApp.Features.CoffeeTest do
  # Options other than `file:` are passed directly to `ExUnit`.
  use Cabbage.Feature, async: false, file: "coffee.feature"

  # `setup/1` runs prior to each scenario; `setup_all/1` runs once for the suite.
  setup do
    on_exit fn ->
      IO.puts "Scenario completed, cleanup stuff"
    end
    %{my_starting: :state, user: %User{}} # Beginning state
  end

  # `defgiven/4`, `defwhen/4` and `defthen/4` take a regex, the matched data,
  # the current state, and a block.
  defgiven ~r/^there (is|are) (?<number>\d+) coffee(s) left in the machine$/, %{number: number}, %{user: user} do
    # Returning `{:ok, map}` merges into the scenario state; anything else leaves it unchanged.
    {:ok, %{machine: Machine.put_coffee(Machine.new, number)}}
  end

  defgiven ~r/^I have deposited £(?<number>\d+)$/, %{number: number}, %{user: user, machine: machine} do
    {:ok, %{machine: Machine.deposit(machine, user, number)}} # State is merged, so `user` is kept
  end

  # With no captures, the matched map is empty. State is unchanged here.
  defwhen ~r/^I press the coffee button$/, _, state do
    Machine.press_coffee(state.machine)
  end

  defthen ~r/^I should be served a coffee$/, _, state do
    assert %Coffee{} = Machine.take_drink(state.machine) # Assert inside `defthen/4`
  end
end
```

The compiled test is logically equivalent to a hand-written ExUnit case: each scenario
becomes one `test`, with state threaded from step to step.

This provides the best of both worlds: feature files for non-technical users, and an actual
test file written in Elixir for developers who maintain them.

### Tables & Doc Strings

Tables and Doc Strings are provided to step definitions under the `:table` and `:doc_string`
variables. See the dynamic-data example in
[test/feature_execution_test.exs](test/feature_execution_test.exs) and
[test/features/dynamic.feature](test/features/dynamic.feature).

### Running specific tests

Feature files are translated to ExUnit at compile time, so target the `.exs` file (not the
`.feature` file) when running a single scenario. The line numbers are printed as each test runs.

```shell
# Runs the scenario of test/features/coffee.feature compiled into feature_test.exs at line 13
mix test test/feature_test.exs:13
```

### Emitting cucumber-messages

`Cabbage.Formatter` is an ExUnit formatter that writes a
[cucumber-messages](https://github.com/cucumber/messages) NDJSON stream as your scenarios
run. Add it alongside the default formatter in `test/test_helper.exs`:

```elixir
ExUnit.start(formatters: [ExUnit.CLIFormatter, Cabbage.Formatter])
```

The stream is written to `cucumber-messages.ndjson` by default; configure the path with
`config :cabbage, messages_output: "path.ndjson"` or the formatter's `:messages_output`
option. See `Cabbage.Formatter` for the emitted envelope types and the scenario-level
step-result semantics.

## Developing

Run the test suite and the conformance gates:

```shell
mix deps.get
mix test
mix test --only conformance
```

A `docker-compose.yml` is also provided for running the tests in containers:

```shell
docker-compose up
```

## Attribution

This is a fork of [`cabbage-ex/cabbage`](https://github.com/cabbage-ex/cabbage), originally
created by Matt Widmann, Steve B, and Max Marcon. Big thanks also to
[@meadsteve](https://github.com/meadsteve) and the
[White Bread](https://github.com/meadsteve/white-bread) project for the original head start.

Licensed under the [MIT License](LICENSE).
