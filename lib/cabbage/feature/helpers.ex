defmodule Cabbage.Feature.Helpers do
  @moduledoc false
  require Logger

  def add_step(module, string_or_regex, vars, state, block, metadata) do
    regex = to_regex_ast(string_or_regex)

    Module.put_attribute(module, :steps, {:{}, [], [regex, vars, state, block, metadata]})
    quote(do: nil)
  end

  defp to_regex_ast(term) when is_binary(term) do
    regex_string = Cabbage.Feature.CucumberExpression.to_regex_string(term)
    Code.string_to_quoted!("~r/#{regex_string}/")
  end

  defp to_regex_ast(term), do: term

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

  def agent_name(scenario_name, module_name) do
    :"cabbage_integration_test-#{scenario_name}-#{module_name}"
  end

  @keys ~w(async case describe file integration line test type scenario case_templae registered)a
  def remove_hidden_state(state) do
    Map.drop(state, @keys)
  end

  def start_state(scenario_name, module_name, state) do
    name = scenario_name |> agent_name(module_name)
    agent = Process.whereis(name)

    if agent do
      update_state(scenario_name, module_name, fn s ->
        Map.merge(s, state) |> remove_hidden_state()
      end)
    else
      Agent.start(fn -> state end, name: name)
    end
  end

  def fetch_state(scenario_name, module_name) do
    name = scenario_name |> agent_name(module_name)
    ((Process.whereis(name) && Agent.get(name, & &1)) || %{}) |> remove_hidden_state()
  end

  def update_state(scenario_name, module_name, fun) do
    scenario_name
    |> agent_name(module_name)
    |> Agent.update(fun)
  end

  def run_tag(tags, tag, module, scenario_name) do
    string_tag = to_string(tag)

    case Enum.find(tags, &match?({^string_tag, _}, &1)) do
      {^string_tag, block} ->
        Logger.debug("Cabbage: Running tag @#{tag}...")
        state = evaluate_tag_block(block)
        start_state(scenario_name, module, state)

      _ ->
        # Nothing to do
        nil
    end
  end

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
