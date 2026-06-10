defmodule Cabbage.Feature.Helpers do
  @moduledoc false
  require Logger

  def add_step(module, string_or_regex, vars, state, block, metadata) do
    pattern = to_pattern_ast(string_or_regex)

    Module.put_attribute(module, :steps, {:{}, [], [pattern, vars, state, block, metadata]})
    quote(do: nil)
  end

  # cabbage understands three kinds of step pattern. A step is stored with its
  # pattern AST as the first tuple element:
  #
  #   * a `~r/.../` `Regex` (passed through verbatim) — matched with
  #     `Regex.named_captures`, so its matched data is a *map* of named captures
  #     (string values);
  #
  #   * a binary containing at least one `{...}` parameter (anonymous `{}` or
  #     typed `{int}`) — a standard Cucumber Expression, stored as a
  #     `{:cucumber_expression, source}` marker and matched through the real
  #     engine, `Cabbage.CucumberExpression`, so its matched data is a positional
  #     *list* of transformed argument values (`{int}` -> integer, etc.);
  #
  #   * any other binary — an exact literal match, stored as a `Regex` whose
  #     metacharacters ($, (, ), +, ., /, ...) are escaped to match literally.
  #
  # Requiring a `{...}` parameter to opt in to the Cucumber Expression case keeps
  # patterns like `It costs $5 (USD)` literal: with no parameter, the `(USD)` is
  # *not* treated as optional text. A literal `{` can be escaped with a backslash:
  # writing "\\{weird\\}" in Elixir source yields the pattern `\{weird\}`, which
  # the engine matches against the literal text `{weird}`.
  #
  # The expression is compiled here (at step-macro expansion) purely to validate
  # it: a malformed expression — or the removed cabbage-specific `{name:type}`
  # named-capture sugar (e.g. `{count:int}`), since `:` is not valid in a spec
  # parameter-type name — raises a clear `Undefined parameter type` compile error
  # at the definition site rather than later. To keep a named `vars` binding, use
  # a regex with a named capture instead, e.g. `~r/(?<count>\d+) rows/`; spec
  # expressions like `{int}` match but bind positionally. See UPGRADING.md.
  @standard_expression_format ~r/\{[^{}]*\}/u

  defp to_pattern_ast(term) when is_binary(term) do
    cond do
      Regex.match?(@standard_expression_format, term) ->
        _ = Cabbage.CucumberExpression.compile(term, standard_registry())
        Macro.escape({:cucumber_expression, term})

      true ->
        regex = Regex.compile!("^" <> Regex.escape(term) <> "$")
        Macro.escape(regex)
    end
  end

  defp to_pattern_ast(term), do: term

  @doc false
  # Compiles a stored `{:cucumber_expression, source}` marker back into a
  # `%Cabbage.CucumberExpression{}` against the built-in parameter-type registry.
  # Called at the feature module's compile time by `Cabbage.Feature` to match
  # steps and extract their positional, transformed arguments.
  def compile_expression(source), do: Cabbage.CucumberExpression.compile(source, standard_registry())

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

  @keys ~w(async case describe file integration line test type scenario case_template registered __table__ __doc_string__)a
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
