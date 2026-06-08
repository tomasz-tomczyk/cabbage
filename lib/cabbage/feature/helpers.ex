defmodule Cabbage.Feature.Helpers do
  @moduledoc false
  require Logger

  def add_step(module, string_or_regex, vars, state, block, metadata) do
    regex = to_regex_ast(string_or_regex)

    Module.put_attribute(module, :steps, {:{}, [], [regex, vars, state, block, metadata]})
    quote(do: nil)
  end

  # cabbage understands three kinds of string step pattern, in priority order:
  #
  #   1. The cabbage-specific named-capture expression `{name:type}` (e.g.
  #      `{count:int}`) -> `Cabbage.Feature.NamedCaptureExpression`, which produces
  #      named captures bound into the step's `vars` map. (The spec engine in
  #      case 2 cannot express a named binding and rejects this syntax, so this
  #      remains a separate, frozen mini-engine — see that module's docs.)
  #
  #   2. A standard Cucumber Expression - it must contain at least one parameter
  #      `{...}` (anonymous `{}` or typed `{int}`). Once it does, optional text
  #      `(s)` and alternation `a/b` in the same pattern are honoured by the real
  #      engine, `Cabbage.CucumberExpression` (cabbage-ex/cabbage#47).
  #
  #   3. Anything else is an exact literal match: regex metacharacters ($, (, ),
  #      +, ., /, ...) are escaped so they match literally (see issue #64).
  #
  # Requiring a `{...}` parameter to opt in to case 2 keeps patterns like
  # `It costs $5 (USD)` literal: with no parameter, the `(USD)` is *not* treated
  # as optional text.
  @named_parameter_format ~r/\{[^{}:]+:[^{}:]+\}/u
  @standard_expression_format ~r/\{[^{}]*\}/u

  defp to_regex_ast(term) when is_binary(term) do
    cond do
      Regex.match?(@named_parameter_format, term) ->
        regex_string = Cabbage.Feature.NamedCaptureExpression.to_regex_string(term)
        Code.string_to_quoted!("~r/#{regex_string}/")

      Regex.match?(@standard_expression_format, term) ->
        regex_string = Cabbage.CucumberExpression.to_regex(term, standard_registry())
        Macro.escape(Regex.compile!(regex_string))

      true ->
        regex = Regex.compile!("^" <> Regex.escape(term) <> "$")
        Macro.escape(regex)
    end
  end

  defp to_regex_ast(term), do: term

  defp standard_registry, do: Cabbage.CucumberExpression.ParameterTypeRegistry.new()

  def add_tag(module, "@" <> tag_name, block), do: add_tag(module, tag_name, block)

  def add_tag(module, tag_name, block) do
    Module.put_attribute(module, :tags, {tag_name, block})
    quote(do: nil)
  end

  def evaluate_tag_block(block) do
    {new_state, _} = Code.eval_quoted(block)

    case new_state do
      {:ok, state} -> state
      _ -> %{}
    end
  end

  def file(file) do
    String.replace_leading(file, "#{File.cwd!()}/", "")
  end

  def metadata(env, function) do
    %{file: file(env.file), line: env.line, module: env.module, function: function, arity: 4}
  end

  def stacktrace(module, metadata) do
    [
      {module, metadata[:function], metadata[:arity], [file: metadata[:file], line: metadata[:line]]}
    ]
  end

  @keys ~w(async case describe file integration line test type scenario case_templae registered)a
  def remove_hidden_state(state) do
    Map.drop(state, @keys)
  end

  @doc false
  # Normalizes the ExUnit `setup` context into a scenario's starting state map, dropping the
  # ExUnit/cabbage bookkeeping keys that should never be visible to a step's state pattern.
  def init_context(exunit_state) do
    exunit_state |> to_map() |> remove_hidden_state()
  end

  @doc false
  # Folds a scenario's tags through the module's registered `tag` blocks and returns the merged
  # state map they contribute. Pure (no process) — replaces the Agent-seeding `run_tag/4`; the
  # result is merged into the scenario's initial context by the generated `setup` block.
  def collect_tag_state(tags, scenario_tags) do
    for tag <- scenario_tags, reduce: %{} do
      acc -> Map.merge(acc, tag_state(tags, tag))
    end
  end

  # Cabbage `tag` blocks are keyed by an atom/binary name. ExUnit-style valued tags
  # (e.g. `@moduletag timeout: 100`, which reaches here as `{:timeout, 100}`) are not cabbage
  # tag blocks — they configure ExUnit, not cabbage state — so they contribute no state.
  defp tag_state(tags, {tag, _value}), do: tag_state(tags, tag)

  defp tag_state(tags, tag) when is_atom(tag) or is_binary(tag) do
    string_tag = to_string(tag)

    case Enum.find(tags, &match?({^string_tag, _}, &1)) do
      {^string_tag, block} ->
        Logger.debug("Cabbage: Running tag @#{tag}...")
        evaluate_tag_block(block)

      _ ->
        %{}
    end
  end

  defp tag_state(_tags, _tag), do: %{}

  def map_tags(tags) do
    tags
    |> Enum.map(fn
      {tag, value} ->
        [{tag, value}]

      tag ->
        tag
    end)
  end

  @doc false
  # Normalizes the ExUnit `setup` context into a plain map. Older Elixir versions
  # passed `nil` when no context was present; newer ones pass a keyword list.
  def to_map(value) when is_map(value), do: value
  def to_map(value) when is_list(value), do: Map.new(value)
  def to_map(nil), do: %{}

  @doc false
  # Version-conditional wrapper around `ExUnit.Case.register_test`. Elixir 1.16+
  # exposes the 6-arity form (`module, file, line, type, name, tags`) and
  # deprecated the 4-arity `(env, type, name, tags)` form. We call whichever is
  # available so cabbage compiles warning-free across Elixir 1.15 - 1.19.
  def register_test(env, test_type, name, tags) do
    if function_exported?(ExUnit.Case, :register_test, 6) do
      apply(ExUnit.Case, :register_test, [env.module, env.file, env.line, test_type, name, tags])
    else
      apply(ExUnit.Case, :register_test, [env, test_type, name, tags])
    end
  end
end
