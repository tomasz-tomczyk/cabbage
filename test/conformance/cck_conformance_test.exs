defmodule Cabbage.Conformance.CCKTest do
  @moduledoc """
  Drives the message-emitting runner (`Cabbage.Messages`) over the vendored Cucumber
  Compatibility Kit samples and asserts each targeted area's normalized envelope stream
  equals its golden.

  Tagged `:conformance` so it is excluded from the default `mix test` run (which must stay
  green). Run with `mix conformance` or `mix test --only conformance`. The plain scoreboard
  is `mix conformance.cck`.
  """
  use ExUnit.Case, async: true

  @moduletag :conformance

  alias Cabbage.Conformance.CCK.Runner

  # Areas that currently pass end-to-end. A regression here fails loudly.
  @passing ~w(
    empty backgrounds data-tables doc-strings cdata rules rules-backgrounds examples-tables
    multiple-features multiple-features-reversed unused-steps undefined pending skipped ambiguous
  )

  # Areas blocked on gherkin-parser feature gaps (NOT on the runner):
  #   * minimal  — Feature description lines beginning with `*` are mis-tokenized as steps.
  #   * markdown — the Markdown-with-Gherkin dialect (`.feature.md`) is not parsed.
  # Tracked as gherkin-fork follow-ups; skipped so the suite documents them without failing.
  @blocked_on_gherkin ~w(minimal markdown)

  for sample <- @passing do
    test "CCK conformance: #{sample}" do
      sample = unquote(sample)

      case Runner.compare(sample) do
        {:ok, count} -> assert count > 0
        {:error, reason} -> flunk("#{sample} diverged from golden:\n#{reason}")
      end
    end
  end

  for sample <- @blocked_on_gherkin do
    @tag :skip
    test "CCK conformance: #{sample} (blocked on gherkin parser)" do
      sample = unquote(sample)
      assert {:ok, _} = Runner.compare(sample)
    end
  end

  test "every targeted sample is accounted for" do
    assert Enum.sort(Runner.samples()) == Enum.sort(@passing ++ @blocked_on_gherkin)
  end
end
