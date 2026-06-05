defmodule Cabbage.Conformance.CCK.Steps do
  @moduledoc """
  Elixir step definitions for the CCK sample features, re-implemented from the upstream
  reference TypeScript (`test/conformance/cck/reference/<name>/<name>.ts`).

  Each public function returns a populated `Cabbage.Messages.StepRegistry` for one sample
  area. The `for/1` dispatcher maps a sample name to its registry; `sample_uri/2` mirrors
  the `samples/<name>/<file>` uri the goldens embed (dropped by normalization, but kept
  realistic). These are test fixtures, not shipped library code.

  Step outcome protocol (see `Cabbage.Messages`): returning `"pending"`/`"skipped"` sets
  that status (no exception); raising `Cabbage.PendingError`/`Cabbage.SkippedError` sets
  PENDING/SKIPPED *with* the reference exception type; raising anything else marks the
  step FAILED; anything else PASSES. `{:ok, world}` threads scenario world state across
  steps.
  """

  alias Cabbage.Messages.StepRegistry

  @doc "The step registry for `sample`, or an empty registry when the sample has no step defs."
  @spec for(String.t()) :: StepRegistry.t()
  def for(sample)

  def for("minimal") do
    StepRegistry.new()
    |> add("I have {int} cukes in my belly", "minimal", 3, fn _args -> :ok end)
  end

  def for("empty"), do: StepRegistry.new()

  def for("cdata") do
    StepRegistry.new()
    |> add("I have {int} <![CDATA[cukes]]> in my belly", "cdata", 3, fn _args -> :ok end)
  end

  def for("backgrounds") do
    StepRegistry.new()
    |> add("an order for {string}", "backgrounds", 3, fn _ -> :ok end)
    |> add("an action", "backgrounds", 7, fn -> :ok end)
    |> add("an outcome", "backgrounds", 11, fn -> :ok end)
  end

  def for("rules-backgrounds") do
    StepRegistry.new()
    |> add("an order for {string}", "rules-backgrounds", 3, fn _ -> :ok end)
    |> add("an action", "rules-backgrounds", 7, fn -> :ok end)
    |> add("an outcome", "rules-backgrounds", 11, fn -> :ok end)
  end

  def for("doc-strings") do
    StepRegistry.new()
    |> add("a doc string:", "doc-strings", 3, fn _args, _arg -> :ok end)
  end

  def for("data-tables") do
    StepRegistry.new()
    |> add("the following table is transposed:", "data-tables", 6, fn _args, {:data_table, rows}, world ->
      {:ok, Map.put(world, :transposed, transpose(rows))}
    end)
    |> add("it should be:", "data-tables", 10, fn _args, {:data_table, expected}, world ->
      ^expected = Map.fetch!(world, :transposed)
      :ok
    end)
  end

  def for("unused-steps") do
    StepRegistry.new()
    |> add("a step that is used", "unused-steps", 3, fn -> :ok end)
    |> add("a step that is not used", "unused-steps", 7, fn -> :ok end)
  end

  def for("undefined") do
    StepRegistry.new()
    |> add("an implemented step", "undefined", 3, fn -> :ok end)
    |> add("a step that will be skipped", "undefined", 7, fn -> :ok end)
  end

  def for("pending") do
    StepRegistry.new()
    |> add("an implemented non-pending step", "pending", 3, fn -> :ok end)
    |> add("an implemented step that is skipped", "pending", 7, fn -> :ok end)
    |> add("an unimplemented pending step", "pending", 11, fn -> "pending" end)
  end

  def for("skipped") do
    StepRegistry.new()
    |> add("a step that does not skip", "skipped", 3, fn -> :ok end)
    |> add("a step that is skipped", "skipped", 7, fn -> :ok end)
    |> add("I skip a step", "skipped", 11, fn -> "skipped" end)
  end

  def for("ambiguous") do
    StepRegistry.new()
    |> add(~r/^a (.*?) with (.*?)$/, "ambiguous", 3, fn _args -> :ok end)
    |> add(~r/^a step with (.*?)$/, "ambiguous", 7, fn _args -> :ok end)
  end

  def for("rules") do
    StepRegistry.new()
    |> add("the customer has {int} cents", "rules", 5, fn [money], _arg, world ->
      {:ok, Map.put(world, :money, money)}
    end)
    |> add("there are chocolate bars in stock", "rules", 9, fn _args, _arg, world ->
      {:ok, Map.put(world, :stock, ["Mars"])}
    end)
    |> add("there are no chocolate bars in stock", "rules", 13, fn _args, _arg, world ->
      {:ok, Map.put(world, :stock, [])}
    end)
    |> add("the customer tries to buy a {int} cent chocolate bar", "rules", 17, fn [price], _arg, world ->
      money = Map.get(world, :money, 0)
      stock = Map.get(world, :stock, [])

      if money >= price and stock != [] do
        {:ok, Map.put(world, :chocolate, hd(stock))}
      else
        :ok
      end
    end)
    |> add("the sale should not happen", "rules", 22, fn _args, _arg, world ->
      nil = Map.get(world, :chocolate)
      :ok
    end)
    |> add("the sale should happen", "rules", 26, fn _args, _arg, world ->
      true = Map.get(world, :chocolate) != nil
      :ok
    end)
  end

  def for("examples-tables") do
    StepRegistry.new()
    |> add("there are {int} cucumbers", "examples-tables", 4, fn [count], _arg, world ->
      {:ok, Map.put(world, :count, count)}
    end)
    |> add("there are {int} friends", "examples-tables", 8, fn [friends], _arg, world ->
      {:ok, Map.put(world, :friends, friends)}
    end)
    |> add("I eat {int} cucumbers", "examples-tables", 12, fn [eaten], _arg, world ->
      {:ok, Map.update!(world, :count, &(&1 - eaten))}
    end)
    |> add("I should have {int} cucumbers", "examples-tables", 16, fn [expected], _arg, world ->
      ^expected = Map.fetch!(world, :count)
      :ok
    end)
    |> add("each person can eat {int} cucumbers", "examples-tables", 20, fn [expected], _arg, world ->
      share = div(Map.fetch!(world, :count), 1 + Map.fetch!(world, :friends))
      ^expected = share
      :ok
    end)
  end

  def for("markdown") do
    StepRegistry.new()
    |> add("some TypeScript code:", "markdown", 4, fn _args, _arg -> :ok end)
    |> add("some classic Gherkin:", "markdown", 8, fn _args, _arg -> :ok end)
    |> add(
      "we use a data table and attach something and then {word}",
      "markdown",
      11,
      fn [word], _arg ->
        if word == "fail", do: raise("You asked me to fail"), else: :ok
      end
    )
    |> add("this might or might not run", "markdown", 22, fn -> :ok end)
  end

  def for("multiple-features") do
    StepRegistry.new()
    |> add("an order for {string}", "multiple-features", 3, fn _args -> :ok end)
  end

  def for("multiple-features-reversed") do
    StepRegistry.new()
    |> add("an order for {string}", "multiple-features-reversed", 3, fn _args -> :ok end)
  end

  def for("all-statuses") do
    StepRegistry.new()
    |> add(~r/^a step$/, "all-statuses", 3, fn _args -> :ok end)
    |> add(~r/^a failing step$/, "all-statuses", 5, fn _args -> raise "whoops" end)
    |> add(~r/^a pending step$/, "all-statuses", 9, fn _args -> "pending" end)
    |> add(~r/^a skipped step$/, "all-statuses", 13, fn _args -> "skipped" end)
    |> add(~r/^an ambiguous (.*?)$/, "all-statuses", 17, fn _args -> :ok end)
    |> add(~r/^(.*?) ambiguous step$/, "all-statuses", 19, fn _args -> :ok end)
  end

  def for("failedish-combinations") do
    StepRegistry.new()
    |> add(~r/^a step$/, "failedish-combinations", 3, fn _args -> :ok end)
    |> add(~r/^a skipped step$/, "failedish-combinations", 7, fn _args -> "skipped" end)
    |> add(~r/^a pending step$/, "failedish-combinations", 11, fn _args -> "pending" end)
    |> add(~r/^an ambiguous (.*?)$/, "failedish-combinations", 15, fn _args -> :ok end)
    |> add(~r/^(.*?) ambiguous step$/, "failedish-combinations", 17, fn _args -> :ok end)
    |> add(~r/^a failing step$/, "failedish-combinations", 19, fn _args -> raise "whoops" end)
  end

  def for("stack-traces") do
    StepRegistry.new()
    |> add("a step throws an exception", "stack-traces", 3, fn -> raise "BOOM" end)
  end

  def for("pending-exception") do
    StepRegistry.new()
    |> add("an unimplemented pending step", "pending-exception", 3, fn ->
      raise Cabbage.PendingError, "TODO"
    end)
  end

  def for("skipped-exception") do
    StepRegistry.new()
    |> add("I skip a step", "skipped-exception", 3, fn ->
      raise Cabbage.SkippedError, "skipping"
    end)
  end

  # ---- helpers ---------------------------------------------------------------

  defp add(registry, pattern, sample, line, fun) do
    uri = "samples/#{sample}/#{sample}.ts"
    StepRegistry.add(registry, pattern, fun, uri: uri, line: line)
  end

  # Transpose a list of rows (each a list of cell strings), matching DataTable#transpose.
  defp transpose([]), do: []
  defp transpose(rows), do: rows |> Enum.zip() |> Enum.map(&Tuple.to_list/1)
end
