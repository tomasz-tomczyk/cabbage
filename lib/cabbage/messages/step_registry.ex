defmodule Cabbage.Messages.StepRegistry do
  @moduledoc """
  An ordered collection of step definitions for the message-emitting runner
  (`Cabbage.Messages`).

  This is intentionally separate from `Cabbage.Feature`'s compile-time, ExUnit-bound
  step machinery. The runner is a direct interpreter over `Gherkin.Pickle` steps, so
  it needs a plain, runtime-inspectable registry rather than module attributes baked
  into a test module.

  A step definition pairs a *pattern* (a Cucumber Expression string or an Elixir
  `Regex`) with a 0-arity-or-more function executed when a pickle step matches. The
  registry preserves registration order, which the runner uses to assign the stable,
  sequential ids the cucumber-messages goldens expect.

  ## Pattern kinds

    * a **binary** is a Cucumber Expression (`"I have {int} cukes"`), reported in the
      `stepDefinition` envelope as `CUCUMBER_EXPRESSION`;
    * a **`Regex`** is a regular expression, reported as `REGULAR_EXPRESSION`.

  Matching against either yields the captured arguments *and* their source-text
  offsets, which the runner serializes into `stepMatchArgumentsLists`.
  """

  alias Cabbage.CucumberExpression
  alias Cabbage.CucumberExpression.ParameterTypeRegistry
  alias Cabbage.Messages.StepRegistry.StepDefinition

  @type t :: %__MODULE__{definitions: [StepDefinition.t()], parameter_registry: term()}

  defstruct definitions: [], parameter_registry: nil

  defmodule StepDefinition do
    @moduledoc "A single registered step definition: a pattern, a run function, and a source reference."

    @type pattern_kind :: :cucumber_expression | :regular_expression

    @type t :: %__MODULE__{
            pattern_kind: pattern_kind(),
            source: String.t(),
            compiled: term(),
            fun: function(),
            uri: String.t() | nil,
            line: pos_integer() | nil
          }

    defstruct [:pattern_kind, :source, :compiled, :fun, :uri, :line]
  end

  @doc "An empty registry backed by the default parameter-type registry (int/float/word/string)."
  @spec new() :: t()
  def new do
    %__MODULE__{definitions: [], parameter_registry: ParameterTypeRegistry.new()}
  end

  @doc """
  Register a step definition.

  `pattern` is a Cucumber Expression string or a `Regex`. `fun` receives the matched,
  transformed arguments (one per capture) and may return `:ok`/`nil`/`{:ok, world}`
  (PASSED), the strings `"pending"`/`"skipped"`, raise `Cabbage.PendingError` /
  `Cabbage.SkippedError` (PENDING/SKIPPED *with* an exception), or raise anything else
  (FAILED) — see `Cabbage.Messages` for the full status mapping. `:uri`/`:line` populate
  the emitted `stepDefinition.sourceReference`.
  """
  @spec add(t(), String.t() | Regex.t(), function(), keyword()) :: t()
  def add(%__MODULE__{} = registry, pattern, fun, opts \\ []) when is_function(fun) do
    definition = build_definition(registry, pattern, fun, opts)
    %{registry | definitions: registry.definitions ++ [definition]}
  end

  defp build_definition(registry, pattern, fun, opts) when is_binary(pattern) do
    compiled = CucumberExpression.compile(pattern, registry.parameter_registry)

    %StepDefinition{
      pattern_kind: :cucumber_expression,
      source: pattern,
      compiled: compiled,
      fun: fun,
      uri: opts[:uri],
      line: opts[:line]
    }
  end

  defp build_definition(_registry, %Regex{} = pattern, fun, opts) do
    %StepDefinition{
      pattern_kind: :regular_expression,
      source: Regex.source(pattern),
      compiled: pattern,
      fun: fun,
      uri: opts[:uri],
      line: opts[:line]
    }
  end

  @doc "The registered definitions, in registration order."
  @spec definitions(t()) :: [StepDefinition.t()]
  def definitions(%__MODULE__{definitions: definitions}), do: definitions
end
