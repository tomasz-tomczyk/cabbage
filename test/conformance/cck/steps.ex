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

  alias Cabbage.Messages.{HookRegistry, StepRegistry}

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

  # ---- hook areas (step definitions) -----------------------------------------

  def for("hooks") do
    StepRegistry.new()
    |> add("a step passes", "hooks", 7, fn -> :ok end)
    |> add("a step fails", "hooks", 11, fn -> raise "Exception in step" end)
  end

  def for("hooks-named") do
    StepRegistry.new()
    |> add("a step passes", "hooks-named", 7, fn -> :ok end)
  end

  def for("hooks-conditional") do
    StepRegistry.new()
    |> add("a step passes", "hooks-conditional", 11, fn -> :ok end)
  end

  def for("hooks-skipped") do
    StepRegistry.new()
    |> add("a normal step", "hooks-skipped", 13, fn -> :ok end)
    |> add("a step that skips", "hooks-skipped", 17, fn -> "skipped" end)
  end

  def for("hooks-undefined"), do: StepRegistry.new()

  def for("global-hooks") do
    StepRegistry.new()
    |> add("a step passes", "global-hooks", 11, fn -> :ok end)
    |> add("a step fails", "global-hooks", 15, fn -> raise "Exception in step" end)
  end

  def for("global-hooks-beforeall-error") do
    StepRegistry.new()
    |> add("a step passes", "global-hooks-beforeall-error", 15, fn -> :ok end)
  end

  def for("global-hooks-afterall-error") do
    StepRegistry.new()
    |> add("a step passes", "global-hooks-afterall-error", 11, fn -> :ok end)
  end

  def for("skipped-failing-hook") do
    StepRegistry.new()
    |> add("a step that skips", "skipped-failing-hook", 3, fn -> "skipped" end)
  end

  # ---- hook areas (hook registrations) ---------------------------------------

  @doc """
  The hook registry for `sample`, mirroring the reference `Before`/`After`/`BeforeAll`/
  `AfterAll` registrations (registration order is significant — see
  `Cabbage.Messages.HookRegistry`). Samples with no hooks get an empty registry.
  """
  @spec hooks_for(String.t()) :: HookRegistry.t()
  def hooks_for(sample)

  def hooks_for("hooks") do
    HookRegistry.new()
    |> before(fn -> :ok end, "hooks", 3)
    |> aftr(fn -> :ok end, "hooks", 15)
  end

  def hooks_for("hooks-named") do
    HookRegistry.new()
    |> before(fn -> :ok end, "hooks-named", 3, name: "A named before hook")
    |> aftr(fn -> :ok end, "hooks-named", 11, name: "A named after hook")
  end

  def hooks_for("hooks-conditional") do
    HookRegistry.new()
    |> before(fn -> :ok end, "hooks-conditional", 3, tag: "@passing-hook")
    |> before(fn -> raise "Exception in conditional hook" end, "hooks-conditional", 7, tag: "@fail-before")
    |> aftr(fn -> raise "Exception in conditional hook" end, "hooks-conditional", 15, tag: "@fail-after")
    |> aftr(fn -> :ok end, "hooks-conditional", 19, tag: "@passing-hook")
  end

  def hooks_for("hooks-skipped") do
    HookRegistry.new()
    |> before(fn -> :ok end, "hooks-skipped", 3)
    |> before(fn -> "skipped" end, "hooks-skipped", 7, tag: "@skip-before")
    |> before(fn -> :ok end, "hooks-skipped", 9)
    |> aftr(fn -> :ok end, "hooks-skipped", 19)
    |> aftr(fn -> "skipped" end, "hooks-skipped", 23, tag: "@skip-after")
    |> aftr(fn -> :ok end, "hooks-skipped", 25)
  end

  def hooks_for("hooks-undefined") do
    HookRegistry.new()
    |> before(fn -> :ok end, "hooks-undefined", 3)
    |> aftr(fn -> :ok end, "hooks-undefined", 5)
  end

  def hooks_for("global-hooks") do
    HookRegistry.new()
    |> before_all(fn -> :ok end, "global-hooks", 3)
    |> before_all(fn -> :ok end, "global-hooks", 7)
    |> after_all(fn -> :ok end, "global-hooks", 19)
    |> after_all(fn -> :ok end, "global-hooks", 23)
  end

  def hooks_for("global-hooks-beforeall-error") do
    HookRegistry.new()
    |> before_all(fn -> :ok end, "global-hooks-beforeall-error", 3)
    |> before_all(fn -> raise "BeforeAll hook went wrong" end, "global-hooks-beforeall-error", 7)
    |> before_all(fn -> :ok end, "global-hooks-beforeall-error", 11)
    |> after_all(fn -> :ok end, "global-hooks-beforeall-error", 19)
    |> after_all(fn -> :ok end, "global-hooks-beforeall-error", 23)
  end

  def hooks_for("global-hooks-afterall-error") do
    HookRegistry.new()
    |> before_all(fn -> :ok end, "global-hooks-afterall-error", 3)
    |> before_all(fn -> :ok end, "global-hooks-afterall-error", 7)
    |> after_all(fn -> :ok end, "global-hooks-afterall-error", 15)
    |> after_all(fn -> raise "AfterAll hook went wrong" end, "global-hooks-afterall-error", 19)
    |> after_all(fn -> :ok end, "global-hooks-afterall-error", 23)
  end

  def hooks_for("skipped-failing-hook") do
    HookRegistry.new()
    |> aftr(fn -> raise "whoops" end, "skipped-failing-hook", 5)
  end

  def hooks_for(_sample), do: HookRegistry.new()

  # ---- helpers ---------------------------------------------------------------

  defp add(registry, pattern, sample, line, fun) do
    uri = "samples/#{sample}/#{sample}.ts"
    StepRegistry.add(registry, pattern, fun, uri: uri, line: line)
  end

  defp before(registry, fun, sample, line, opts \\ []),
    do: hook(registry, :before_test_case, fun, sample, line, opts)

  defp aftr(registry, fun, sample, line, opts \\ []),
    do: hook(registry, :after_test_case, fun, sample, line, opts)

  defp before_all(registry, fun, sample, line, opts \\ []),
    do: hook(registry, :before_test_run, fun, sample, line, opts)

  defp after_all(registry, fun, sample, line, opts \\ []),
    do: hook(registry, :after_test_run, fun, sample, line, opts)

  defp hook(registry, type, fun, sample, line, opts) do
    uri = "samples/#{sample}/#{sample}.ts"
    HookRegistry.add(registry, type, fun, Keyword.merge([uri: uri, line: line], opts))
  end

  # Transpose a list of rows (each a list of cell strings), matching DataTable#transpose.
  defp transpose([]), do: []
  defp transpose(rows), do: rows |> Enum.zip() |> Enum.map(&Tuple.to_list/1)
end
