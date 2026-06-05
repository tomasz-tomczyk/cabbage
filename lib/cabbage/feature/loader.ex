defmodule Cabbage.Feature.Loader do
  alias Gherkin.Elements.{Feature, Scenario, Step}

  def load_from_file(path) do
    "#{Cabbage.base_path()}#{path}"
    |> File.read!()
    |> load_from_string()
  end

  def load_from_string(string) do
    string
    |> Gherkin.parse()
    |> Gherkin.flatten()
    |> fix_step_types()
  end

  defp fix_step_types(%Feature{scenarios: scenarios} = feature) do
    scenarios = scenarios |> Enum.map(&fix_step_types/1)
    %{feature | scenarios: scenarios}
  end

  defp fix_step_types(%Scenario{steps: steps} = scenario) do
    steps = steps |> Enum.reduce([], &fix_step_type/2) |> Enum.reverse()
    %{scenario | steps: steps}
  end

  # "And" and "But" are continuation keywords: they inherit the keyword of the
  # preceding step (which has itself already been resolved by the reduce).
  @inherited_keywords ~w(And But)

  defp fix_step_type(%Step{keyword: keyword} = current_step, [previous_step | _] = steps)
       when keyword in @inherited_keywords do
    fixed_step = %{current_step | keyword: previous_step.keyword}
    [fixed_step | steps]
  end

  defp fix_step_type(current_step, steps), do: [current_step | steps]
end
