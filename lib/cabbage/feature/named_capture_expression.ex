defmodule Cabbage.Feature.NamedCaptureExpression do
  @moduledoc false

  # An INTENTIONAL, frozen mini-engine for cabbage's `{name:type}` named-capture step sugar.
  #
  # This is deliberately NOT a duplicate of the full `Cabbage.CucumberExpression` engine.
  # The two solve different problems:
  #
  #   * `Cabbage.CucumberExpression` implements the cucumber-expressions SPEC (`{int}`,
  #     `{word}`, optionals, alternation, custom parameter types). Its captures are
  #     ANONYMOUS — `{int}` carries no caller-chosen name — so it cannot bind a value to a
  #     named variable, and it REJECTS the `{name:type}` syntax outright (`:` is a reserved
  #     character in a spec parameter-type name).
  #
  #   * This module implements cabbage's older, cabbage-specific extension `{name:type}`
  #     (e.g. `{count:int}`). It compiles to a regex with a NAMED capture group
  #     (`(?<count>\d+)`) so the matched value is bound to the `count` key in the step's
  #     `vars` map (via `Regex.named_captures/2` in `Cabbage.Feature`).
  #
  # Because the spec engine fundamentally cannot model a named binding, this sugar cannot be
  # folded into it without a behaviour change. It is kept as a small, self-contained module —
  # consolidating the former `CucumberExpression`/`Parameter`/`ParameterType` trio — so it
  # reads as a frozen feature, not as accidental duplication.
  #
  # `Cabbage.Feature.Helpers` routes a string step pattern here ONLY when it contains the
  # `{name:type}` form; bare spec expressions (`{int}`, `{}`) go to `Cabbage.CucumberExpression`
  # and parameterless strings are matched literally.
  #
  # Supported types: `int`, `float`, `word`, `string`.

  # A `{name:type}` term. `name` is the capture name; `type` resolves to a type regex below.
  @parameter_format ~r/\{(?<name>.*):(?<type>.*)\}/u

  @type_regexes %{
    "int" => ~S/\d+/,
    "float" => ~S/\d+\.\d+/,
    "word" => ~S/\w*\S/,
    "string" => ~S/"(.*)"/
  }

  @doc """
  Turn a `{name:type}` cucumber expression into an anchored regex string with one named
  capture group per parameter.

      iex> Cabbage.Feature.NamedCaptureExpression.to_regex_string("{count:int} rows")
      "^(?<count>\\\\d+) rows$"
  """
  @spec to_regex_string(String.t()) :: String.t()
  def to_regex_string(expression) do
    inner =
      expression
      |> String.split()
      |> Enum.map_join(" ", &term_to_pattern/1)

    "^" <> inner <> "$"
  end

  # A `{name:type}` term becomes a named capture; any other term is emitted verbatim.
  defp term_to_pattern(term) do
    case Regex.named_captures(@parameter_format, term) do
      %{"name" => name, "type" => type} -> "(?<#{name}>#{type_regex(type)})"
      _ -> term
    end
  end

  # The regex source for a supported `{name:type}` type (`nil` for an unknown type, matching
  # the historical behaviour where `Map.get/2` returned nil).
  defp type_regex(type), do: Map.get(@type_regexes, type)
end
