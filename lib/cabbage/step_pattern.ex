defmodule Cabbage.StepPattern do
  @moduledoc """
  The shared, dependency-free pattern core both cabbage runners use to classify a
  step pattern into a tagged, compiled form.

  Cabbage understands three kinds of step pattern, but only two compiled forms:

    * a `~r/.../` `Regex` (passed through verbatim) → `{:regex, %Regex{}}`;

    * a binary containing at least one `{...}` parameter (anonymous `{}` or typed
      `{int}`) — a standard Cucumber Expression compiled against the parameter-type
      registry → `{:cucumber_expression, %Cabbage.CucumberExpression{}}`;

    * any other binary — an exact literal match, compiled to an anchored `Regex`
      whose metacharacters (`$`, `(`, `)`, `+`, `.`, ...) are escaped to match
      literally → `{:regex, %Regex{}}`.

  Requiring a `{...}` parameter to opt in to the Cucumber Expression case keeps
  patterns like `It costs $5 (USD)` literal. A literal `{` can be escaped with a
  backslash: writing `"\\\\{weird\\\\}"` in Elixir source yields the pattern
  `\\{weird\\}`, which classifies as a Cucumber Expression that matches the literal
  text `{weird}`.

  Both runners share `classify/2`; each retains its own storage (the Feature layer
  re-wraps the result into AST, the Messages layer stores it on its struct) and its
  own ambiguity policy. Offset computation (`stepMatchArguments`) stays in the
  Messages layer.
  """

  alias Cabbage.CucumberExpression

  @standard_expression_format ~r/\{[^{}]*\}/u

  @type classified ::
          {:regex, Regex.t()}
          | {:cucumber_expression, CucumberExpression.t()}

  @doc "The default parameter-type registry (int/float/word/string) for callers with no custom types."
  @spec standard_registry() :: CucumberExpression.ParameterTypeRegistry.t()
  def standard_registry, do: CucumberExpression.ParameterTypeRegistry.new()

  @doc """
  Classifies `pattern` against `parameter_registry` into a tagged, compiled form.

  `parameter_registry` is a `Cabbage.CucumberExpression.ParameterTypeRegistry` — the
  Feature layer passes the default registry; the Messages layer passes its own
  (which may carry custom parameter types). A binary containing a `{...}` parameter
  is compiled here, so an undefined parameter type (e.g. the removed `{count:int}`
  sugar) raises a `Cabbage.CucumberExpression.Errors.CucumberExpressionError` at the
  call site.
  """
  @spec classify(Regex.t() | String.t(), CucumberExpression.ParameterTypeRegistry.t()) :: classified()
  def classify(%Regex{} = regex, _parameter_registry), do: {:regex, regex}

  def classify(pattern, parameter_registry) when is_binary(pattern) do
    cond do
      Regex.match?(@standard_expression_format, pattern) ->
        {:cucumber_expression, CucumberExpression.compile(pattern, parameter_registry)}

      true ->
        {:regex, Regex.compile!("^" <> Regex.escape(pattern) <> "$")}
    end
  end
end
